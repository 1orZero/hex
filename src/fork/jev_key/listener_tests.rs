use std::time::Duration;

use super::*;
use crate::app_settings::{HotkeyModifiers, OPTION_KEY_MASK, RuntimeHotkey};
use crate::suppression::{HotkeyAction, InputEvent};

const J: u16 = 38;

fn option() -> RuntimeHotkey {
    RuntimeHotkey {
        modifiers: HotkeyModifiers::option(),
        key_code: None,
    }
}

fn hotkeys(base: CaptureInstant) -> Hotkeys {
    Hotkeys::new(
        DictationHotkey::new(base, true, option()),
        DictationHotkey::new(base, false, RuntimeHotkey::default()),
    )
}

/// Feeds one input as the listener does: the machines act, and a start or
/// an end updates the active capture.
fn feed(hotkeys: &mut Hotkeys, event: InputEvent, at: CaptureInstant) -> Vec<HotkeyAction> {
    let actions = hotkeys.process(event, at);
    for (shortcut, action) in &actions {
        hotkeys.resolve_action(*shortcut, *action);
    }
    actions.into_iter().map(|(_, action)| action).collect()
}

fn holding_option(owned: bool) -> Recording {
    Recording::Hotkey {
        owned,
        held: HotkeyModifiers::option(),
    }
}

#[test]
fn a_hold_owns_its_press_past_the_hold_threshold() {
    let base = CaptureInstant::from_nanos(60_000_000_000);
    let at = |ms: u64| base + Duration::from_millis(ms);
    let mut hotkeys = hotkeys(base);
    assert_eq!(recording(&hotkeys, false, at(0)), Recording::Idle);
    assert_eq!(
        feed(&mut hotkeys, InputEvent::Flags(OPTION_KEY_MASK), at(600)),
        [HotkeyAction::Start]
    );
    assert_eq!(recording(&hotkeys, false, at(680)), holding_option(false));
    assert_eq!(recording(&hotkeys, false, at(1_000)), holding_option(true));
    assert_eq!(
        recording(&hotkeys, true, at(1_000)),
        Recording::Other,
        "a programmatic dictation's"
    );
    assert_eq!(
        feed(&mut hotkeys, InputEvent::Flags(0), at(3_000)),
        [HotkeyAction::Finish]
    );
    assert_eq!(recording(&hotkeys, false, at(3_000)), Recording::Idle);
}

/// Why the session tap keeps the Jev key from the machines: a held
/// modifier-only shortcut plus any other key is a chord, which throws the
/// dictation away however long it was held.
#[test]
fn j_reaching_a_held_option_dictation_would_discard_it() {
    let base = CaptureInstant::from_nanos(61_000_000_000);
    let at = |ms: u64| base + Duration::from_millis(ms);
    let mut hotkeys = hotkeys(base);
    feed(&mut hotkeys, InputEvent::Flags(OPTION_KEY_MASK), at(600));
    let j = InputEvent::Key {
        code: J,
        down: true,
        flags: OPTION_KEY_MASK,
    };
    assert!(matches!(
        feed(&mut hotkeys, j, at(2_000))[..],
        [HotkeyAction::Discard(_)]
    ));
}

#[test]
fn a_double_tap_lock_owns_its_press_with_nothing_held() {
    let base = CaptureInstant::from_nanos(62_000_000_000);
    let at = |ms: u64| base + Duration::from_millis(ms);
    let mut hotkeys = hotkeys(base);
    feed(&mut hotkeys, InputEvent::Flags(OPTION_KEY_MASK), at(0));
    feed(&mut hotkeys, InputEvent::Flags(0), at(80));
    assert_eq!(
        feed(&mut hotkeys, InputEvent::Flags(OPTION_KEY_MASK), at(180)),
        [HotkeyAction::Start]
    );
    assert!(feed(&mut hotkeys, InputEvent::Flags(0), at(260)).is_empty());
    assert!(hotkeys.dictation.is_locked());
    assert_eq!(recording(&hotkeys, false, at(300)), holding_option(true));
    assert_eq!(
        feed(&mut hotkeys, InputEvent::Flags(OPTION_KEY_MASK), at(5_000)),
        [HotkeyAction::Finish]
    );
    assert_eq!(recording(&hotkeys, false, at(5_000)), Recording::Idle);
}

#[test]
fn a_raw_dictation_runs_no_jev_choice() {
    let base = CaptureInstant::from_nanos(63_000_000_000);
    let mut hotkeys = hotkeys(base);
    hotkeys.raw = Some(DictationHotkey::new(base, false, option()));
    assert!(hotkeys.raw.as_mut().is_some_and(DictationHotkey::lock));
    hotkeys.begin_capture(Shortcut::Raw, true);
    assert_eq!(recording(&hotkeys, false, base), Recording::Other);
}
