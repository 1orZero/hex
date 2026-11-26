//! Dropline's live text while a hotkey dictation records (macOS). This is
//! `crate::dictation`'s child (`dictation.rs` names this file), so it reads
//! the recording it serves.
//!
//! While Dropline is selected a capture opens no local stream, so no local
//! model runs while it records. With live text wanted (Labs › Live text, or
//! the first run's practice), the recording's live text reads Listening…
//! until Dropline's first words, and every 4 s the whole recording so far
//! goes to Dropline in the session the recording's final request uses (taken
//! once, when the recording starts showing); a round is skipped while the
//! previous request is out,
//! and none goes once the recording passes 180 s, which keeps the last words
//! shown. The recording's own live text holder shows it, so the text leaves
//! with the recording.

use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use super::{DictationCapture, Fft, Recording, Resampler};
use crate::audio::CaptureInstant;
use crate::transcription::engine::Partial;

const EVERY: Duration = Duration::from_secs(4);
/// No request goes once the recording holds more 16 kHz audio than this.
const LIVE_SAMPLES: usize = 180 * 16_000;

/// The recording being served.
struct Live {
    recording: CaptureInstant,
    /// The Dropline session, while the recording shows live text.
    session: Option<String>,
    next: Instant,
    answer: Arc<Mutex<Answer>>,
}

/// One recording's request in flight and Dropline's newest words for it.
#[derive(Default)]
struct Answer {
    waiting: bool,
    text: Option<String>,
}

static LIVE: Mutex<Option<Live>> = Mutex::new(None);

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|error| error.into_inner())
}

impl DictationCapture {
    /// Runs where a hotkey capture past its hold threshold opens its local
    /// stream, on every chunk: true, so the capture opens none, while
    /// Dropline is selected.
    pub(super) fn fork_dropline_live(&mut self) -> bool {
        if !crate::fork::dropline::selected() {
            return false;
        }
        let Some(recording) = &mut self.recording else {
            return true;
        };
        let shown = tick(
            recording,
            &mut lock(&LIVE),
            Instant::now(),
            || {
                let wanted = !cfg!(test)
                    && (crate::labs::live_text() || crate::dictation::live_text::board_demanded());
                wanted.then(crate::fork::dropline::live_session)
            },
            send,
        );
        if let Some(partial) = shown {
            recording
                .live_text
                .get_or_insert_with(crate::dictation::live_text::Publisher::new)
                .show(&partial);
        }
        true
    }
}

/// What the recording's live text should show now, if it changes.
/// `session` is asked once per recording: the Dropline session when live
/// text is wanted, else `None`.
fn tick(
    recording: &Recording,
    live: &mut Option<Live>,
    now: Instant,
    session: impl FnOnce() -> Option<String>,
    send: impl FnOnce(Vec<f32>, String, Arc<Mutex<Answer>>),
) -> Option<Partial> {
    let mut shown = None;
    if live
        .as_ref()
        .is_none_or(|live| live.recording != recording.started_at)
    {
        let session = session();
        if session.is_some() {
            shown = Some(Partial {
                stable: String::new(),
                tentative: crate::desktop::i18n::tr("Listening…").to_owned(),
            });
        }
        *live = Some(Live {
            recording: recording.started_at,
            session,
            next: now + EVERY,
            answer: Arc::default(),
        });
    }
    let live = live.as_mut()?;
    let session = live.session.clone()?;
    let text = lock(&live.answer).text.take();
    if let Some(text) = text.filter(|text| !text.trim().is_empty()) {
        shown = Some(Partial {
            stable: text,
            tentative: String::new(),
        });
    }
    if now < live.next {
        return shown;
    }
    while live.next <= now {
        live.next += EVERY;
    }
    let delay = recording.resampler.as_ref().map_or(0, Fft::output_delay);
    let audio = &recording.samples[delay.min(recording.samples.len())..];
    if audio.len() > LIVE_SAMPLES {
        return shown;
    }
    {
        let mut answer = lock(&live.answer);
        if answer.waiting {
            return shown;
        }
        answer.waiting = true;
    }
    send(audio.to_vec(), session, live.answer.clone());
    shown
}

/// Asks Dropline on its own thread; the capture shows the answer on its
/// next chunk.
fn send(audio: Vec<f32>, session: String, answer: Arc<Mutex<Answer>>) {
    let reply = answer.clone();
    let started = std::thread::Builder::new()
        .name("hex-dropline-live".into())
        .spawn(move || {
            let text = crate::fork::dropline::live(audio, session);
            let mut reply = lock(&reply);
            reply.waiting = false;
            if text.is_some() {
                reply.text = text;
            }
        });
    if let Err(error) = started {
        tracing::warn!(%error, "could not start a Dropline live request");
        lock(&answer).waiting = false;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::dictation::Finish;
    use crate::transcription::engine::{Command, TranscriptionEngine};

    const SECOND: usize = 16_000;

    /// A hotkey capture past its hold threshold, holding `seconds` of audio.
    fn recording(seconds: usize) -> (DictationCapture, CaptureInstant) {
        let mut capture = DictationCapture::new(16_000);
        let start = CaptureInstant::from_nanos(1_000_000_000_000);
        capture.start(start);
        assert!(capture.become_intentional(start + super::super::MINIMUM_HOLD_DURATION));
        let mut through = start;
        more(&mut capture, &mut through, seconds);
        (capture, through)
    }

    fn more(capture: &mut DictationCapture, through: &mut CaptureInstant, seconds: usize) {
        for _ in 0..seconds * 10 {
            *through = *through + Duration::from_millis(100);
            capture.ingest(&[0.25; SECOND / 10], *through);
        }
    }

    /// Ticks with live text wanted: each request's length, session, and
    /// reply slot, what the live text shows, and how often a session was
    /// asked for.
    struct Ticks {
        live: Option<Live>,
        session: &'static str,
        sessions_taken: usize,
        sent: Vec<(usize, String, Arc<Mutex<Answer>>)>,
        shown: Option<Partial>,
    }

    impl Ticks {
        fn new() -> Self {
            Self {
                live: None,
                session: "qa-session",
                sessions_taken: 0,
                sent: Vec::new(),
                shown: None,
            }
        }

        fn at(&mut self, capture: &DictationCapture, now: Instant) {
            let sent = &mut self.sent;
            let taken = &mut self.sessions_taken;
            let session = self.session;
            let shown = tick(
                capture.recording.as_ref().unwrap(),
                &mut self.live,
                now,
                || {
                    *taken += 1;
                    Some(session.to_owned())
                },
                |audio, session, answer| sent.push((audio.len(), session, answer)),
            );
            if shown.is_some() {
                self.shown = shown;
            }
        }

        fn shows(&self) -> Option<(&str, &str)> {
            self.shown
                .as_ref()
                .map(|partial| (partial.stable.as_str(), partial.tentative.as_str()))
        }

        fn reply(&self, request: usize, text: &str) {
            let mut answer = lock(&self.sent[request].2);
            answer.waiting = false;
            answer.text = Some(text.into());
        }
    }

    #[test]
    fn listening_shows_until_the_first_words_then_every_four_seconds_sends_the_recording() {
        let (mut capture, mut through) = recording(1);
        let mut ticks = Ticks::new();
        let t0 = Instant::now();
        ticks.at(&capture, t0);
        assert_eq!(ticks.shows(), Some(("", "Listening…")));
        assert!(ticks.sent.is_empty(), "nothing goes before 4 s");
        ticks.at(&capture, t0 + Duration::from_millis(3_990));
        assert!(ticks.sent.is_empty());
        more(&mut capture, &mut through, 3);
        ticks.at(&capture, t0 + EVERY);
        assert_eq!(ticks.sent.len(), 1);
        assert!(
            ticks.sent[0].0 >= 4 * SECOND,
            "the whole recording so far: {}",
            ticks.sent[0].0
        );
        assert_eq!(ticks.shows(), Some(("", "Listening…")));
        ticks.reply(0, "qa-第一段");
        ticks.at(&capture, t0 + EVERY + Duration::from_millis(10));
        assert_eq!(ticks.shows(), Some(("qa-第一段", "")));
        more(&mut capture, &mut through, 4);
        ticks.at(&capture, t0 + 2 * EVERY);
        assert_eq!(ticks.sent.len(), 2);
        assert!(ticks.sent[1].0 >= 8 * SECOND, "{}", ticks.sent[1].0);
        assert_eq!(ticks.sessions_taken, 1, "the session is taken once");
        assert!(
            ticks
                .sent
                .iter()
                .all(|(_, session, _)| session == "qa-session")
        );
    }

    #[test]
    fn an_empty_answer_keeps_listening() {
        let (capture, _) = recording(1);
        let mut ticks = Ticks::new();
        let t0 = Instant::now();
        ticks.at(&capture, t0);
        ticks.at(&capture, t0 + EVERY);
        ticks.reply(0, " ");
        ticks.at(&capture, t0 + EVERY + Duration::from_millis(10));
        assert_eq!(ticks.shows(), Some(("", "Listening…")));
    }

    #[test]
    fn a_round_is_skipped_while_the_previous_request_is_out() {
        let (capture, _) = recording(1);
        let mut ticks = Ticks::new();
        let t0 = Instant::now();
        ticks.at(&capture, t0);
        ticks.at(&capture, t0 + EVERY);
        ticks.at(&capture, t0 + 2 * EVERY);
        ticks.at(&capture, t0 + 2 * EVERY + Duration::from_secs(1));
        assert_eq!(
            ticks.sent.len(),
            1,
            "the 8 s round is skipped, and not made up"
        );
        ticks.reply(0, "qa-慢");
        ticks.at(&capture, t0 + 2 * EVERY + Duration::from_secs(2));
        assert_eq!(ticks.sent.len(), 1, "the next round waits for 12 s");
        ticks.at(&capture, t0 + 3 * EVERY);
        assert_eq!(ticks.sent.len(), 2);
        for round in 4..=15 {
            ticks.reply(ticks.sent.len() - 1, "qa-快");
            ticks.at(&capture, t0 + round * EVERY);
        }
        assert_eq!(ticks.sent.len(), 14, "a minute holds at most 15 rounds");
    }

    #[test]
    fn nothing_goes_once_the_recording_passes_180_seconds_and_the_last_words_stay() {
        let (mut capture, mut through) = recording(176);
        let mut ticks = Ticks::new();
        let t0 = Instant::now();
        ticks.at(&capture, t0);
        ticks.at(&capture, t0 + EVERY);
        assert_eq!(ticks.sent.len(), 1);
        ticks.reply(0, "qa-最後");
        more(&mut capture, &mut through, 5);
        ticks.at(&capture, t0 + 2 * EVERY);
        ticks.at(&capture, t0 + 3 * EVERY);
        assert_eq!(ticks.sent.len(), 1, "181 s of audio sends nothing");
        assert_eq!(ticks.shows(), Some(("qa-最後", "")));
    }

    #[test]
    fn without_live_text_nothing_shows_and_nothing_goes() {
        let (capture, _) = recording(1);
        let mut live = None;
        let mut sent = 0;
        let t0 = Instant::now();
        for round in 0..4 {
            let shown = tick(
                capture.recording.as_ref().unwrap(),
                &mut live,
                t0 + round * EVERY,
                || None,
                |_, _, _| sent += 1,
            );
            assert!(shown.is_none());
        }
        assert_eq!(sent, 0);
    }

    #[test]
    fn a_new_recording_starts_over_and_drops_the_old_answer() {
        let (capture, _) = recording(1);
        let mut ticks = Ticks::new();
        let t0 = Instant::now();
        ticks.at(&capture, t0);
        ticks.at(&capture, t0 + EVERY);
        let (mut next, _) = recording(1);
        next.recording.as_mut().unwrap().started_at = CaptureInstant::from_nanos(2_000_000_000_000);
        ticks.reply(0, "qa-舊的");
        ticks.shown = None;
        ticks.session = "qa-next-session";
        ticks.at(&next, t0 + EVERY + Duration::from_secs(1));
        assert_eq!(ticks.shows(), Some(("", "Listening…")));
        ticks.at(&next, t0 + EVERY + Duration::from_secs(2));
        assert_eq!(ticks.shows(), Some(("", "Listening…")));
        assert_eq!(ticks.sent.len(), 1, "the new recording waits its own 4 s");
        ticks.at(&next, t0 + 2 * EVERY + Duration::from_secs(1));
        assert_eq!(ticks.sent.len(), 2);
        assert_eq!(ticks.sent[1].1, "qa-next-session");
        assert_eq!(ticks.sessions_taken, 2);
    }

    /// Begin, feed, or finish commands the engine received.
    fn engine_work(commands: &std::sync::mpsc::Receiver<Command>) -> usize {
        commands
            .try_iter()
            .filter(|command| {
                matches!(
                    command,
                    Command::Begin { .. } | Command::Feed { .. } | Command::Finish { .. }
                )
            })
            .count()
    }

    #[test]
    fn while_dropline_is_selected_the_capture_opens_no_local_stream() {
        crate::fork::dropline::select_for_test(true);
        let (engine, commands) = TranscriptionEngine::for_test();
        let (mut capture, mut through) = recording(1);
        for _ in 0..5 {
            capture.begin_stream(&engine);
            more(&mut capture, &mut through, 1);
        }
        assert!(!capture.is_streaming());
        let Finish::Transcribe(mut clip) = capture.finish(through) else {
            panic!("expected a clip");
        };
        assert!(clip.take_stream().is_none());
        assert_eq!(
            engine_work(&commands),
            0,
            "no local model ran while it recorded"
        );
        crate::fork::dropline::select_for_test(false);
        let (mut capture, mut through) = recording(1);
        capture.begin_stream(&engine);
        more(&mut capture, &mut through, 1);
        assert!(
            capture.is_streaming(),
            "without Dropline the capture streams as before"
        );
        assert!(engine_work(&commands) > 0);
    }
}
