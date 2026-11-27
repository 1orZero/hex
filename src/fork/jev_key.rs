//! The recording's Jev key (FORK.md "Jev key"): while a hotkey dictation
//! records, a press of the key (J unless Output sets another) turns Derek's
//! `jev` transformation on or off for that dictation only. The session tap
//! keeps the press from the app in front and from the shortcut machines
//! ([`take`]), and the HID tap reports no chord for it ([`claims`]), so a
//! held Option plus J never discards the capture. The listener tells this
//! module what records ([`follow`]); the clip's submission keeps the choice
//! for its job ([`submitted`]), and processing applies it ([`profiles`]).
//! The HUD draws a border while the dictation runs Jev ([`hud_border`]).

use std::collections::VecDeque;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, PoisonError};
use std::time::Instant;

use crate::app_settings::{
    AppSettings, HotkeyBinding, HotkeyKey, HotkeyModifiers, HotkeySlot, RuntimeHotkey,
};
use crate::dictation::processor::Profiles;
use crate::suppression::InputEvent;

/// macOS's virtual key code for J on ANSI keyboards (`kVK_ANSI_J`).
const J_KEY_CODE: u16 = 38;
const ESCAPE_KEY_CODE: u16 = 53;
/// Submitted choices kept for processing; a job that never reached it
/// leaves its choice behind, so only the newest are kept.
const MAX_CHOICES: usize = 16;

/// J, the key until Output records another.
pub fn default_binding() -> HotkeyBinding {
    HotkeyBinding {
        modifiers: HotkeyModifiers::default(),
        key: Some(HotkeyKey {
            code: J_KEY_CODE,
            label: "J".into(),
        }),
    }
}

#[derive(serde::Deserialize, serde::Serialize)]
struct Setting {
    binding: HotkeyBinding,
}

/// The key, saved in `fork/jev-key.json` in the data folder; J when nothing
/// readable is saved.
pub fn binding() -> HotkeyBinding {
    setting_path()
        .and_then(|path| load_setting(&path))
        .unwrap_or_else(default_binding)
}

/// Saves the key; the next dictation uses it.
pub fn set_binding(binding: &HotkeyBinding) -> std::io::Result<()> {
    let path = setting_path().ok_or_else(|| std::io::Error::other("no data folder"))?;
    save_setting(&path, binding)?;
    tracing::info!(keys = %binding.keycaps().join("+"), "fork Jev key: saved");
    Ok(())
}

fn setting_path() -> Option<PathBuf> {
    crate::app_paths::support_dir()
        .ok()
        .map(|support| support.join("fork").join("jev-key.json"))
}

fn load_setting(path: &Path) -> Option<HotkeyBinding> {
    let bytes = std::fs::read(path).ok()?;
    serde_json::from_slice::<Setting>(&bytes)
        .ok()
        .map(|setting| setting.binding)
}

fn save_setting(path: &Path, binding: &HotkeyBinding) -> std::io::Result<()> {
    if let Some(folder) = path.parent() {
        crate::app_paths::create_private_dir(folder)?;
    }
    let bytes = serde_json::to_vec_pretty(&Setting {
        binding: binding.clone(),
    })
    .map_err(std::io::Error::other)?;
    crate::durable::write(path, &bytes)
}

/// Why a recorded key can't be the Jev key.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Refusal {
    /// Modifiers alone, or a mouse button.
    NeedsKey,
    /// Escape cancels the recording.
    Escape,
    /// A Hex shortcut uses it, alone or with a dictation shortcut's
    /// modifiers held (⌥T while ⌥ is held to dictate).
    InUse,
}

pub fn refusal(settings: &AppSettings, binding: &HotkeyBinding) -> Option<Refusal> {
    let Some(key) = binding.key.as_ref().filter(|key| !key.is_mouse()) else {
        return Some(Refusal::NeedsKey);
    };
    if key.code == ESCAPE_KEY_CODE {
        return Some(Refusal::Escape);
    }
    let dictation = [HotkeySlot::Dictation, HotkeySlot::SecondDictation]
        .into_iter()
        .chain((0..settings.extra_dictation_hotkeys.len()).map(HotkeySlot::ExtraDictation))
        .filter_map(|slot| slot.get(settings))
        .map(|held| HotkeyBinding {
            modifiers: with_held(binding.modifiers, held.modifiers),
            key: binding.key.clone(),
        });
    let pressed: Vec<HotkeyBinding> = std::iter::once(binding.clone()).chain(dictation).collect();
    let in_use = HotkeySlot::all_in(settings)
        .filter_map(|slot| slot.get(settings))
        .any(|other| pressed.iter().any(|candidate| candidate.overlaps(other)));
    in_use.then_some(Refusal::InUse)
}

/// `required` plus the modifiers a held dictation shortcut keeps down.
fn with_held(required: HotkeyModifiers, held: HotkeyModifiers) -> HotkeyModifiers {
    HotkeyModifiers {
        control: required.control.or(held.control),
        option: required.option.or(held.option),
        shift: required.shift.or(held.shift),
        command: required.command.or(held.command),
        function: required.function || held.function,
    }
}

/// What records now, as the listener sees it.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Recording {
    Idle,
    /// A raw, programmatic, or other capture that runs no Jev choice.
    Other,
    /// A hotkey dictation. `owned`: its press is Hex's (held past the hold
    /// threshold, or hands-free), so the key is too. `held`: the modifiers
    /// its shortcut keeps down.
    Hotkey {
        owned: bool,
        held: HotkeyModifiers,
    },
}

/// What a capture's start resolved off the listener's thread.
#[derive(Clone, Copy, Debug)]
pub struct Resolved {
    /// Global runs `jev` without a press: Output's 使用 Jev.
    pub initial: bool,
    pub key: RuntimeHotkey,
}

#[derive(Default)]
struct State {
    /// A hotkey dictation records.
    capturing: bool,
    generation: u64,
    /// The recording dictation's choice can flip: `jev` is registered and
    /// the key resolved. None until then, and for a capture without it.
    resolved: Option<Resolved>,
    on: bool,
    owned: bool,
    held: HotkeyModifiers,
    /// The key code a press was taken for, until its release.
    taken: Option<u16>,
    /// The latest dictation's choice still waits for its clip.
    unsubmitted: bool,
    choices: VecDeque<(Instant, bool)>,
}

impl State {
    /// Follows the listener; returns the generation of a hotkey dictation
    /// that just started, to resolve.
    fn follow(&mut self, recording: Recording) -> Option<u64> {
        let (capturing, owned, held) = match recording {
            Recording::Hotkey { owned, held } => (true, owned, held),
            Recording::Idle | Recording::Other => (false, false, HotkeyModifiers::default()),
        };
        let mut started = None;
        if capturing && !self.capturing {
            self.generation += 1;
            self.resolved = None;
            self.on = false;
            self.taken = None;
            self.unsubmitted = true;
            started = Some(self.generation);
        }
        if matches!(recording, Recording::Other) {
            self.resolved = None;
            self.on = false;
        }
        self.capturing = capturing;
        self.owned = owned;
        self.held = held;
        started
    }

    fn resolve(&mut self, generation: u64, resolved: Option<Resolved>) {
        if generation != self.generation || !self.capturing {
            return;
        }
        self.resolved = resolved;
        self.on = resolved.is_some_and(|resolved| resolved.initial);
    }

    fn armed(&self) -> Option<RuntimeHotkey> {
        self.resolved
            .filter(|_| self.capturing && self.owned)
            .map(|resolved| resolved.key)
    }

    /// The press is the key, alone or with the held shortcut's modifiers.
    fn matches(&self, key: RuntimeHotkey, code: u16, flags: u64) -> bool {
        let held = RuntimeHotkey {
            modifiers: with_held(key.modifiers, self.held),
            key_code: key.key_code,
        };
        key.matches_key_press(code, flags) || held.matches_key_press(code, flags)
    }

    fn claims(&self, code: u16, flags: u64) -> bool {
        self.taken == Some(code)
            || self
                .armed()
                .is_some_and(|key| self.matches(key, code, flags))
    }

    fn take(&mut self, input: InputEvent) -> bool {
        let InputEvent::Key { code, down, flags } = input else {
            return false;
        };
        if !down {
            let taken = self.taken == Some(code);
            if taken {
                self.taken = None;
            }
            return taken;
        }
        // A held key repeats; only its first press flips.
        if self.taken == Some(code) {
            return true;
        }
        if !self.claims(code, flags) {
            return false;
        }
        self.taken = Some(code);
        self.on = !self.on;
        tracing::info!(jev = self.on, "fork Jev key: flipped");
        true
    }

    fn submitted(&mut self, at: Instant) {
        if !std::mem::take(&mut self.unsubmitted) {
            return;
        }
        // The capture is over even when the listener saw the next one start
        // in the same pass, so the next follow starts a new dictation.
        self.capturing = false;
        let Some(resolved) = self.resolved else {
            return;
        };
        if self.on == resolved.initial {
            return;
        }
        if self.choices.len() == MAX_CHOICES {
            self.choices.pop_front();
        }
        self.choices.push_back((at, self.on));
    }

    fn cancelled(&mut self) {
        self.capturing = false;
        self.on = false;
        self.unsubmitted = false;
    }

    fn choice(&mut self, submitted: Instant) -> Option<bool> {
        let index = self.choices.iter().position(|(at, _)| *at == submitted)?;
        self.choices.remove(index).map(|(_, on)| on)
    }

    fn border(&self) -> bool {
        self.on && self.resolved.is_some()
    }
}

static STATE: Mutex<State> = Mutex::new(State {
    capturing: false,
    generation: 0,
    resolved: None,
    on: false,
    owned: false,
    held: HotkeyModifiers {
        control: None,
        option: None,
        shift: None,
        command: None,
        function: false,
    },
    taken: None,
    unsubmitted: false,
    choices: VecDeque::new(),
});

fn state() -> std::sync::MutexGuard<'static, State> {
    STATE.lock().unwrap_or_else(PoisonError::into_inner)
}

/// The listener's view after each pass. A dictation's start reads the key,
/// `jev`'s registration, and Global's steps on a thread of its own, so the
/// listener never waits on a file.
pub fn follow(recording: Recording) {
    let Some(generation) = state().follow(recording) else {
        return;
    };
    let spawned = std::thread::Builder::new()
        .name("hex-fork-jev-key".into())
        .spawn(move || {
            let resolved = resolve();
            state().resolve(generation, resolved);
        });
    if let Err(error) = spawned {
        tracing::warn!(%error, "fork Jev key: could not resolve the dictation's choice");
    }
}

fn resolve() -> Option<Resolved> {
    let registered = crate::personal_commands::load_status()
        .inspect_err(|error| tracing::warn!(%error, "fork Jev key: no transformation status"))
        .ok()?
        .transformations
        .iter()
        .any(|transformation| transformation.id == crate::fork::jev::JEV);
    if !registered {
        return None;
    }
    let binding = binding();
    let settings = crate::app_settings::path().and_then(|path| AppSettings::load_from(&path));
    if let Ok(settings) = settings
        && refusal(&settings, &binding).is_some()
    {
        tracing::info!("fork Jev key: a Hex shortcut uses the key, so it stays off");
        return None;
    }
    let key = binding.runtime();
    key.key_code.map(|_| Resolved {
        initial: crate::dictation::config::dictation_profiles().fork_global_has_jev(),
        key,
    })
}

/// The session tap: whether it keeps this key event from the app in front
/// and from the shortcut machines. Only a press of the key while a hotkey
/// dictation owns its press, and that press's repeats and release.
pub fn take(input: InputEvent) -> bool {
    state().take(input)
}

/// The HID tap: whether this key press is the Jev key's, so no chord.
pub fn claims(code: u16, flags: u64) -> bool {
    state().claims(code, flags)
}

/// The dictation's clip was submitted at `at`, its job's `submitted_at`.
pub fn submitted(at: Instant) {
    state().submitted(at);
}

/// The recording was cancelled or discarded: nothing runs, no border.
pub fn cancelled() {
    state().cancelled();
}

/// `profiles` for the job submitted at `submitted`: `jev` put into or
/// taken out of every mode when its dictation's choice differs from Global's,
/// else as they are.
pub fn profiles(profiles: Profiles, submitted: Instant) -> Profiles {
    match state().choice(submitted) {
        Some(on) => {
            tracing::info!(jev = on, "fork Jev key: this dictation's choice");
            profiles.fork_with_jev(on)
        }
        None => profiles,
    }
}

/// The system appearance the HUD last drew in, as Rune reports it to the
/// overlay: dark until the first frame says otherwise.
static HUD_DARK: AtomicBool = AtomicBool::new(true);

/// Follows the appearance each HUD frame draws in, so the border's look
/// changes with the next frame when the appearance does.
pub fn hud_dark(dark: bool) {
    HUD_DARK.store(dark, Ordering::Relaxed);
}

/// The HUD's border for `src/fork/jev_hud.wgsl`, shown while the dictation it
/// shows runs Jev: 0 none, 1 the dark appearance's, 2 the light one's.
pub fn hud_border() -> f32 {
    border_look(state().border(), HUD_DARK.load(Ordering::Relaxed))
}

fn border_look(border: bool, dark: bool) -> f32 {
    match (border, dark) {
        (false, _) => 0.0,
        (true, true) => 1.0,
        (true, false) => 2.0,
    }
}

#[cfg(test)]
mod tests;
