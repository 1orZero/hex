//! Output's Jev key row (FORK.md "Jev key"): the key that turns `jev` on
//! or off while a dictation records, J until another is recorded. It records
//! with General's recorder face, from the window's key presses, with Hex's
//! shortcuts suspended, and refuses a key Hex's shortcuts use.

use std::cell::{Cell, RefCell};
use std::ptr::NonNull;
use std::sync::mpsc::{self, Receiver};
use std::time::{Duration, Instant};

use block2::RcBlock;
use objc2::rc::Retained;
use objc2::runtime::AnyObject;
use objc2_app_kit::{NSEvent, NSEventMask, NSEventType};
use rune::{El, Tx, col, row};

use super::super::Ui;
use super::super::controls::{KeySize, Paint, key_tray, keycap, setting_row};
use super::super::settings::{self as s, Capture as UpstreamCapture, Face, Prompt};
use crate::app_settings::{HotkeyBinding, HotkeyModifiers, modifiers_from_flags};
use crate::fork::jev_key::{self, Refusal};

const ESCAPE_KEY_CODE: u16 = 53;
/// How long a saved key shows Saved, as General's recorders do.
const SAVED_FOR: Duration = Duration::from_secs(1);
/// A recorder nobody presses a key into stops listening.
const LISTEN_FOR: Duration = Duration::from_secs(10);

#[derive(Clone, Copy, PartialEq)]
enum Capture {
    Idle,
    Listening {
        message: Option<&'static str>,
        since: Instant,
    },
    Saved {
        until: Instant,
    },
}

enum Recorded {
    Key(Result<HotkeyBinding, &'static str>),
    Cancelled,
}

/// The key monitor while the recorder listens. Dropping it stops listening.
struct Watch {
    monitor: Retained<AnyObject>,
    results: Receiver<Recorded>,
    /// Another recorder took over: its own watch keeps shortcuts suspended.
    keep_suspended: bool,
}

impl Drop for Watch {
    fn drop(&mut self) {
        // SAFETY: the monitor came from addLocalMonitor on this thread.
        unsafe { NSEvent::removeMonitor(&self.monitor) };
        if !self.keep_suspended {
            crate::app_settings::set_hotkey_capture_active(false);
        }
    }
}

struct Recorder {
    capture: Capture,
    watch: Option<Watch>,
    binding: Option<HotkeyBinding>,
}

thread_local! {
    static RECORDER: RefCell<Recorder> = const {
        RefCell::new(Recorder {
            capture: Capture::Idle,
            watch: None,
            binding: None,
        })
    };
}

pub(in crate::rune_ui) fn row_el(ui: &Ui, p: Paint) -> El {
    let (capture, binding) = RECORDER.with_borrow_mut(|recorder| {
        let binding = recorder
            .binding
            .get_or_insert_with(jev_key::binding)
            .clone();
        (recorder.capture, binding)
    });
    setting_row(
        p,
        "fork-jev-key",
        "錄音中切換 Jev",
        None,
        keys_button(ui, p, capture, &binding),
    )
}

/// General's `keys_button`, for this key.
fn keys_button(ui: &Ui, p: Paint, capture: Capture, binding: &HotkeyBinding) -> El {
    let c = &p.k.c;
    let listening = matches!(capture, Capture::Listening { .. });
    let face = match capture {
        Capture::Listening { message, .. } => {
            Face::Listening(message.map_or(Prompt::Press, Prompt::Rejected))
        }
        Capture::Saved { .. } => Face::Shortcut { saved: true },
        Capture::Idle => Face::Shortcut { saved: false },
    };
    let content = match face {
        Face::Listening(_) => s::recorder_face(p, face, true).key("face"),
        Face::Shortcut { saved } => {
            let caps = s::shortcut_caps(binding, false);
            let keys = key_tray(
                p,
                "keys",
                KeySize::Small,
                caps.iter()
                    .enumerate()
                    .map(|(index, cap)| keycap(p, index, cap, KeySize::Small, false)),
            );
            row()
                .key("face")
                .gap(4.0)
                .center_y()
                .children(saved.then(|| {
                    rune::icon(&rune_theme_opencode::icons::CHECK_SMALL, 16.0)
                        .key("saved")
                        .color(p.success())
                }))
                .child(keys)
        }
    };
    let live = ui.live();
    let mut button = row()
        .key("fork-jev-key-hotkey")
        .role("button")
        .label(s::face_label(face))
        .center_y()
        .padding(2.0)
        .mr(-4.0)
        .radius(p.k.radius.md)
        .focusable(!listening)
        .focus_ring(2.0, 0.0, c.border_focus)
        .on_press(move |ui: &mut Ui| {
            if live {
                begin(ui);
            }
        })
        .child(col().key("content").child(content));
    if listening {
        button = button.fill(c.bg_button_neutral);
    } else {
        button = button.hover(c.hover).press(c.pressed);
    }
    button
}

fn begin(ui: &mut Ui) {
    if RECORDER.with_borrow(|recorder| matches!(recorder.capture, Capture::Listening { .. })) {
        stop(false);
        return;
    }
    s::cancel_capture(ui);
    let Some(waker) = ui.modes.waker.clone() else {
        return;
    };
    match watch(waker) {
        Ok(watch) => RECORDER.with_borrow_mut(|recorder| {
            recorder.watch = Some(watch);
            recorder.capture = Capture::Listening {
                message: None,
                since: Instant::now(),
            };
        }),
        Err(message) => ui.error = Some(message.into()),
    }
}

fn stop(keep_suspended: bool) {
    RECORDER.with_borrow_mut(|recorder| {
        if let Some(watch) = &mut recorder.watch {
            watch.keep_suspended = keep_suspended;
        }
        recorder.watch = None;
        recorder.capture = Capture::Idle;
    });
}

fn watch(waker: rune::Waker) -> Result<Watch, &'static str> {
    crate::app_settings::set_hotkey_capture_active(true);
    let (sender, results) = mpsc::channel();
    let held_alone = Cell::new(HotkeyModifiers::default());
    let block = RcBlock::new(move |event: NonNull<NSEvent>| -> *mut NSEvent {
        // SAFETY: AppKit passes a live event for the handler's duration.
        let event_ref = unsafe { event.as_ref() };
        let kind = event_ref.r#type();
        if kind != NSEventType::KeyDown && kind != NSEventType::FlagsChanged {
            return event.as_ptr();
        }
        let flags = crate::app_settings::normalized_modifier_flags(
            event_ref.modifierFlags().bits() as u64,
            crate::suppression::physical_keys::snapshot(),
        );
        let mut modifiers = modifiers_from_flags(flags).without_side_constraints();
        modifiers.function = false;
        if kind == NSEventType::FlagsChanged {
            let released = held_alone.replace(modifiers);
            if modifiers.is_empty() && !released.is_empty() {
                let alone = HotkeyBinding {
                    modifiers: released,
                    key: None,
                };
                if sender.send(Recorded::Key(Ok(alone))).is_ok() {
                    waker();
                }
            }
            return event.as_ptr();
        }
        held_alone.set(HotkeyModifiers::default());
        if !event_ref.isARepeat() {
            let code = event_ref.keyCode();
            let recorded = if code == ESCAPE_KEY_CODE && modifiers.is_empty() {
                Recorded::Cancelled
            } else {
                let characters = event_ref
                    .charactersIgnoringModifiers()
                    .map(|characters| characters.to_string());
                Recorded::Key(
                    super::super::hotkey_keys::hotkey_key(code, characters.as_deref(), || {
                        crate::keyboard::key_label(code)
                    })
                    .map(|key| HotkeyBinding {
                        modifiers,
                        key: Some(key),
                    }),
                )
            };
            if sender.send(recorded).is_ok() {
                waker();
            }
        }
        std::ptr::null_mut()
    });
    // SAFETY: the block lives as long as AppKit retains it; the monitor is
    // removed on drop, on the main thread that installed it.
    let monitor = unsafe {
        NSEvent::addLocalMonitorForEventsMatchingMask_handler(
            NSEventMask::KeyDown | NSEventMask::FlagsChanged,
            &block,
        )
    };
    match monitor {
        Some(monitor) => Ok(Watch {
            monitor,
            results,
            keep_suspended: false,
        }),
        None => {
            crate::app_settings::set_hotkey_capture_active(false);
            Err("無法讀取鍵盤來錄下按鍵")
        }
    }
}

/// Follows the recorder: a recorded key, Escape, another recorder taking
/// over, the window hiding, or Saved running out.
pub(in crate::rune_ui) fn poll(ui: &mut Ui, tx: &mut Tx) -> bool {
    let capture = RECORDER.with_borrow(|recorder| recorder.capture);
    let now = Instant::now();
    match capture {
        Capture::Idle => false,
        Capture::Saved { until } => {
            if now < until {
                return false;
            }
            RECORDER.with_borrow_mut(|recorder| recorder.capture = Capture::Idle);
            true
        }
        Capture::Listening { since, .. } => {
            if !matches!(ui.capture, UpstreamCapture::Idle) {
                stop(true);
                return true;
            }
            let visible = ui.window.as_ref().is_none_or(rune::AppHandle::is_visible);
            let shown = ui.pane == super::super::Pane::Output && visible;
            if !shown || now.duration_since(since) >= LISTEN_FOR {
                stop(false);
                return true;
            }
            let recorded = RECORDER.with_borrow(|recorder| {
                recorder
                    .watch
                    .as_ref()
                    .and_then(|watch| watch.results.try_recv().ok())
            });
            match recorded {
                None => {
                    tx.wake_after(LISTEN_FOR - now.duration_since(since));
                    false
                }
                Some(Recorded::Cancelled) => {
                    stop(false);
                    true
                }
                Some(Recorded::Key(Err(message))) => {
                    listen_with(message);
                    true
                }
                Some(Recorded::Key(Ok(binding))) => {
                    if let Some(refusal) = jev_key::refusal(&ui.settings, &binding) {
                        listen_with(refusal_message(refusal));
                        return true;
                    }
                    stop(false);
                    match jev_key::set_binding(&binding) {
                        Ok(()) => RECORDER.with_borrow_mut(|recorder| {
                            recorder.binding = Some(binding);
                            recorder.capture = Capture::Saved {
                                until: now + SAVED_FOR,
                            };
                            tx.wake_after(SAVED_FOR);
                        }),
                        Err(error) => ui.error = Some(format!("無法儲存切換 Jev 的按鍵：{error}")),
                    }
                    true
                }
            }
        }
    }
}

fn listen_with(message: &'static str) {
    RECORDER.with_borrow_mut(|recorder| {
        if let Capture::Listening { message: shown, .. } = &mut recorder.capture {
            *shown = Some(message);
        }
    });
}

fn refusal_message(refusal: Refusal) -> &'static str {
    match refusal {
        Refusal::NeedsKey => "請按一個按鍵",
        Refusal::Escape => "Esc 用來取消聽寫",
        Refusal::InUse => "Hex 的快捷鍵已使用這個鍵",
    }
}
