//! Screen text (FORK.md, "Screen text"): while a dictation records, Hex reads
//! the front window's text lines with Vision (`screen_text.swift`), and the
//! snapshot that dictation finishes with hands them to its transformations as
//! `context.screenLines`. Only a capture that may run a script transformation
//! reads, and only with Screen Recording already allowed: nothing here asks.

use std::ffi::{CStr, c_char, c_void};
use std::fmt;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex, PoisonError};
use std::thread;
use std::time::{Duration, Instant};

/// How long a transformation chain waits for its dictation's read: the wait
/// the screen OCR helper's reader used.
const WAIT: Duration = Duration::from_millis(500);
/// At most this many lines and UTF-8 bytes reach a transformation; the lines
/// after them are left out.
const MAX_LINES: usize = 400;
const MAX_BYTES: usize = 32 * 1024;

unsafe extern "C" {
    fn hex_fork_screen_text_permitted() -> bool;
    fn hex_fork_screen_text_front_window() -> u32;
    fn hex_fork_screen_text_read_window(
        id: u32,
        stopped: extern "C" fn(*const c_void) -> bool,
        context: *const c_void,
        status: *mut i32,
    ) -> *mut c_char;
    fn hex_fork_screen_text_prewarm();
    fn hex_fork_screen_text_free(text: *mut c_char);
    #[cfg(test)]
    fn hex_fork_screen_text_read_image(path: *const c_char, status: *mut i32) -> *mut c_char;
}

/// One capture's read, carried by the snapshot that capture finished with.
/// Every handle equals every other, so the foreground monitor never notices
/// one, and none prints its lines.
#[derive(Clone, Default)]
pub struct ScreenText(Option<Arc<Claim>>);

/// Held by the handles alone: when the last one goes, a read still running
/// stops at its next step.
struct Claim(Arc<Job>);

#[derive(Default)]
struct Job {
    /// `None` while the read runs, then its lines (`None` when it failed).
    outcome: Mutex<Option<Option<Vec<String>>>>,
    done: Condvar,
    stopped: AtomicBool,
}

impl Drop for Claim {
    fn drop(&mut self) {
        self.0.stop();
    }
}

impl Job {
    fn finish(&self, lines: Option<Vec<String>>) {
        *self.outcome.lock().unwrap_or_else(PoisonError::into_inner) = Some(lines);
        self.done.notify_all();
    }

    fn stop(&self) {
        self.stopped.store(true, Ordering::Release);
    }

    fn stopped(&self) -> bool {
        self.stopped.load(Ordering::Acquire)
    }
}

impl ScreenText {
    fn pending() -> (Self, Arc<Job>) {
        let job = Arc::new(Job::default());
        (Self(Some(Arc::new(Claim(job.clone())))), job)
    }

    /// This capture's lines for a transformation chain, top to bottom. Waits
    /// up to `WAIT` for a read still running; `None` when nothing was read,
    /// the read failed, or it is still running, which then stops.
    pub fn lines(&self) -> Option<Vec<String>> {
        self.lines_within(WAIT)
    }

    fn lines_within(&self, limit: Duration) -> Option<Vec<String>> {
        let job = &self.0.as_ref()?.0;
        let started = Instant::now();
        let outcome = job.outcome.lock().unwrap_or_else(PoisonError::into_inner);
        let (outcome, _) = job
            .done
            .wait_timeout_while(outcome, limit, |outcome| outcome.is_none())
            .unwrap_or_else(PoisonError::into_inner);
        let lines = outcome.clone();
        drop(outcome);
        tracing::info!(
            waited_ms = started.elapsed().as_millis() as u64,
            ready = lines.is_some(),
            "fork screen text: transformation context"
        );
        if lines.is_none() {
            job.stop();
        }
        lines.flatten()
    }
}

impl PartialEq for ScreenText {
    fn eq(&self, _: &Self) -> bool {
        true
    }
}

impl fmt::Debug for ScreenText {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self.0 {
            Some(_) => "ScreenText(..)",
            None => "ScreenText(none)",
        })
    }
}

/// The listener's read for the capture under way (`ContextWatch`): started
/// once, when the capture becomes real or, for a short tap, when it
/// finishes, and handed to the snapshot that finish returns.
pub struct ScreenTextRead {
    capture: Capture,
    read: Box<dyn FnMut() -> ScreenText>,
}

enum Capture {
    None,
    Pending,
    Reading(ScreenText),
}

impl ScreenTextRead {
    /// The listener's reader. With a script transformation set up and Screen
    /// Recording allowed, Vision loads now rather than at the first read.
    pub fn start() -> Self {
        prewarm();
        Self::reading_with(|| start_read(crate::dictation::config::reads_window_title()))
    }

    fn reading_with(read: impl FnMut() -> ScreenText + 'static) -> Self {
        Self {
            capture: Capture::None,
            read: Box::new(read),
        }
    }

    /// A press started a capture, maybe a provisional one: nothing is read
    /// yet, and a read an earlier capture left here is dropped.
    pub fn begin(&mut self) {
        self.capture = Capture::Pending;
    }

    /// A raw capture skips processing, so it never reads.
    pub fn raw(&mut self, raw: bool) {
        if raw {
            self.cancel();
        }
    }

    /// The capture became real: its read starts, once.
    pub fn intend(&mut self) {
        if matches!(self.capture, Capture::Pending) {
            self.capture = Capture::Reading((self.read)());
        }
    }

    /// The capture ended without transcribing: its read stops.
    pub fn cancel(&mut self) {
        self.capture = Capture::None;
    }

    /// The capture ended transcribing: its read, started now for a capture
    /// that finished before it became real.
    pub fn finish(&mut self) -> ScreenText {
        self.intend();
        match std::mem::replace(&mut self.capture, Capture::None) {
            Capture::Reading(text) => text,
            Capture::None | Capture::Pending => ScreenText::default(),
        }
    }
}

/// This capture's read, on its own thread, when a script transformation is
/// set up (`scripts`): the window frontmost now, never another.
fn start_read(scripts: bool) -> ScreenText {
    if !scripts {
        return ScreenText::default();
    }
    let (text, job) = ScreenText::pending();
    let spawned = thread::Builder::new()
        .name("hex-fork-screen-text".into())
        .spawn(move || {
            let started = Instant::now();
            let outcome = read(&Native, &job);
            let duration_ms = started.elapsed().as_millis() as u64;
            match &outcome {
                Ok(lines) => {
                    tracing::info!(lines = lines.len(), duration_ms, "fork screen text: read")
                }
                Err(reason) => {
                    tracing::info!(
                        reason = reason.as_str(),
                        duration_ms,
                        "fork screen text: no read"
                    )
                }
            }
            job.finish(outcome.ok());
        });
    match spawned {
        Ok(_) => text,
        Err(error) => {
            tracing::warn!(%error, "fork screen text: could not start a read");
            ScreenText::default()
        }
    }
}

/// Why a read has no lines.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Failure {
    NoPermission,
    NoWindow,
    WindowGone,
    CaptureFailed,
    RecognitionFailed,
    Stopped,
}

impl Failure {
    fn from_bridge(status: i32) -> Self {
        match status {
            1 => Self::WindowGone,
            2 => Self::CaptureFailed,
            4 => Self::Stopped,
            _ => Self::RecognitionFailed,
        }
    }

    fn as_str(self) -> &'static str {
        match self {
            Self::NoPermission => "no-permission",
            Self::NoWindow => "no-window",
            Self::WindowGone => "window-gone",
            Self::CaptureFailed => "capture-failed",
            Self::RecognitionFailed => "recognition-failed",
            Self::Stopped => "stopped",
        }
    }
}

/// What a read asks of macOS (`screen_text.swift`).
trait Screen {
    fn permitted(&self) -> bool;
    fn front_window(&self) -> Option<u32>;
    fn read_window(&self, id: u32, job: &Job) -> Result<Vec<String>, Failure>;
}

/// Without Screen Recording already allowed, nothing is looked at: macOS can
/// ask for the permission when a window is listed or captured.
fn read(screen: &impl Screen, job: &Job) -> Result<Vec<String>, Failure> {
    if !screen.permitted() {
        return Err(Failure::NoPermission);
    }
    let window = screen.front_window().ok_or(Failure::NoWindow)?;
    if job.stopped() {
        return Err(Failure::Stopped);
    }
    screen.read_window(window, job).map(bounded)
}

/// The lines in order, without empty ones, up to `MAX_LINES` and `MAX_BYTES`.
fn bounded(lines: Vec<String>) -> Vec<String> {
    let mut bytes = 0;
    lines
        .into_iter()
        .filter(|line| !line.is_empty())
        .take(MAX_LINES)
        .take_while(|line| {
            bytes += line.len();
            bytes <= MAX_BYTES
        })
        .collect()
}

struct Native;

extern "C" fn job_stopped(job: *const c_void) -> bool {
    // SAFETY: `Native::read_window` passes the `Job` it borrows, and the
    // bridge calls this only during that call.
    unsafe { &*job.cast::<Job>() }.stopped()
}

impl Screen for Native {
    fn permitted(&self) -> bool {
        // SAFETY: no arguments; the bridge only reads the permission.
        unsafe { hex_fork_screen_text_permitted() }
    }

    fn front_window(&self) -> Option<u32> {
        // SAFETY: no arguments; 0 means no window.
        Some(unsafe { hex_fork_screen_text_front_window() }).filter(|id| *id != 0)
    }

    fn read_window(&self, id: u32, job: &Job) -> Result<Vec<String>, Failure> {
        let mut status = 0;
        // SAFETY: `job` outlives the call, and `status` is a valid out pointer.
        let text = unsafe {
            hex_fork_screen_text_read_window(
                id,
                job_stopped,
                std::ptr::from_ref(job).cast(),
                &mut status,
            )
        };
        taken(text, status)
    }
}

/// The bridge's lines, freeing its string, or why it has none.
fn taken(text: *mut c_char, status: i32) -> Result<Vec<String>, Failure> {
    if text.is_null() {
        return Err(Failure::from_bridge(status));
    }
    // SAFETY: a non-null result is a NUL-terminated string the bridge
    // allocated, freed once here.
    let joined = unsafe { CStr::from_ptr(text) }
        .to_string_lossy()
        .into_owned();
    unsafe { hex_fork_screen_text_free(text) };
    Ok(joined.split('\n').map(str::to_owned).collect())
}

/// Loads Vision's text model off the listener when a read can happen: a
/// script transformation is set up and Screen Recording is allowed. Vision
/// keeps it in Hex's memory.
fn prewarm() {
    if !crate::dictation::config::reads_window_title() || !Native.permitted() {
        return;
    }
    let spawned = thread::Builder::new()
        .name("hex-fork-screen-text-prewarm".into())
        .spawn(|| {
            let started = Instant::now();
            // SAFETY: no arguments; the bridge reads a blank image.
            unsafe { hex_fork_screen_text_prewarm() };
            tracing::info!(
                duration_ms = started.elapsed().as_millis() as u64,
                "fork screen text: Vision loaded"
            );
        });
    if let Err(error) = spawned {
        tracing::warn!(%error, "fork screen text: could not load Vision");
    }
}

#[cfg(test)]
impl ScreenText {
    /// A read that already found `lines`.
    pub(crate) fn ready(lines: &[&str]) -> Self {
        let (text, job) = Self::pending();
        job.finish(Some(lines.iter().map(ToString::to_string).collect()));
        text
    }
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;
    use std::ffi::CString;
    use std::path::Path;
    use std::rc::Rc;

    use super::*;

    /// A reader whose reads the test finishes, in any order.
    fn reader() -> (ScreenTextRead, Rc<RefCell<Vec<Arc<Job>>>>) {
        let jobs = Rc::new(RefCell::new(Vec::new()));
        let started = jobs.clone();
        let reader = ScreenTextRead::reading_with(move || {
            let (text, job) = ScreenText::pending();
            started.borrow_mut().push(job);
            text
        });
        (reader, jobs)
    }

    fn strings(lines: &[&str]) -> Vec<String> {
        lines.iter().map(ToString::to_string).collect()
    }

    #[test]
    fn a_capture_reads_once_when_it_becomes_real() {
        let (mut reader, jobs) = reader();
        reader.begin();
        assert!(
            jobs.borrow().is_empty(),
            "a provisional press reads nothing"
        );
        reader.intend();
        reader.intend();
        let text = reader.finish();
        assert_eq!(jobs.borrow().len(), 1);
        jobs.borrow()[0].finish(Some(strings(&["qa-alpha-4127"])));
        assert_eq!(text.lines(), Some(strings(&["qa-alpha-4127"])));
    }

    #[test]
    fn a_short_tap_reads_when_it_finishes() {
        let (mut reader, jobs) = reader();
        reader.begin();
        let text = reader.finish();
        assert_eq!(jobs.borrow().len(), 1);
        jobs.borrow()[0].finish(Some(strings(&["qa-bravo-5203"])));
        assert_eq!(text.lines(), Some(strings(&["qa-bravo-5203"])));
    }

    #[test]
    fn cancelled_and_raw_captures_never_read() {
        let (mut reader, jobs) = reader();
        reader.begin();
        reader.cancel();
        reader.intend();
        assert!(reader.finish().lines().is_none());
        reader.begin();
        reader.raw(true);
        reader.intend();
        assert!(reader.finish().lines().is_none());
        assert!(jobs.borrow().is_empty());
        let finished_without_capture = reader.finish();
        assert!(finished_without_capture.lines().is_none());
        assert!(jobs.borrow().is_empty());
    }

    #[test]
    fn a_cancelled_or_replaced_read_stops() {
        let (mut reader, jobs) = reader();
        reader.begin();
        reader.intend();
        reader.cancel();
        assert!(jobs.borrow()[0].stopped());
        reader.begin();
        reader.intend();
        reader.begin();
        assert!(
            jobs.borrow()[1].stopped(),
            "a new press drops the unfinished capture's read"
        );
    }

    #[test]
    fn overlapping_dictations_each_get_their_own_lines() {
        let (mut reader, jobs) = reader();
        reader.begin();
        reader.intend();
        let first = reader.finish();
        reader.begin();
        reader.intend();
        let second = reader.finish();
        assert!(
            !jobs.borrow()[0].stopped(),
            "the next capture leaves a finished one's read alone"
        );
        jobs.borrow()[1].finish(Some(strings(&["qa-second-6311"])));
        jobs.borrow()[0].finish(Some(strings(&["qa-first-7489"])));
        assert_eq!(second.lines(), Some(strings(&["qa-second-6311"])));
        assert_eq!(first.lines(), Some(strings(&["qa-first-7489"])));
    }

    #[test]
    fn a_slow_read_is_left_out_and_stopped() {
        let (text, job) = ScreenText::pending();
        let started = Instant::now();
        assert_eq!(text.lines_within(Duration::from_millis(50)), None);
        assert!(started.elapsed() >= Duration::from_millis(50));
        assert!(job.stopped());
        job.finish(Some(strings(&["qa-late-8592"])));
    }

    #[test]
    fn a_failed_read_is_left_out_without_waiting() {
        let (text, job) = ScreenText::pending();
        job.finish(None);
        let started = Instant::now();
        assert_eq!(text.lines(), None);
        assert!(started.elapsed() < WAIT);
    }

    #[test]
    fn a_read_that_ends_while_waited_for_is_used() {
        let (text, job) = ScreenText::pending();
        let finisher = thread::spawn(move || {
            thread::sleep(Duration::from_millis(30));
            job.finish(Some(strings(&["qa-arrived-1180"])));
        });
        assert_eq!(text.lines(), Some(strings(&["qa-arrived-1180"])));
        finisher.join().unwrap();
    }

    #[test]
    fn without_scripts_nothing_is_read() {
        let text = start_read(false);
        assert!(text.0.is_none());
        assert_eq!(text.lines(), None);
    }

    #[derive(Default)]
    struct FakeScreen {
        permitted: bool,
        looked: RefCell<Vec<&'static str>>,
    }

    impl Screen for FakeScreen {
        fn permitted(&self) -> bool {
            self.looked.borrow_mut().push("permitted");
            self.permitted
        }

        fn front_window(&self) -> Option<u32> {
            self.looked.borrow_mut().push("front_window");
            Some(7)
        }

        fn read_window(&self, _: u32, _: &Job) -> Result<Vec<String>, Failure> {
            self.looked.borrow_mut().push("read_window");
            Ok(strings(&["qa-window-2846", ""]))
        }
    }

    #[test]
    fn without_permission_no_window_is_looked_at() {
        let screen = FakeScreen::default();
        assert_eq!(read(&screen, &Job::default()), Err(Failure::NoPermission));
        assert_eq!(*screen.looked.borrow(), ["permitted"]);
        let screen = FakeScreen {
            permitted: true,
            ..FakeScreen::default()
        };
        assert_eq!(
            read(&screen, &Job::default()),
            Ok(strings(&["qa-window-2846"]))
        );
        assert_eq!(
            *screen.looked.borrow(),
            ["permitted", "front_window", "read_window"]
        );
    }

    #[test]
    fn a_stopped_read_captures_nothing() {
        let screen = FakeScreen {
            permitted: true,
            ..FakeScreen::default()
        };
        let job = Job::default();
        job.stop();
        assert_eq!(read(&screen, &job), Err(Failure::Stopped));
        assert_eq!(*screen.looked.borrow(), ["permitted", "front_window"]);
    }

    #[test]
    fn lines_are_bounded_in_count_and_bytes() {
        let many = (0..MAX_LINES + 10)
            .map(|line| format!("qa-{line}"))
            .collect();
        assert_eq!(bounded(many).len(), MAX_LINES);
        let long = "x".repeat(MAX_BYTES / 2);
        let lines = bounded(vec![long.clone(), long.clone(), "qa-after".into()]);
        assert_eq!(lines, [long.clone(), long]);
    }

    #[test]
    fn handles_are_all_equal_and_print_no_lines() {
        let read = ScreenText::ready(&["qa-secret-9917"]);
        assert_eq!(read, ScreenText::default());
        assert!(!format!("{read:?}").contains("qa-secret"));
    }

    #[test]
    fn screen_lines_stay_out_of_the_vocabulary_dropline_sends() {
        let snapshot = crate::dictation::context::ContextSnapshot {
            fork_screen_text: ScreenText::ready(&["qa-screen-only-3359"]),
            ..Default::default()
        };
        crate::dictation::vocabulary::focus(&snapshot);
        assert!(
            !crate::dictation::vocabulary::terms()
                .iter()
                .any(|term| term.contains("qa-screen-only"))
        );
    }

    #[test]
    fn a_closed_window_is_not_replaced_by_another() {
        if !Native.permitted() {
            return;
        }
        assert_eq!(
            Native.read_window(u32::MAX, &Job::default()),
            Err(Failure::WindowGone)
        );
    }

    #[test]
    fn a_qa_image_reads_in_order() {
        let path =
            Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/fork/qa-screen-text.png");
        let path = CString::new(path.to_str().unwrap()).unwrap();
        let mut status = 0;
        // SAFETY: `path` is NUL-terminated and `status` a valid out pointer.
        let text = unsafe { hex_fork_screen_text_read_image(path.as_ptr(), &mut status) };
        assert_eq!(
            taken(text, status),
            Ok(strings(&[
                "qa-alpha-4127",
                "qa-bravo-5203",
                "qa-charlie-6311",
                "qa-delta-7489 qa-echo-8592",
            ]))
        );
    }
}
