use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc::{self, Sender};
use std::time::{Duration, Instant};

use super::*;

const SECOND: usize = 16_000;

/// A fake Dropline: records each draft's audio length and session, and
/// answers with what the test sends, or at once with `instant`.
struct Fake {
    sent: Arc<Mutex<Vec<(usize, String)>>>,
    answers: Option<Sender<Result<String, Failure>>>,
}

impl Fake {
    fn instant(
        answer: impl Fn(usize) -> Result<String, Failure> + Send + Sync + 'static,
    ) -> (Self, Request) {
        let sent = Arc::new(Mutex::new(Vec::new()));
        let log = sent.clone();
        let request: Request = Arc::new(move |audio: Vec<f32>, session: &str| {
            let number = {
                let mut log = log.lock().unwrap();
                log.push((audio.len(), session.to_owned()));
                log.len()
            };
            answer(number)
        });
        (
            Self {
                sent,
                answers: None,
            },
            request,
        )
    }

    fn held() -> (Self, Request) {
        let sent = Arc::new(Mutex::new(Vec::new()));
        let log = sent.clone();
        let (answers, replies) = mpsc::channel::<Result<String, Failure>>();
        let replies = Mutex::new(replies);
        let request: Request = Arc::new(move |audio: Vec<f32>, session: &str| {
            log.lock().unwrap().push((audio.len(), session.to_owned()));
            replies
                .lock()
                .unwrap()
                .recv_timeout(Duration::from_secs(5))
                .unwrap_or(Err(Failure::Timeout))
        });
        (
            Self {
                sent,
                answers: Some(answers),
            },
            request,
        )
    }

    fn sent(&self) -> Vec<(usize, String)> {
        self.sent.lock().unwrap().clone()
    }

    /// The drafts sent so far, once at least `count` have reached Dropline.
    fn sent_at_least(&self, count: usize) -> Vec<(usize, String)> {
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let sent = self.sent();
            if sent.len() >= count {
                return sent;
            }
            assert!(
                Instant::now() < deadline,
                "only {} drafts reached Dropline",
                sent.len()
            );
            std::thread::sleep(Duration::from_millis(2));
        }
    }

    fn answer(&self, answer: Result<String, Failure>) {
        self.answers.as_ref().unwrap().send(answer).unwrap();
    }
}

fn drafts(request: Request) -> Drafts {
    Drafts::new(true, "qa-session".into(), request)
}

/// Waits until no draft is out.
fn settle(drafts: &Drafts) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while lock(&drafts.reply).out {
        assert!(Instant::now() < deadline, "a draft never came back");
        std::thread::sleep(Duration::from_millis(2));
    }
}

/// Records `seconds` more of audio in 100 ms chunks, reporting after each,
/// and returns every text shown.
fn record(drafts: &mut Drafts, audio: &mut Vec<f32>, seconds: usize, wait: bool) -> Vec<Partial> {
    let mut shown = Vec::new();
    for _ in 0..seconds * 10 {
        audio.extend(std::iter::repeat_n(0.1, SECOND / 10));
        shown.extend(drafts.report(audio));
        if wait {
            settle(drafts);
        }
    }
    shown
}

fn listening() -> Partial {
    Partial {
        stable: String::new(),
        tentative: crate::desktop::i18n::tr("Listening…").to_owned(),
    }
}

fn text(stable: &str) -> Partial {
    Partial {
        stable: stable.into(),
        tentative: String::new(),
    }
}

#[test]
fn drafts_go_out_every_four_seconds_with_the_recording_so_far_in_one_session() {
    let (fake, request) = Fake::instant(|number| Ok(format!("qa-draft {number}")));
    let mut drafts = drafts(request);
    let mut audio = Vec::new();
    record(&mut drafts, &mut audio, 13, true);
    assert_eq!(
        fake.sent(),
        [4, 8, 12].map(|seconds| (seconds * SECOND, "qa-session".to_owned()))
    );
}

#[test]
fn listening_shows_until_the_first_text_arrives() {
    let (fake, request) = Fake::held();
    let mut drafts = drafts(request);
    let mut audio = Vec::new();
    assert_eq!(record(&mut drafts, &mut audio, 4, false), [listening()]);
    assert_eq!(fake.sent_at_least(1).len(), 1);
    fake.answer(Ok("  ".into()));
    settle(&drafts);
    assert_eq!(record(&mut drafts, &mut audio, 1, false), []);
    assert_eq!(record(&mut drafts, &mut audio, 3, false), []);
    fake.answer(Ok("qa-你好".into()));
    settle(&drafts);
    assert_eq!(record(&mut drafts, &mut audio, 1, false), [text("qa-你好")]);
}

#[test]
fn a_round_is_skipped_while_the_last_draft_is_still_out() {
    let (fake, request) = Fake::held();
    let mut drafts = drafts(request);
    let mut audio = Vec::new();
    record(&mut drafts, &mut audio, 9, false);
    assert_eq!(
        fake.sent_at_least(1).len(),
        1,
        "the round at 8 s waits for nothing"
    );
    assert_eq!((drafts.sent, drafts.skipped), (1, 1));
    fake.answer(Ok("qa-一".into()));
    settle(&drafts);
    record(&mut drafts, &mut audio, 3, false);
    assert_eq!(
        fake.sent_at_least(2)
            .iter()
            .map(|(len, _)| len / SECOND)
            .collect::<Vec<_>>(),
        [4, 12]
    );
}

#[test]
fn no_draft_after_180_seconds_and_the_last_text_stays() {
    let (fake, request) = Fake::instant(|number| Ok(format!("qa-draft {number}")));
    let mut drafts = drafts(request);
    let mut audio = Vec::new();
    let shown = record(&mut drafts, &mut audio, 190, true);
    let sent = fake.sent();
    assert_eq!(sent.len(), 45);
    assert_eq!(sent.last().unwrap().0, 180 * SECOND);
    assert_eq!(shown.last(), Some(&text("qa-draft 45")));
    assert_eq!(record(&mut drafts, &mut audio, 8, true), []);
    assert_eq!(fake.sent().len(), 45);
}

#[test]
fn too_many_requests_ends_the_drafts_and_the_text_stays() {
    let (fake, request) = Fake::instant(|number| match number {
        1 => Ok("qa-一".into()),
        _ => Err(Failure::Http(429)),
    });
    let mut drafts = drafts(request);
    let mut audio = Vec::new();
    let shown = record(&mut drafts, &mut audio, 20, true);
    assert_eq!(fake.sent().len(), 2);
    assert_eq!(shown, [listening(), text("qa-一")]);
}

#[test]
fn a_timeout_leaves_the_next_rounds_going() {
    let (fake, request) = Fake::instant(|number| match number {
        1 => Err(Failure::Timeout),
        _ => Ok("qa-二".into()),
    });
    let mut drafts = drafts(request);
    let mut audio = Vec::new();
    let shown = record(&mut drafts, &mut audio, 9, true);
    assert_eq!(fake.sent().len(), 2);
    assert_eq!(shown, [listening(), text("qa-二")]);
}

#[test]
fn without_the_plate_no_draft_goes_out() {
    let calls = Arc::new(AtomicUsize::new(0));
    let counted = calls.clone();
    let mut drafts = Drafts::new(
        false,
        "qa-session".into(),
        Arc::new(move |_, _| {
            counted.fetch_add(1, Ordering::SeqCst);
            Ok("qa-".into())
        }),
    );
    let mut audio = Vec::new();
    assert_eq!(record(&mut drafts, &mut audio, 12, true), []);
    assert_eq!(calls.load(Ordering::SeqCst), 0);
}

/// The capture loop's hooks: with Dropline selected the recording opens no
/// local stream and its live text is the drafts'.
#[test]
fn a_dropline_recording_streams_nothing_to_the_local_model() {
    use crate::dictation::DictationCapture;
    use crate::transcription::engine::TranscriptionEngine;
    SELECTED.set(true);
    let _plate = crate::dictation::live_text::demand();
    let (engine, commands) = TranscriptionEngine::for_test();
    let mut capture = DictationCapture::new(16_000);
    let start = crate::audio::CaptureInstant::from_nanos(60_000_000_000);
    capture.start(start);
    capture.begin_stream(&engine);
    capture.begin_stream(&engine);
    capture.ingest(&[0.1; 1_600], start + Duration::from_millis(100));
    assert!(!capture.is_streaming());
    assert_eq!(commands.try_iter().count(), 0, "the engine got a command");
    assert_eq!(capture.report_live_text(), Some(listening()));
    assert_eq!(capture.report_live_text(), None);
    SELECTED.set(false);
}
