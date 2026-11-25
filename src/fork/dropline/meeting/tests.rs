//! The meeting's Dropline path end to end inside the fork: real cutting,
//! encoding, queueing, and merging, with a scripted transport that refuses
//! any request it doesn't expect. Audio and text are `qa-` stand-ins.

use std::sync::atomic::AtomicUsize;

use super::*;
use client::{Request, Response};

pub(crate) fn scratch(name: &str) -> PathBuf {
    static NEXT: AtomicUsize = AtomicUsize::new(0);
    let path = std::env::temp_dir().join(format!(
        "qa-hex-dropline-{name}-{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ));
    let _ = std::fs::remove_dir_all(&path);
    std::fs::create_dir_all(&path).unwrap();
    path
}

/// What production code gets in tests: any request fails the test.
pub(crate) struct Unscripted;

impl Transport for Unscripted {
    fn send(&self, request: Request<'_>) -> Result<Response, Failure> {
        panic!("an unscripted {} {} in a test", request.method, request.url)
    }
}

const ENDPOINT: &str = "https://qa-worker.example/v1/dropline-private/token";
const CLEAR_URL: &str = "https://qa-worker.example/v1/dropline-private/memory/clear";
const DICTATE: &str = "https://api.dropline.fish.audio/client/dictate";

type Answer = Box<dyn Fn(usize) -> Result<Response, Failure> + Send + Sync>;

/// The Worker and Dropline as a test scripts them; every other request
/// fails the test.
pub(crate) struct Fake {
    token_status: u16,
    dictate: Answer,
    clear: Answer,
    log: Mutex<Vec<&'static str>>,
    dictates: AtomicUsize,
    in_flight: AtomicUsize,
    most: AtomicUsize,
}

impl Fake {
    fn new(dictate: impl Fn(usize) -> Result<Response, Failure> + Send + Sync + 'static) -> Self {
        Self {
            token_status: 200,
            dictate: Box::new(dictate),
            clear: Box::new(|_| Ok(response(200, r#"{"cleared":true}"#))),
            log: Mutex::new(Vec::new()),
            dictates: AtomicUsize::new(0),
            in_flight: AtomicUsize::new(0),
            most: AtomicUsize::new(0),
        }
    }

    /// Answers the segments in the order they are sent.
    pub(crate) fn texts(texts: &'static [&'static str]) -> Self {
        Self::new(move |n| Ok(segment(texts[n])))
    }

    /// Like [`Self::texts`]; `None` answers HTTP 500.
    pub(crate) fn answers(answers: &'static [Option<&'static str>]) -> Self {
        Self::new(move |n| Ok(answers[n].map_or_else(|| response(500, "{}"), segment)))
    }

    fn clearing(mut self, status: u16, body: &'static str) -> Self {
        self.clear = Box::new(move |_| Ok(response(status, body)));
        self
    }

    pub(crate) fn log(&self) -> Vec<&'static str> {
        lock(&self.log).clone()
    }
}

impl Transport for Fake {
    fn send(&self, request: Request<'_>) -> Result<Response, Failure> {
        let kind = match (request.method, request.url) {
            ("GET", ENDPOINT) => "token",
            ("POST", DICTATE) => "dictate",
            ("POST", CLEAR_URL) => "clear",
            (method, url) => panic!("an unexpected {method} {url}"),
        };
        let bearer = if kind == "dictate" {
            "qa-access"
        } else {
            "qa-bearer"
        };
        assert_eq!(request.bearer, bearer, "{kind}");
        lock(&self.log).push(kind);
        match kind {
            "token" => Ok(response(
                self.token_status,
                &format!(
                    r#"{{"access_token":"qa-access","expires_at":{}}}"#,
                    client::now_ms() + 3_600_000
                ),
            )),
            "dictate" => {
                let now = self.in_flight.fetch_add(1, Ordering::SeqCst) + 1;
                self.most.fetch_max(now, Ordering::SeqCst);
                let answer = (self.dictate)(self.dictates.fetch_add(1, Ordering::SeqCst));
                self.in_flight.fetch_sub(1, Ordering::SeqCst);
                answer
            }
            _ => (self.clear)(0),
        }
    }
}

fn response(status: u16, body: &str) -> Response {
    Response {
        status,
        body: body.as_bytes().to_vec(),
        retry_after: None,
    }
}

fn segment(text: &str) -> Response {
    response(
        200,
        &serde_json::json!({"final_text": "qa-final", "transcript": {"text": text}}).to_string(),
    )
}

fn credentials() -> Credentials {
    Credentials {
        endpoint: ENDPOINT.into(),
        bearer: "qa-bearer".into(),
    }
}

fn setup(transport: Arc<Fake>) -> Setup {
    Setup {
        transport,
        credentials: Some(credentials()),
        context: client::Context {
            text: "qa-Hex".into(),
        },
        limit_blocks: 150,
        finish_budget: Duration::from_secs(30),
    }
}

/// A test's meeting, started as `start` would with Dropline selected.
pub(crate) fn recording(directory: &Path, transport: Arc<Fake>) -> Recording {
    start_with(directory, setup(transport))
}

const BLOCK: usize = 320;

/// Speech: loud, with two softer blocks in every ten as between words.
fn speech(blocks: usize) -> Vec<f32> {
    (0..blocks * BLOCK)
        .map(|index| {
            let amplitude = if matches!(index / BLOCK % 10, 4 | 5) {
                0.01
            } else {
                0.3
            };
            amplitude * (index as f32 * 0.3).sin()
        })
        .collect()
}

fn quiet(blocks: usize) -> Vec<f32> {
    vec![0.0001; blocks * BLOCK]
}

fn track(parts: &[(bool, usize)]) -> Vec<f32> {
    parts
        .iter()
        .flat_map(|(loud, blocks)| {
            if *loud {
                speech(*blocks)
            } else {
                quiet(*blocks)
            }
        })
        .collect()
}

/// Offers `samples` at `rate` in 10 ms packets from `position`, as the
/// WAV writer does.
fn feed(directory: &Path, source: MeetingSource, position: &mut u64, rate: u32, samples: &[f32]) {
    for packet in samples.chunks(rate as usize / 100) {
        offer(directory, source, *position, rate, packet);
        *position += packet.len() as u64;
    }
}

fn entry(source: MeetingSource, start_ms: u64, end_ms: u64, text: &str) -> TranscriptEntry {
    TranscriptEntry {
        source,
        start_ms,
        end_ms,
        text: text.into(),
    }
}

/// Stands in for the meeting's merge and echo suppression: drops the
/// microphone entries whose text is in `echo`, sorts, and moves the rest
/// onto the meeting clock.
fn local_join(
    echo: &'static [&'static str],
) -> impl FnOnce(Vec<TranscriptEntry>, u64, ()) -> (Vec<TranscriptEntry>, u64) {
    move |mut entries, origin_ms, ()| {
        let before = entries.len();
        entries.retain(|entry| {
            entry.source != MeetingSource::Microphone || !echo.contains(&entry.text.as_str())
        });
        let dropped = (before - entries.len()) as u64;
        entries.sort_by_key(|entry| entry.start_ms);
        for entry in &mut entries {
            entry.start_ms -= origin_ms;
            entry.end_ms -= origin_ms;
        }
        (entries, dropped)
    }
}

/// The final pass of a live meeting, as `join` runs it.
fn finish(
    recording: &Recording,
    origins: [u64; 2],
    entries: Vec<TranscriptEntry>,
    origin_ms: u64,
    echo: &'static [&'static str],
) -> (Vec<TranscriptEntry>, u64) {
    let input = lock(&LIVE)
        .iter()
        .find(|live| live.directory == recording.directory)
        .map(|live| live.input.clone())
        .unwrap();
    let before = entries.clone();
    let (kept, dropped) = local_join(echo)(entries, origin_ms, ());
    let merged = recording.meeting.complete(&input, |segments| {
        merge(origins, &before, kept, origin_ms, segments)
    });
    (merged, dropped)
}

fn shown(entries: &[TranscriptEntry]) -> Vec<(MeetingSource, u64, u64, &str)> {
    entries
        .iter()
        .map(|entry| {
            (
                entry.source,
                entry.start_ms,
                entry.end_ms,
                entry.text.as_str(),
            )
        })
        .collect()
}

fn summary(directory: &Path) -> sidecar::Summary {
    sidecar::Summary::of(sidecar::read(directory))
}

fn wait_until(what: &str, done: impl Fn() -> bool) {
    let started = Instant::now();
    while !done() {
        assert!(
            started.elapsed() < Duration::from_secs(10),
            "waited too long for {what}"
        );
        thread::sleep(Duration::from_millis(10));
    }
}

const SYSTEM: MeetingSource = MeetingSource::System;
const MICROPHONE: MeetingSource = MeetingSource::Microphone;
/// Each track's first arrival on the capture clock, in ms.
const ORIGINS: [u64; 2] = [10_000, 10_200];

#[test]
fn segments_go_out_one_at_a_time_and_their_words_replace_the_local_text() {
    let directory = scratch("meeting");
    let fake = Arc::new(Fake::texts(&[
        "QA 今天我们讨论头发，还有軟體發佈的時間。",
        "最後確認上線日期。",
        "我們下週上線。好的，沒問題！",
    ]));
    let prepared = super::super::new_session();
    super::super::state().prepared = Some((prepared.clone(), Instant::now()));
    let recording = recording(&directory, fake.clone());
    // System: 2.2 s of speech, a 0.8 s pause (the cut, at block 122), then
    // 1.2 s more. Microphone: echo of the speaker, then the user, 2.4 s in all.
    let mut position = 0;
    feed(
        &directory,
        SYSTEM,
        &mut position,
        16_000,
        &track(&[(true, 110), (false, 40), (true, 60)]),
    );
    let mut position = 0;
    feed(
        &directory,
        MICROPHONE,
        &mut position,
        16_000,
        &track(&[(false, 25), (true, 40), (false, 10), (true, 40), (false, 5)]),
    );
    let entries = vec![
        entry(SYSTEM, 10_100, 11_200, "qa 今天 我們 討論 頭 髮"),
        entry(MICROPHONE, 10_700, 11_500, "我們 下週 上線"),
        entry(SYSTEM, 11_300, 12_200, "還有 軟體 發布 的 時間"),
        entry(MICROPHONE, 11_700, 12_500, "好 的 沒 問題"),
        entry(SYSTEM, 13_000, 14_100, "最後 確認 上線 日期"),
    ];
    let (merged, dropped) = finish(&recording, ORIGINS, entries, 10_000, &["我們 下週 上線"]);
    assert_eq!(dropped, 1);
    assert_eq!(
        shown(&merged),
        [
            (SYSTEM, 100, 1_200, "QA 今天我們討論頭髮，"),
            (SYSTEM, 1_300, 2_200, "還有軟體發佈的時間。"),
            (MICROPHONE, 1_700, 2_500, "好的，沒問題！"),
            (SYSTEM, 3_000, 4_100, "最後確認上線日期。"),
        ]
    );
    let log = fake.log();
    assert_eq!(log.iter().filter(|kind| **kind == "dictate").count(), 3);
    assert_eq!(log.iter().filter(|kind| **kind == "token").count(), 1);
    assert_eq!(log.last(), Some(&"clear"));
    assert_eq!(log.iter().filter(|kind| **kind == "clear").count(), 1);
    assert_eq!(fake.most.load(Ordering::SeqCst), 1);
    let summary = summary(&directory);
    assert!(summary.clear_recorded);
    assert_eq!(
        summary
            .segments
            .iter()
            .map(|segment| (
                segment.track,
                segment.start,
                segment.end,
                segment.state,
                segment.sent
            ))
            .collect::<Vec<_>>(),
        [
            (SYSTEM, 0, 122 * 320, State::Done, true),
            (SYSTEM, 122 * 320, 210 * 320, State::Done, true),
            (MICROPHONE, 0, 120 * 320, State::Done, true),
        ]
    );
    assert!(sidecar::read(&directory).contains(&Line::Start {
        provider: PROVIDER.into()
    }));
    // Dictation's prepared session and General's status are untouched.
    let mut dropline = super::super::state();
    assert_eq!(
        dropline.prepared.take().map(|(session, _)| session),
        Some(prepared)
    );
    assert!(dropline.fallback.is_none());
    drop(dropline);
    drop(recording);
    thread::sleep(Duration::from_millis(50));
    assert_eq!(fake.log().len(), log.len());
}

#[test]
fn a_refused_bearer_stops_the_meeting_and_its_segments_keep_local_text() {
    let directory = scratch("refused");
    let fake = Arc::new(Fake {
        token_status: 401,
        ..Fake::texts(&[])
    });
    let recording = recording(&directory, fake.clone());
    let mut position = 0;
    feed(
        &directory,
        SYSTEM,
        &mut position,
        16_000,
        &track(&[(true, 110), (false, 40), (true, 60)]),
    );
    let entries = vec![
        entry(SYSTEM, 10_100, 11_200, "qa 本機 第一句"),
        entry(SYSTEM, 13_000, 14_100, "qa 本機 第二句"),
    ];
    let (merged, _) = finish(&recording, ORIGINS, entries, 10_000, &[]);
    assert_eq!(
        shown(&merged),
        [
            (SYSTEM, 100, 1_200, "qa 本機 第一句"),
            (SYSTEM, 3_000, 4_100, "qa 本機 第二句"),
        ]
    );
    // One token request, no audio, so no memory clear.
    assert_eq!(fake.log(), ["token"]);
    let summary = summary(&directory);
    assert!(!summary.sent() && !summary.clear_recorded);
    for segment in &summary.segments {
        assert_eq!(segment.state, State::Failed);
        assert_eq!(segment.reason.as_deref(), Some("Token 端點失敗：HTTP 401"));
    }
    assert!(super::super::last_fallback().is_none());
}

#[test]
fn dropline_refusing_twice_stops_sending_and_still_clears_once() {
    let directory = scratch("unauthorized");
    let fake = Arc::new(Fake::new(|_| Ok(response(401, "{}"))));
    let recording = recording(&directory, fake.clone());
    let mut position = 0;
    feed(
        &directory,
        SYSTEM,
        &mut position,
        16_000,
        &track(&[(true, 110), (false, 40), (true, 60)]),
    );
    let entries = vec![entry(SYSTEM, 10_100, 11_200, "qa 本機")];
    let (merged, _) = finish(&recording, ORIGINS, entries, 10_000, &[]);
    assert_eq!(shown(&merged), [(SYSTEM, 100, 1_200, "qa 本機")]);
    assert_eq!(
        fake.log(),
        ["token", "dictate", "token", "dictate", "clear"]
    );
    let summary = summary(&directory);
    assert_eq!(
        summary.segments[0].reason.as_deref(),
        Some("Dropline 授權失敗（401）")
    );
    assert!(summary.segments[0].sent);
    assert!(!summary.segments[1].sent);
    assert_eq!(summary.segments[1].state, State::Failed);
}

#[test]
fn one_request_at_a_time_and_at_most_twenty_segments_wait() {
    let directory = scratch("queue");
    let gate = Arc::new((Mutex::new(false), Condvar::new()));
    let opened = gate.clone();
    let fake = Arc::new(Fake::new(move |n| {
        let (open, changed) = &*opened;
        let mut open = lock(open);
        while !*open {
            open = changed.wait(open).unwrap();
        }
        Ok(segment(&format!("qa-{n}")))
    }));
    let recording = start_with(
        &directory,
        Setup {
            limit_blocks: 20,
            ..setup(fake.clone())
        },
    );
    // Speech without pauses: a segment every 20 blocks.
    let mut position = 0;
    feed(&directory, SYSTEM, &mut position, 16_000, &speech(20));
    wait_until("the first request", || {
        fake.in_flight.load(Ordering::SeqCst) == 1
    });
    feed(&directory, SYSTEM, &mut position, 16_000, &speech(24 * 20));
    wait_until("24 more segments", || {
        recording.meeting.progress().segments.len() == 25
    });
    {
        let progress = recording.meeting.progress();
        assert_eq!(progress.queue.len(), MAX_QUEUED);
        let full = progress
            .segments
            .iter()
            .filter(|segment| segment.reason.as_deref() == Some("佇列已滿"))
            .count();
        assert_eq!(full, 4);
    }
    *lock(&gate.0) = true;
    gate.1.notify_all();
    finish(&recording, ORIGINS, Vec::new(), 10_000, &[]);
    assert_eq!(fake.most.load(Ordering::SeqCst), 1);
    let summary = summary(&directory);
    let done = summary
        .segments
        .iter()
        .filter(|segment| segment.state == State::Done)
        .count();
    assert_eq!(done, 21);
    assert_eq!(fake.dictates.load(Ordering::SeqCst), 21);
}

#[test]
fn the_final_pass_waits_at_most_its_budget_then_keeps_local_text() {
    let directory = scratch("budget");
    let fake = Arc::new(Fake::new(|_| {
        thread::sleep(Duration::from_millis(1_500));
        Ok(segment("qa-太晚了"))
    }));
    let recording = start_with(
        &directory,
        Setup {
            finish_budget: Duration::from_millis(300),
            ..setup(fake.clone())
        },
    );
    let mut position = 0;
    feed(&directory, SYSTEM, &mut position, 16_000, &speech(40));
    let entries = vec![entry(SYSTEM, 10_100, 10_700, "qa 本機")];
    let started = Instant::now();
    let (merged, _) = finish(&recording, ORIGINS, entries, 10_000, &[]);
    assert!(
        started.elapsed() < Duration::from_millis(1_200),
        "{:?}",
        started.elapsed()
    );
    assert_eq!(shown(&merged), [(SYSTEM, 100, 700, "qa 本機")]);
    // The clear waits for the request still in flight.
    assert_eq!(fake.log(), ["token", "dictate"]);
    wait_until("the clear", || fake.log().contains(&"clear"));
    assert_eq!(fake.log(), ["token", "dictate", "clear"]);
    let summary = summary(&directory);
    assert_eq!(summary.segments[0].state, State::Failed);
    assert_eq!(summary.segments[0].reason.as_deref(), Some("定稿等待逾時"));
    assert!(summary.segments[0].sent && summary.clear_recorded);
}

#[test]
fn a_meeting_that_ends_without_its_final_pass_cancels_the_queue_and_clears_after_the_request() {
    let directory = scratch("dropped");
    let fake = Arc::new(Fake::new(|_| {
        thread::sleep(Duration::from_millis(400));
        Ok(segment("qa-第一段"))
    }));
    let recording = recording(&directory, fake.clone());
    let mut position = 0;
    feed(
        &directory,
        SYSTEM,
        &mut position,
        16_000,
        &track(&[(true, 110), (false, 40), (true, 110), (false, 40)]),
    );
    wait_until("two segments", || {
        recording.meeting.progress().segments.len() == 2
    });
    wait_until("the first request", || {
        fake.in_flight.load(Ordering::SeqCst) == 1
    });
    drop(recording);
    wait_until("the clear", || fake.log().contains(&"clear"));
    assert_eq!(fake.log(), ["token", "dictate", "clear"]);
    let summary = summary(&directory);
    assert_eq!(summary.segments[0].state, State::Done);
    assert_eq!(summary.segments[1].state, State::Failed);
    assert_eq!(summary.segments[1].reason.as_deref(), Some("會議中止"));
    assert!(summary.clear_recorded);
}

#[test]
fn a_quiet_segment_is_done_without_a_request() {
    let directory = scratch("quiet");
    let fake = Arc::new(Fake::texts(&[]));
    let recording = recording(&directory, fake.clone());
    let mut position = 0;
    feed(&directory, MICROPHONE, &mut position, 16_000, &quiet(60));
    let entries = vec![entry(MICROPHONE, 10_300, 10_900, "qa 本機 聽到")];
    let (merged, _) = finish(&recording, ORIGINS, entries, 10_000, &[]);
    assert_eq!(shown(&merged), [(MICROPHONE, 300, 900, "qa 本機 聽到")]);
    assert!(fake.log().is_empty());
    let summary = summary(&directory);
    assert_eq!(summary.segments[0].state, State::Done);
    assert_eq!(summary.segments[0].text.as_deref(), Some(""));
    assert!(!summary.sent() && !summary.clear_recorded);
}

#[test]
fn segments_keep_wav_positions_across_a_gap_at_48_khz() {
    let directory = scratch("gap");
    let fake = Arc::new(Fake::texts(&["qa-前", "qa-後"]));
    let recording = recording(&directory, fake.clone());
    let at_48k = |samples: Vec<f32>| -> Vec<f32> {
        samples.iter().flat_map(|sample| [*sample; 3]).collect()
    };
    let mut position = 0;
    feed(
        &directory,
        SYSTEM,
        &mut position,
        48_000,
        &at_48k(speech(30)),
    );
    // The writer padded a second of silence: the next packet is 48 000
    // samples later.
    position += 48_000;
    feed(
        &directory,
        SYSTEM,
        &mut position,
        48_000,
        &at_48k(speech(30)),
    );
    finish(&recording, ORIGINS, Vec::new(), 10_000, &[]);
    let segments = summary(&directory).segments;
    assert_eq!(segments.len(), 2);
    let close = |actual: u64, expected: u64| actual.abs_diff(expected) <= 64;
    assert_eq!(segments[0].start, 0);
    assert!(close(segments[0].end, 30 * 320), "{:?}", segments[0]);
    assert_eq!(segments[1].start, (30 * 960 + 48_000) / 3);
    assert!(
        close(segments[1].end, (30 * 960 + 48_000) / 3 + 30 * 320),
        "{:?}",
        segments[1]
    );
}

/// A sidecar as a meeting Hex quit in leaves it.
fn interrupted(directory: &Path) {
    let mut writer = sidecar::Writer::new(directory);
    let line = |seq: u32, start: u64, end: u64, state: State, sent: bool, text: Option<&str>| {
        Line::Segment(SegmentLine {
            track: SYSTEM,
            seq,
            start,
            end,
            state,
            sent,
            text: text.map(str::to_owned),
            reason: None,
        })
    };
    for line in [
        Line::Start {
            provider: PROVIDER.into(),
        },
        line(
            1,
            0,
            32_000,
            State::Done,
            true,
            Some("QA 已經答覆的第一段。"),
        ),
        line(2, 32_000, 64_000, State::Sending, true, None),
        line(3, 64_000, 96_000, State::Queued, false, None),
    ] {
        writer.write(&line);
    }
}

fn interrupted_entries() -> Vec<TranscriptEntry> {
    vec![
        entry(SYSTEM, 10_200, 11_500, "qa 已經 答覆 的 第一 段"),
        entry(SYSTEM, 12_300, 13_500, "qa 送出 沒 回應"),
        entry(SYSTEM, 14_300, 15_500, "qa 還沒 送"),
    ]
}

#[test]
fn the_next_launch_reuses_answered_segments_sends_no_audio_and_clears_once() {
    let directory = scratch("backfill");
    interrupted(&directory);
    let fake = Fake::new(|_| panic!("audio was sent again"));
    let entries = interrupted_entries();
    let (kept, _) = local_join(&[])(entries.clone(), 10_000, ());
    let merged = backfill(
        &directory,
        ORIGINS,
        &entries,
        kept,
        10_000,
        &fake,
        Some(&credentials()),
    );
    assert_eq!(
        shown(&merged),
        [
            (SYSTEM, 200, 1_500, "QA 已經答覆的第一段。"),
            (SYSTEM, 2_300, 3_500, "qa 送出 沒 回應"),
            (SYSTEM, 4_300, 5_500, "qa 還沒 送"),
        ]
    );
    assert_eq!(fake.log(), ["clear"]);
    assert!(summary(&directory).clear_recorded);
    let (kept, _) = local_join(&[])(entries.clone(), 10_000, ());
    backfill(
        &directory,
        ORIGINS,
        &entries,
        kept,
        10_000,
        &fake,
        Some(&credentials()),
    );
    assert_eq!(fake.log(), ["clear"]);
}

#[test]
fn every_memory_clear_outcome_is_recorded_without_its_content() {
    for (status, body, result, reason) in [
        (200, r#"{"cleared":true}"#, "cleared", None),
        (
            200,
            r#"{"cleared":false,"note":"qa-detail"}"#,
            "not_cleared",
            None,
        ),
        (403, r#"{"error":"qa-detail"}"#, "failed", Some("HTTP 403")),
        (429, "{}", "failed", Some("HTTP 429")),
    ] {
        let directory = scratch("clear");
        interrupted(&directory);
        let fake = Fake::texts(&[]).clearing(status, body);
        let entries = interrupted_entries();
        backfill(
            &directory,
            ORIGINS,
            &entries,
            entries.clone(),
            10_000,
            &fake,
            Some(&credentials()),
        );
        assert_eq!(fake.log(), ["clear"]);
        let lines = sidecar::read(&directory);
        assert_eq!(
            lines.last(),
            Some(&Line::Clear {
                result: result.into(),
                reason: reason.map(str::to_owned),
            })
        );
        let text = std::fs::read_to_string(directory.join(sidecar::FILE)).unwrap();
        assert!(!text.contains("qa-detail"));
    }
    // An endpoint without the Worker's path: no call, recorded as skipped.
    let directory = scratch("clear");
    interrupted(&directory);
    let other = Credentials {
        endpoint: "https://qa-worker.example/v1/token".into(),
        bearer: "qa-bearer".into(),
    };
    let entries = interrupted_entries();
    backfill(
        &directory,
        ORIGINS,
        &entries,
        entries.clone(),
        10_000,
        &Unscripted,
        Some(&other),
    );
    assert!(matches!(
        sidecar::read(&directory).last(),
        Some(Line::Clear { result, .. }) if result == "skipped"
    ));
    // No provider any more: nothing is called.
    let directory = scratch("clear");
    interrupted(&directory);
    backfill(
        &directory,
        ORIGINS,
        &entries,
        entries.clone(),
        10_000,
        &Unscripted,
        None,
    );
    assert!(matches!(
        sidecar::read(&directory).last(),
        Some(Line::Clear { result, .. }) if result == "failed"
    ));
}

#[test]
fn a_meeting_that_sent_nothing_is_not_cleared() {
    let directory = scratch("unsent");
    let mut writer = sidecar::Writer::new(&directory);
    writer.write(&Line::Start {
        provider: PROVIDER.into(),
    });
    writer.write(&Line::Segment(SegmentLine {
        track: SYSTEM,
        seq: 1,
        start: 0,
        end: 32_000,
        state: State::Queued,
        sent: false,
        text: None,
        reason: None,
    }));
    let entries = interrupted_entries();
    let merged = backfill(
        &directory,
        ORIGINS,
        &entries,
        entries.clone(),
        10_000,
        &Unscripted,
        Some(&credentials()),
    );
    assert_eq!(merged, entries);
    assert!(!summary(&directory).clear_recorded);
}
