use super::*;
use crate::app_settings::{COMMAND_KEY_MASK, OPTION_KEY_MASK};

const J: u16 = J_KEY_CODE;
const K: u16 = 40;

fn j() -> RuntimeHotkey {
    default_binding().runtime()
}

fn holding_option(owned: bool) -> Recording {
    Recording::Hotkey {
        owned,
        held: HotkeyModifiers::option(),
    }
}

fn key(code: u16, down: bool, flags: u64) -> InputEvent {
    InputEvent::Key { code, down, flags }
}

/// A dictation that started and resolved, `initial` being Output's 使用 Jev.
fn recording(recording: Recording, initial: bool) -> State {
    let mut state = State::default();
    let generation = state.follow(recording).expect("a new dictation");
    state.resolve(generation, Some(Resolved { initial, key: j() }));
    state
}

#[test]
fn a_held_dictation_takes_j_with_option_down_and_flips_once_per_press() {
    let mut state = recording(holding_option(true), false);
    assert!(!state.border());
    assert!(
        state.claims(J, OPTION_KEY_MASK),
        "no chord evidence for the HID tap"
    );
    assert!(state.take(key(J, true, OPTION_KEY_MASK)));
    assert!(state.border());
    // Repeats of the held key are kept from the app but flip nothing.
    assert!(state.take(key(J, true, OPTION_KEY_MASK)));
    assert!(state.take(key(J, true, OPTION_KEY_MASK)));
    assert!(state.border());
    assert!(state.take(key(J, false, OPTION_KEY_MASK)));
    assert!(state.take(key(J, true, OPTION_KEY_MASK)));
    assert!(state.take(key(J, false, OPTION_KEY_MASK)));
    assert!(!state.border(), "a second press flips back");
}

#[test]
fn a_hands_free_dictation_takes_j_alone() {
    let mut state = recording(
        Recording::Hotkey {
            owned: true,
            held: HotkeyModifiers::default(),
        },
        false,
    );
    assert!(state.take(key(J, true, 0)));
    assert!(state.take(key(J, false, 0)));
    assert!(state.border());
}

#[test]
fn other_keys_and_other_chords_reach_the_app() {
    let mut state = recording(holding_option(true), false);
    assert!(!state.take(key(K, true, OPTION_KEY_MASK)));
    assert!(!state.take(key(K, false, OPTION_KEY_MASK)));
    assert!(!state.take(key(J, true, OPTION_KEY_MASK | COMMAND_KEY_MASK)));
    assert!(!state.claims(J, OPTION_KEY_MASK | COMMAND_KEY_MASK));
    assert!(!state.border());
}

#[test]
fn j_belongs_to_the_app_until_the_press_is_hexs() {
    let mut state = recording(holding_option(false), false);
    assert!(
        !state.claims(J, OPTION_KEY_MASK),
        "Option-J may still be the app's ∆"
    );
    assert!(!state.take(key(J, true, OPTION_KEY_MASK)));
    assert!(!state.take(key(J, false, OPTION_KEY_MASK)));
    state.follow(holding_option(true));
    assert!(state.take(key(J, true, OPTION_KEY_MASK)));
}

#[test]
fn nothing_is_taken_while_idle_or_without_jev_registered() {
    let mut idle = State::default();
    idle.follow(Recording::Idle);
    assert!(!idle.take(key(J, true, 0)));

    let mut unregistered = State::default();
    let generation = unregistered.follow(holding_option(true)).unwrap();
    unregistered.resolve(generation, None);
    assert!(!unregistered.take(key(J, true, OPTION_KEY_MASK)));
    assert!(!unregistered.border());

    let mut other = State::default();
    other.follow(Recording::Other);
    assert!(!other.take(key(J, true, 0)));
}

#[test]
fn a_release_after_the_dictation_ends_still_belongs_to_hex() {
    let mut state = recording(holding_option(true), false);
    assert!(state.take(key(J, true, OPTION_KEY_MASK)));
    state.follow(Recording::Idle);
    assert!(state.take(key(J, false, 0)));
    assert!(!state.take(key(J, true, 0)), "the next press is the app's");
}

#[test]
fn a_dictation_started_in_the_pass_that_ended_the_last_one_is_new() {
    let mut state = recording(holding_option(true), false);
    assert!(state.take(key(J, true, OPTION_KEY_MASK)));
    assert!(state.take(key(J, false, OPTION_KEY_MASK)));
    let first = Instant::now();
    state.follow(holding_option(false));
    state.submitted(first);
    let generation = state
        .follow(holding_option(false))
        .expect("the next dictation starts its own choice");
    state.resolve(
        generation,
        Some(Resolved {
            initial: false,
            key: j(),
        }),
    );
    assert!(
        !state.border(),
        "it starts from 使用 Jev, not the last choice"
    );
    state.follow(holding_option(true));
    assert!(state.take(key(J, true, OPTION_KEY_MASK)));
    let second = first + std::time::Duration::from_millis(1);
    state.submitted(second);
    assert_eq!(state.choice(first), Some(true));
    assert_eq!(state.choice(second), Some(true), "its own choice is kept");
}

#[test]
fn the_dictation_starts_from_outputs_switch_and_shows_it() {
    let state = recording(holding_option(true), true);
    assert!(
        state.border(),
        "使用 Jev on: the border shows from the start"
    );
}

#[test]
fn a_late_resolution_for_an_older_dictation_changes_nothing() {
    let mut state = State::default();
    let old = state.follow(holding_option(true)).unwrap();
    state.follow(Recording::Idle);
    state.follow(holding_option(true)).unwrap();
    state.resolve(
        old,
        Some(Resolved {
            initial: true,
            key: j(),
        }),
    );
    assert!(state.resolved.is_none());
    assert!(!state.border());
}

#[test]
fn only_a_flipped_choice_reaches_processing_for_its_own_job() {
    let at = Instant::now();
    let later = at + std::time::Duration::from_millis(5);

    let mut unflipped = recording(holding_option(true), true);
    unflipped.submitted(at);
    assert_eq!(
        unflipped.choice(at),
        None,
        "Output's switch already decides"
    );

    let mut on = recording(holding_option(true), false);
    on.take(key(J, true, OPTION_KEY_MASK));
    on.submitted(at);
    assert_eq!(on.choice(later), None);
    assert_eq!(on.choice(at), Some(true));
    assert_eq!(on.choice(at), None, "taken once");

    let mut off = recording(holding_option(true), true);
    off.take(key(J, true, OPTION_KEY_MASK));
    off.submitted(at);
    off.submitted(later);
    assert_eq!(off.choice(at), Some(false));
    assert_eq!(
        off.choice(later),
        None,
        "another clip is not this dictation's"
    );
}

#[test]
fn a_cancelled_dictation_keeps_no_choice_and_no_border() {
    let at = Instant::now();
    let mut state = recording(holding_option(true), false);
    state.take(key(J, true, OPTION_KEY_MASK));
    state.cancelled();
    assert!(!state.border());
    state.submitted(at);
    assert_eq!(state.choice(at), None);
}

#[test]
fn a_raw_or_programmatic_capture_shows_no_border_from_the_last_dictation() {
    let mut state = recording(holding_option(true), true);
    state.follow(Recording::Idle);
    assert!(state.border(), "the processing dictation still runs Jev");
    state.follow(Recording::Other);
    assert!(!state.border());
}

#[test]
fn the_profiles_put_jev_in_or_take_it_out_of_every_mode() {
    let mut settings = crate::app_settings::DictationProcessingSettings::default();
    settings.default_mode.transformations =
        vec!["traditional-chinese".into(), "cjk-spacing".into()];
    let profiles = Profiles::from_settings(&settings);
    assert!(!profiles.fork_global_has_jev());
    let on = profiles.clone().fork_with_jev(true);
    assert!(on.fork_global_has_jev());
    assert!(!on.fork_with_jev(false).fork_global_has_jev());
}

#[test]
fn the_key_is_saved_and_read_back() {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let folder =
        std::env::temp_dir().join(format!("qa-hex-jev-key-{}-{nanos}", std::process::id()));
    let path = folder.join("fork").join("jev-key.json");
    assert_eq!(load_setting(&path), None, "nothing saved yet");
    let k = HotkeyBinding {
        modifiers: HotkeyModifiers::default(),
        key: Some(HotkeyKey {
            code: K,
            label: "K".into(),
        }),
    };
    save_setting(&path, &k).unwrap();
    assert_eq!(load_setting(&path), Some(k));
    std::fs::write(&path, b"not json").unwrap();
    assert_eq!(load_setting(&path), None, "unreadable reads as J");
    let _ = std::fs::remove_dir_all(&folder);
}

fn letter(code: u16, label: &str, modifiers: HotkeyModifiers) -> HotkeyBinding {
    HotkeyBinding {
        modifiers,
        key: Some(HotkeyKey {
            code,
            label: label.into(),
        }),
    }
}

#[test]
fn a_key_hex_uses_while_dictating_is_refused() {
    let settings = AppSettings {
        dictation_hotkey: HotkeyBinding {
            modifiers: HotkeyModifiers::option(),
            key: None,
        },
        extra_dictation_hotkeys: vec![crate::app_settings::ExtraDictationHotkey {
            binding: Some(letter(17, "T", HotkeyModifiers::option())),
            mode: crate::app_settings::ExtraDictationMode::Tap,
        }],
        ..AppSettings::default()
    };
    let none = HotkeyModifiers::default();
    assert_eq!(refusal(&settings, &default_binding()), None);
    assert_eq!(refusal(&settings, &letter(K, "K", none)), None);
    assert_eq!(
        refusal(&settings, &letter(17, "T", none)),
        Some(Refusal::InUse),
        "holding ⌥ to dictate, T is the ⌥T shortcut"
    );
    assert_eq!(
        refusal(&settings, &letter(ESCAPE_KEY_CODE, "Esc", none)),
        Some(Refusal::Escape)
    );
    assert_eq!(
        refusal(
            &settings,
            &letter(ESCAPE_KEY_CODE, "Esc", HotkeyModifiers::option())
        ),
        Some(Refusal::Escape),
        "⌥Esc would keep Escape from cancelling an Option dictation"
    );
    assert_eq!(
        refusal(
            &settings,
            &HotkeyBinding {
                modifiers: HotkeyModifiers::option(),
                key: None,
            }
        ),
        Some(Refusal::NeedsKey)
    );
}
