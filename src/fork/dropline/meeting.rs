//! Meetings through Dropline (macOS; ADR-0001, 0003, 0004, 0005, 0007,
//! 0008). A meeting that starts while Dropline is selected copies each
//! track's audio from the WAV writer, cuts it at pauses into segments of up
//! to 178 s (`segmenter`), and sends them one at a time on its own thread
//! while the meeting goes on; the in-call draft stays local. At the final
//! pass the local transcript is merged and echo-suppressed as before, then
//! each entry inside an answered segment takes Dropline's words for it
//! (`align`); every other entry keeps its local text. Progress goes to
//! `fork-dropline.ndjson` (`sidecar`), so a meeting finished at the next
//! launch reuses what Dropline answered and sends no audio again. After the
//! meeting's last possible send, the Worker's memory clear runs once and its
//! outcome is recorded.

mod align;
mod segmenter;
mod sidecar;

use std::collections::VecDeque;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, SyncSender, TrySendError};
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::thread;
use std::time::{Duration, Instant};

use super::client::{self, Cleared, Failure, Transport};
use crate::dictation::StreamingResampler;
use crate::meeting::{MeetingManifest, MeetingSource, TranscriptEntry};
use segmenter::{Cut, Segmenter};
use sidecar::{Line, SegmentLine, State};

const PROVIDER: &str = "dropline-private";
/// Segments waiting to be sent; more fail at once.
const MAX_QUEUED: usize = 20;
/// The final pass waits this long for the tail and the queue.
const FINISH_BUDGET: Duration = Duration::from_secs(180);
/// Packets the WAV writer may get ahead of the cutter; later ones are a gap.
const BACKLOG: usize = 4096;
/// How long a stopped meeting waits for its request in flight before the
/// memory clear.
const DRAIN: Duration = Duration::from_secs(65);
const RATE: u64 = 16_000;

type SharedTransport = Arc<dyn Transport + Send + Sync>;

/// The token endpoint and Worker bearer, read once when the meeting starts.
#[derive(Clone)]
struct Credentials {
    endpoint: String,
    bearer: String,
}

/// What a meeting is set up with; tests shorten the limits.
struct Setup {
    transport: SharedTransport,
    credentials: Option<Credentials>,
    context: client::Context,
    limit_blocks: usize,
    finish_budget: Duration,
}

/// A recording meeting that sends to Dropline. Dropping it before the final
/// pass stops the meeting's sends; unless Hex is quitting, the memory clear
/// then runs once the request in flight is over.
pub(crate) struct Recording {
    directory: PathBuf,
    meeting: Arc<Meeting>,
}

struct Live {
    directory: PathBuf,
    input: SyncSender<Input>,
    meeting: Arc<Meeting>,
    behind: AtomicBool,
}

static LIVE: Mutex<Vec<Live>> = Mutex::new(Vec::new());

enum Input {
    Audio {
        source: MeetingSource,
        position: u64,
        rate: u32,
        samples: Vec<f32>,
    },
    /// Stop: cut the tails, then answer.
    Finish(SyncSender<()>),
}

struct Meeting {
    transport: SharedTransport,
    credentials: Option<Credentials>,
    context: client::Context,
    limit_blocks: usize,
    finish_budget: Duration,
    progress: Mutex<Progress>,
    changed: Condvar,
}

struct Progress {
    sidecar: sidecar::Writer,
    segments: Vec<SegmentLine>,
    /// Encoded segments waiting, by their index in `segments`.
    queue: VecDeque<(usize, Vec<u8>)>,
    sending: bool,
    /// The cutter queued the tails or stopped.
    cut: bool,
    /// Why the meeting sends nothing more.
    stopped: Option<String>,
    /// The final pass took the segments: later answers are not recorded.
    merged: bool,
    clear_ran: bool,
    tokens: client::TokenCache,
    next_seq: u32,
}

/// Starts sending the meeting in `directory` when Dropline is selected,
/// with the provider as it is now. Never in tests.
pub(crate) fn start(directory: &Path) -> Option<Recording> {
    if cfg!(test) || !super::selected() {
        return None;
    }
    Some(start_with(
        directory,
        Setup {
            transport: Arc::new(client::Http),
            credentials: saved_credentials(),
            context: super::context(&crate::dictation::vocabulary::terms()),
            limit_blocks: segmenter::LIMIT_BLOCKS,
            finish_budget: FINISH_BUDGET,
        },
    ))
}

fn start_with(directory: &Path, setup: Setup) -> Recording {
    let mut sidecar = sidecar::Writer::new(directory);
    sidecar.write(&Line::Start {
        provider: PROVIDER.into(),
    });
    let stopped = setup
        .credentials
        .is_none()
        .then(|| Failure::NotConfigured.to_string());
    let meeting = Arc::new(Meeting {
        transport: setup.transport,
        credentials: setup.credentials,
        context: setup.context,
        limit_blocks: setup.limit_blocks,
        finish_budget: setup.finish_budget,
        progress: Mutex::new(Progress {
            sidecar,
            segments: Vec::new(),
            queue: VecDeque::new(),
            sending: false,
            cut: false,
            stopped,
            merged: false,
            clear_ran: false,
            tokens: client::TokenCache::new(),
            next_seq: 1,
        }),
        changed: Condvar::new(),
    });
    let (input, receiver) = mpsc::sync_channel(BACKLOG);
    let cutter = Arc::clone(&meeting);
    let sender = Arc::clone(&meeting);
    let started = thread::Builder::new()
        .name("hex-dropline-meeting-cut".into())
        .spawn(move || run_cutter(&cutter, receiver))
        .and_then(|_| {
            thread::Builder::new()
                .name("hex-dropline-meeting-send".into())
                .spawn(move || run_sender(&sender))
        });
    if let Err(error) = started {
        tracing::warn!(%error, "could not start the meeting's Dropline threads");
        let mut progress = meeting.progress();
        progress.cut = true;
        meeting.stop(&mut progress, "無法啟動".into());
    }
    tracing::info!(provider = PROVIDER, "meeting segments go to Dropline");
    lock(&LIVE).push(Live {
        directory: directory.to_owned(),
        input,
        meeting: Arc::clone(&meeting),
        behind: AtomicBool::new(false),
    });
    Recording {
        directory: directory.to_owned(),
        meeting,
    }
}

/// The WAV writer's packet: its track, its place in the WAV, and its
/// samples. Never waits; a packet the cutter can't take now becomes a gap
/// that keeps its local text.
pub(crate) fn offer(
    directory: &Path,
    source: MeetingSource,
    position: u64,
    rate: u32,
    samples: &[f32],
) {
    let live = lock(&LIVE);
    let Some(live) = live.iter().find(|live| live.directory == directory) else {
        return;
    };
    let audio = Input::Audio {
        source,
        position,
        rate,
        samples: samples.to_vec(),
    };
    if let Err(TrySendError::Full(_)) = live.input.try_send(audio)
        && !live.behind.swap(true, Ordering::Relaxed)
    {
        tracing::warn!("meeting audio for Dropline is behind; that stretch keeps its local text");
    }
}

/// The final pass: `join` merges and echo-suppresses `entries` as before;
/// a meeting sent to Dropline, now or before Hex quit, then puts Dropline's
/// words in the entries its answered segments cover.
pub(crate) fn join<E>(
    directory: &Path,
    manifest: &MeetingManifest,
    entries: Vec<TranscriptEntry>,
    origin_ms: u64,
    envelope: E,
    join: impl FnOnce(Vec<TranscriptEntry>, u64, E) -> (Vec<TranscriptEntry>, u64),
) -> (Vec<TranscriptEntry>, u64) {
    let live = lock(&LIVE)
        .iter()
        .find(|live| live.directory == directory)
        .map(|live| (live.input.clone(), Arc::clone(&live.meeting)));
    if live.is_none() && !sidecar::exists(directory) {
        return join(entries, origin_ms, envelope);
    }
    let origins = [&manifest.system, &manifest.microphone]
        .map(|track| track.first_arrival_us.unwrap_or_default() / 1_000);
    let before = entries.clone();
    let (kept, dropped) = join(entries, origin_ms, envelope);
    let kept = match live {
        Some((input, meeting)) => meeting.complete(&input, |segments| {
            merge(origins, &before, kept, origin_ms, segments)
        }),
        None => backfill(
            directory,
            origins,
            &before,
            kept,
            origin_ms,
            &*production(),
            saved_credentials().as_ref(),
        ),
    };
    (kept, dropped)
}

/// A meeting Hex quit in, finished at the next launch: the segments
/// Dropline answered, and one memory clear if audio was sent and the clear
/// never ran.
fn backfill(
    directory: &Path,
    origins: [u64; 2],
    before: &[TranscriptEntry],
    kept: Vec<TranscriptEntry>,
    origin_ms: u64,
    transport: &dyn Transport,
    credentials: Option<&Credentials>,
) -> Vec<TranscriptEntry> {
    let summary = sidecar::Summary::of(sidecar::read(directory));
    tracing::info!(
        segments = summary.segments.len(),
        answered = summary
            .segments
            .iter()
            .filter(|segment| segment.state == State::Done)
            .count(),
        "finishing a meeting with the Dropline segments it recorded"
    );
    let merged = merge(origins, before, kept, origin_ms, &summary.segments);
    if summary.sent() && !summary.clear_recorded {
        sidecar::Writer::new(directory).write(&clear(transport, credentials));
    }
    merged
}

/// `kept` with Dropline's words from the answered `segments`; `origins`
/// are each track's first arrival on the capture clock (system, then
/// microphone), in ms.
fn merge(
    origins: [u64; 2],
    before: &[TranscriptEntry],
    kept: Vec<TranscriptEntry>,
    origin_ms: u64,
    segments: &[SegmentLine],
) -> Vec<TranscriptEntry> {
    let origin = |track| origins[index(track)];
    let answered = segments
        .iter()
        .filter(|segment| segment.state == State::Done)
        .filter_map(|segment| {
            Some(align::Answered {
                track: segment.track,
                seq: segment.seq,
                start_ms: origin(segment.track) + segment.start * 1_000 / RATE,
                end_ms: origin(segment.track) + segment.end * 1_000 / RATE,
                text: segment.text.as_deref()?,
            })
        })
        .collect::<Vec<_>>();
    align::merge(before, kept, origin_ms, &answered)
}

/// The Worker's memory clear, as the sidecar line that records it.
fn clear(transport: &dyn Transport, credentials: Option<&Credentials>) -> Line {
    let (result, reason) = match credentials {
        None => ("failed", Some(Failure::NotConfigured.to_string())),
        Some(credentials) => match client::memory_clear_url(&credentials.endpoint) {
            None => (
                "skipped",
                Some("Token 端點不是 /dropline-private/token".into()),
            ),
            Some(url) => match client::clear_memory(transport, &url, &credentials.bearer) {
                Cleared::Yes => ("cleared", None),
                Cleared::No => ("not_cleared", None),
                Cleared::Failed(reason) => ("failed", Some(reason)),
            },
        },
    };
    tracing::info!(
        result,
        reason = reason.as_deref(),
        "Dropline memory clear after a meeting"
    );
    Line::Clear {
        result: result.into(),
        reason,
    }
}

impl Meeting {
    fn progress(&self) -> MutexGuard<'_, Progress> {
        lock(&self.progress)
    }

    /// Writes `line` as segment `index` (or a new one) and keeps it.
    fn record(progress: &mut Progress, index: Option<usize>, line: SegmentLine) -> usize {
        progress.sidecar.write(&Line::Segment(line.clone()));
        match index {
            Some(index) => {
                progress.segments[index] = line;
                index
            }
            None => {
                progress.segments.push(line);
                progress.segments.len() - 1
            }
        }
    }

    /// No more sends: every waiting segment fails with `reason`.
    fn stop(&self, progress: &mut Progress, reason: String) {
        if progress.stopped.is_none() {
            tracing::info!(%reason, "the meeting sends nothing more to Dropline");
            progress.stopped = Some(reason.clone());
        }
        while let Some((index, _)) = progress.queue.pop_front() {
            let mut line = progress.segments[index].clone();
            line.state = State::Failed;
            line.reason = Some(reason.clone());
            Self::record(progress, Some(index), line);
        }
        self.changed.notify_all();
    }

    /// A segment the cutter finished: queued when it has speech and the
    /// meeting still sends.
    fn add(&self, track: MeetingSource, cut: Cut) {
        let encoded = cut.speech.then(|| {
            let kept = super::audio::shorten_pauses(&cut.samples);
            super::audio::ogg_opus(&kept)
        });
        let mut progress = self.progress();
        let mut line = SegmentLine {
            track,
            seq: progress.next_seq,
            start: cut.start,
            end: cut.end,
            state: State::Failed,
            sent: false,
            text: None,
            reason: None,
        };
        progress.next_seq += 1;
        match encoded {
            None => {
                line.state = State::Done;
                line.text = Some(String::new());
            }
            Some(_) if progress.stopped.is_some() => line.reason = progress.stopped.clone(),
            Some(_) if progress.queue.len() >= MAX_QUEUED => line.reason = Some("佇列已滿".into()),
            Some(Err(error)) => line.reason = Some(Failure::Encoding(error).to_string()),
            Some(Ok(ogg)) => {
                line.state = State::Queued;
                let index = Self::record(&mut progress, None, line);
                progress.queue.push_back((index, ogg));
                self.changed.notify_all();
                return;
            }
        }
        Self::record(&mut progress, None, line);
    }

    /// Before each request of segment `index`: false once the meeting
    /// stopped. The first one marks the segment sent, as it may reach
    /// Dropline even if no answer comes back.
    fn proceed(&self, index: usize) -> bool {
        let mut progress = self.progress();
        if progress.stopped.is_some() || crate::desktop::process_exit::quitting() {
            return false;
        }
        if !progress.segments[index].sent {
            let mut line = progress.segments[index].clone();
            line.state = State::Sending;
            line.sent = true;
            Self::record(&mut progress, Some(index), line);
        }
        true
    }

    /// Sleeps `pause` out (a 429); false when the meeting stopped meanwhile.
    fn pause(&self, pause: Duration) -> bool {
        let deadline = Instant::now() + pause;
        let mut progress = self.progress();
        loop {
            if progress.stopped.is_some() || crate::desktop::process_exit::quitting() {
                return false;
            }
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return true;
            }
            progress = self
                .changed
                .wait_timeout(progress, left.min(Duration::from_millis(200)))
                .unwrap_or_else(|error| error.into_inner())
                .0;
        }
    }

    /// The meeting's access token, fetched again when it nears expiry or
    /// Dropline answered 401 (`fresh`).
    fn token(&self, fresh: bool) -> Result<String, Failure> {
        let credentials = self.credentials.as_ref().ok_or(Failure::NotConfigured)?;
        {
            let mut progress = self.progress();
            if fresh {
                progress.tokens.invalidate();
            } else if let Some(token) = progress.tokens.current(client::now_ms()) {
                return Ok(token);
            }
        }
        let token =
            client::request_token(&*self.transport, &credentials.endpoint, &credentials.bearer)?;
        let value = token.value.clone();
        self.progress().tokens.store(token);
        Ok(value)
    }

    /// The final pass: cuts the tails, waits for the queue (at most the
    /// budget, and not at all once Hex quits), stops what is left, merges
    /// with `merge`, and clears Dropline's memory once if audio was sent:
    /// after a request still in flight is over, or at once when Hex is
    /// quitting, leaving the outcome unrecorded while that request runs.
    fn complete(
        self: &Arc<Self>,
        input: &SyncSender<Input>,
        merge: impl FnOnce(&[SegmentLine]) -> Vec<TranscriptEntry>,
    ) -> Vec<TranscriptEntry> {
        let deadline = Instant::now() + self.finish_budget;
        let (done, finished) = mpsc::sync_channel(1);
        if input.send(Input::Finish(done)).is_ok() {
            let _ = finished.recv_timeout(deadline.saturating_duration_since(Instant::now()));
        }
        let mut progress = self.progress();
        loop {
            let idle = progress.cut && progress.queue.is_empty() && !progress.sending;
            let quitting = crate::desktop::process_exit::quitting();
            let left = deadline.saturating_duration_since(Instant::now());
            if idle || quitting || left.is_zero() {
                if !idle {
                    let reason = if quitting {
                        "Hex 結束"
                    } else {
                        "定稿等待逾時"
                    };
                    self.stop(&mut progress, reason.into());
                    for index in 0..progress.segments.len() {
                        if progress.segments[index].state == State::Sending {
                            let mut line = progress.segments[index].clone();
                            line.state = State::Failed;
                            line.reason = Some(reason.into());
                            Self::record(&mut progress, Some(index), line);
                        }
                    }
                }
                break;
            }
            progress = self
                .changed
                .wait_timeout(progress, left.min(Duration::from_millis(100)))
                .unwrap_or_else(|error| error.into_inner())
                .0;
        }
        progress.merged = true;
        let segments = progress.segments.clone();
        let sending = progress.sending;
        drop(progress);
        let merged = merge(&segments);
        if sending && !crate::desktop::process_exit::quitting() {
            Arc::clone(self).clear_later();
        } else {
            self.clear_once(!sending);
        }
        merged
    }

    /// Clears Dropline's memory on its own thread once the request in
    /// flight is over, waiting at most [`DRAIN`]; right away when that
    /// thread can't start.
    fn clear_later(self: Arc<Self>) {
        let meeting = Arc::clone(&self);
        let waiter = thread::Builder::new()
            .name("hex-dropline-meeting-clear".into())
            .spawn(move || {
                let deadline = Instant::now() + DRAIN;
                let mut progress = meeting.progress();
                while progress.sending && Instant::now() < deadline {
                    progress = meeting
                        .changed
                        .wait_timeout(progress, Duration::from_millis(200))
                        .unwrap_or_else(|error| error.into_inner())
                        .0;
                }
                let settled = !progress.sending;
                drop(progress);
                meeting.clear_once(settled);
            });
        if let Err(error) = waiter {
            tracing::warn!(%error, "could not wait for the request in flight; clearing Dropline's memory now");
            let settled = !self.progress().sending;
            self.clear_once(settled);
        }
    }

    /// The meeting's one memory clear in this process, when audio was sent.
    /// With `record` false the outcome stays out of the file, so the next
    /// launch clears again: a request still in flight may reach Dropline
    /// after this clear.
    fn clear_once(&self, record: bool) {
        let mut progress = self.progress();
        let sent = progress.segments.iter().any(|segment| segment.sent);
        if !sent || progress.clear_ran {
            return;
        }
        progress.clear_ran = true;
        drop(progress);
        let line = clear(&*self.transport, self.credentials.as_ref());
        if record {
            self.progress().sidecar.write(&line);
        }
    }
}

impl Drop for Recording {
    fn drop(&mut self) {
        {
            let mut live = lock(&LIVE);
            live.retain(|live| live.directory != self.directory);
        }
        let meeting = Arc::clone(&self.meeting);
        let mut progress = meeting.progress();
        if progress.merged {
            return;
        }
        let quitting = crate::desktop::process_exit::quitting();
        meeting.stop(
            &mut progress,
            if quitting {
                "Hex 結束"
            } else {
                "會議中止"
            }
            .into(),
        );
        if quitting {
            // The next launch finishes the meeting and clears.
            return;
        }
        drop(progress);
        meeting.clear_later();
    }
}

/// One track on its way into segments: resampled to 16 kHz and placed by
/// its WAV position, gaps included.
struct Track {
    rate: u32,
    resampler: Option<StreamingResampler>,
    /// The WAV position the next packet should have.
    next: u64,
    /// The 16 kHz position of the next resampled sample.
    at: u64,
    segmenter: Segmenter,
    failed: bool,
}

impl Track {
    fn new(rate: u32, position: u64, limit_blocks: usize) -> Self {
        Self {
            rate,
            resampler: StreamingResampler::new(rate).ok(),
            next: position,
            at: at_16k(position, rate),
            segmenter: Segmenter::new(limit_blocks),
            failed: false,
        }
    }

    fn push(&mut self, position: u64, rate: u32, samples: &[f32]) -> Vec<Cut> {
        if self.failed {
            return Vec::new();
        }
        if rate != self.rate || position < self.next || self.resampler.is_none() {
            tracing::warn!("meeting audio for Dropline lost its timeline; the rest stays local");
            self.failed = true;
            return self.finish();
        }
        let mut cuts = Vec::new();
        if position > self.next {
            cuts.extend(self.finish());
            self.resampler = StreamingResampler::new(rate).ok();
            self.at = at_16k(position, rate);
        }
        self.next = position + samples.len() as u64;
        let Some(resampler) = &mut self.resampler else {
            return cuts;
        };
        let resampled = resampler.push(samples);
        cuts.extend(self.segmenter.push(self.at, &resampled));
        self.at += resampled.len() as u64;
        cuts
    }

    /// The audio before a gap, or at Stop.
    fn finish(&mut self) -> Vec<Cut> {
        let mut cuts = Vec::new();
        if let Some(resampler) = self.resampler.take() {
            let tail = resampler.finish();
            cuts.extend(self.segmenter.push(self.at, &tail));
            self.at += tail.len() as u64;
        }
        cuts.extend(self.segmenter.finish());
        cuts
    }
}

fn at_16k(position: u64, rate: u32) -> u64 {
    (u128::from(position) * u128::from(RATE) / u128::from(rate.max(1))) as u64
}

fn run_cutter(meeting: &Meeting, receiver: Receiver<Input>) {
    let mut tracks: [Option<Track>; 2] = [None, None];
    for input in receiver {
        match input {
            Input::Audio {
                source,
                position,
                rate,
                samples,
            } => {
                let track = tracks[index(source)]
                    .get_or_insert_with(|| Track::new(rate, position, meeting.limit_blocks));
                for cut in track.push(position, rate, &samples) {
                    meeting.add(source, cut);
                }
            }
            Input::Finish(done) => {
                for source in [MeetingSource::System, MeetingSource::Microphone] {
                    if let Some(track) = &mut tracks[index(source)] {
                        for cut in track.finish() {
                            meeting.add(source, cut);
                        }
                    }
                }
                cut_done(meeting);
                let _ = done.send(());
            }
        }
    }
    cut_done(meeting);
}

fn cut_done(meeting: &Meeting) {
    meeting.progress().cut = true;
    meeting.changed.notify_all();
}

fn run_sender(meeting: &Meeting) {
    loop {
        let (index, audio) = {
            let mut progress = meeting.progress();
            loop {
                if let Some(next) = progress.queue.pop_front() {
                    progress.sending = true;
                    break next;
                }
                if progress.cut || progress.stopped.is_some() {
                    return;
                }
                progress = meeting
                    .changed
                    .wait(progress)
                    .unwrap_or_else(|error| error.into_inner());
            }
        };
        let session = super::new_session();
        let started = Instant::now();
        let outcome = client::transcribe_segment(
            &*meeting.transport,
            &mut |fresh| meeting.token(fresh),
            &audio,
            &session,
            &meeting.context,
            &mut || meeting.proceed(index),
            &|pause| meeting.pause(pause),
        );
        let mut progress = meeting.progress();
        progress.sending = false;
        if !progress.merged {
            let mut line = progress.segments[index].clone();
            match &outcome {
                Ok(text) => {
                    tracing::info!(
                        provider = PROVIDER,
                        seq = line.seq,
                        finish_ms = started.elapsed().as_millis() as u64,
                        chars = text.chars().count(),
                        "transcribed a meeting segment with Dropline"
                    );
                    line.state = State::Done;
                    line.text = Some(text.clone());
                }
                Err(failure) => {
                    tracing::warn!(provider = PROVIDER, seq = line.seq, reason = %failure, "a meeting segment keeps its local text");
                    line.state = State::Failed;
                    line.reason = Some(failure.to_string());
                }
            }
            Meeting::record(&mut progress, Some(index), line);
        }
        if let Err(failure) = &outcome
            && failure.is_authorization()
        {
            meeting.stop(&mut progress, failure.to_string());
        }
        meeting.changed.notify_all();
    }
}

fn index(source: MeetingSource) -> usize {
    match source {
        MeetingSource::System => 0,
        MeetingSource::Microphone => 1,
    }
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|error| error.into_inner())
}

/// The saved provider's endpoint and bearer; never read in tests.
fn saved_credentials() -> Option<Credentials> {
    if cfg!(test) {
        return None;
    }
    super::credentials()
        .ok()
        .map(|(endpoint, bearer)| Credentials { endpoint, bearer })
}

/// Hex's HTTPS, except in tests, which must script every request.
fn production() -> SharedTransport {
    #[cfg(test)]
    return Arc::new(tests::Unscripted);
    #[cfg(not(test))]
    Arc::new(client::Http)
}

#[cfg(test)]
pub(crate) mod tests;
