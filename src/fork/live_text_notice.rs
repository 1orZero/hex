//! Hex fork (see FORK.md): confirmations on the live text plate beside the
//! HUD, for actions that happen away from the window. Declared from
//! `rune_ui/live_text.rs`, so it reads the plate's private state; a change
//! to that state upstream shows up here as a build error.

use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

/// How long a confirmation stays beside the HUD.
const VISIBLE: Duration = Duration::from_secs(4);

/// The newest confirmation, so an older one's timer never hides it.
static SHOWN: AtomicU64 = AtomicU64::new(0);

/// Shows `message` in the live words' colour for [`VISIBLE`]. A dictation's
/// words or a failure notice already on the plate keep it.
pub(crate) fn show(message: String) {
    let (Some(overlay), Some(place)) = (super::LIVE.get(), super::PLACE.get().copied()) else {
        return;
    };
    let generation = SHOWN.fetch_add(1, Ordering::AcqRel) + 1;
    let handle = overlay.clone();
    overlay.update(move |plate, tx| {
        if plate.live || plate.failure.is_some() {
            return;
        }
        plate.stable = message;
        plate.tentative.clear();
        tx.instant();
        if !plate.shown {
            place().apply(&handle);
            handle.show();
            plate.mark_shown(true);
        }
    });
    let overlay = overlay.clone();
    let _ = std::thread::Builder::new()
        .name("hex-fork-notice".into())
        .spawn(move || {
            std::thread::sleep(VISIBLE);
            let handle = overlay.clone();
            overlay.update(move |plate, _| {
                let newest = SHOWN.load(Ordering::Acquire) == generation;
                if !newest || plate.live || plate.failure.is_some() || !plate.shown {
                    return;
                }
                handle.fade_out(super::FADE);
                plate.mark_shown(false);
            });
        });
}

/// Shows `message` as a failure notice, whether or not Labs › Failure
/// notices is on: it leaves after the notice's own time or when a capture
/// starts.
pub(crate) fn show_failure(message: String) {
    let (Some(overlay), Some(place)) = (super::LIVE.get(), super::PLACE.get().copied()) else {
        return;
    };
    let deadline = super::notice().show(message.clone(), Instant::now());
    super::schedule(deadline);
    let handle = overlay.clone();
    overlay.update(move |plate, tx| {
        plate.show_failure(message);
        tx.instant();
        if !plate.shown {
            place().apply(&handle);
            handle.show();
            plate.mark_shown(true);
        }
    });
}
