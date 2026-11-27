//! `recognition`'s child (FORK.md "Jev key"), so it reads the shortcut
//! machines: after each listener pass, what records for `fork::jev_key`.

use super::hotkeys::{Hotkeys, Shortcut};
use crate::audio::CaptureInstant;
use crate::fork::jev_key::Recording;
use crate::suppression::DictationHotkey;

pub(super) fn follow(hotkeys: &Hotkeys, programmatic: bool) {
    crate::fork::jev_key::follow(recording(hotkeys, programmatic, CaptureInstant::now()));
}

fn recording(hotkeys: &Hotkeys, programmatic: bool, now: CaptureInstant) -> Recording {
    if programmatic {
        return Recording::Other;
    }
    let Some(active) = &hotkeys.active else {
        return Recording::Idle;
    };
    let machine = match active.shortcut {
        Shortcut::Dictation => Some(&hotkeys.dictation),
        Shortcut::Second => hotkeys.second.as_ref(),
        Shortcut::CapsLock => Some(&hotkeys.caps_lock),
        Shortcut::Extra(index) => hotkeys.extra.get(index).and_then(Option::as_ref),
        Shortcut::Raw => None,
    };
    match machine {
        Some(machine) if !active.raw && machine.is_recording() => Recording::Hotkey {
            owned: owns_press(machine, now),
            held: machine.binding().modifiers,
        },
        Some(_) if !active.raw => Recording::Idle,
        _ => Recording::Other,
    }
}

/// The press is Hex's: held past the hold threshold (when Hold takes
/// Escape), or recording hands-free. Earlier, a key may belong to a chord
/// such as Option-J typing ∆, which still discards the capture.
fn owns_press(machine: &DictationHotkey, now: CaptureInstant) -> bool {
    machine.is_locked() || machine.takes_escape(now)
}

#[cfg(test)]
#[path = "listener_tests.rs"]
mod tests;
