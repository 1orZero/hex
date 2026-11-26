//! Dropline's private API as a custom transcription provider (macOS).
//!
//! When the provider is selected, a finished dictation's clip is shortened at
//! its long pauses, encoded as Ogg Opus, and sent to Dropline; the text it
//! returns replaces the local model's. The access token comes from a token
//! endpoint (Derek Voice Worker) with a bearer kept in the Keychain; Hex
//! never refreshes Dropline tokens itself. The local model transcribes the
//! clip only after Dropline fails, so a failure answers with the local text of
//! the same clip and records why. While a hotkey capture records, Dropline
//! also gives its live text (`live`, called by `dictation::fork_dropline_live`).

mod audio;
mod client;
mod keychain;
pub(crate) mod meeting;
mod store;
mod text;

use std::collections::VecDeque;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant, SystemTime};

use crate::transcription::engine::{
    LiveStream, Offline, PendingTranscript, Source, Transcribed, TranscriptionEngine,
};

pub use store::DEFAULT_ENDPOINT;
pub(crate) use text::traditional;

/// The provider's name, as the picker and General show it.
pub const NAME: &str = "Dropline 私人 API";

/// Dropline takes 180 s; stop where Derek Voice does.
const MAX_AUDIO_MS: usize = 178_000;
/// The whole wait for one dictation, a token refetch after a 401 included.
const DICTATE_BUDGET: Duration = Duration::from_secs(10);
/// A prepared session older than this belongs to no capture still recording.
const SESSION_AGE: Duration = Duration::from_secs(200);
/// Answers kept for History; a dictation that never reaches History
/// (cancelled, no speech, a failed paste, the local API's) leaves its answer
/// until newer ones push it out.
const KEPT_ANSWERS: usize = 16;

/// The saved provider: its token endpoint and whether dictation uses it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Provider {
    pub endpoint: String,
    pub selected: bool,
}

/// Why the newest dictation fell back to the local model.
#[derive(Clone, Debug)]
pub struct Fallback {
    pub reason: String,
    pub at: SystemTime,
}

#[derive(Default)]
struct State {
    loaded: bool,
    provider: Option<Provider>,
    bearer: Option<String>,
    tokens: client::TokenCache,
    prepared: Option<(String, Instant)>,
    fallback: Option<Fallback>,
}

static STATE: Mutex<State> = Mutex::new(State {
    loaded: false,
    provider: None,
    bearer: None,
    tokens: client::TokenCache::new(),
    prepared: None,
    fallback: None,
});

/// Recent Dropline dictations' History speech model by submission instant,
/// which the dictation pipeline carries to History as
/// `JobTimings::total_started`.
static ANSWERS: Mutex<VecDeque<(Instant, String)>> = Mutex::new(VecDeque::new());

fn state() -> MutexGuard<'static, State> {
    let mut state = STATE.lock().unwrap_or_else(|error| error.into_inner());
    if !state.loaded {
        state.loaded = true;
        state.provider = store::load();
    }
    state
}

pub fn provider() -> Option<Provider> {
    state().provider.clone()
}

/// Whether dictation goes to Dropline. Tests never read the saved provider:
/// each test thread starts unselected ([`select_for_test`]).
pub fn selected() -> bool {
    #[cfg(test)]
    return SELECTED_FOR_TEST.with(std::cell::Cell::get);
    #[cfg(not(test))]
    state()
        .provider
        .as_ref()
        .is_some_and(|provider| provider.selected)
}

#[cfg(test)]
thread_local! {
    static SELECTED_FOR_TEST: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

/// Makes [`selected`] answer `selected` on this test thread.
#[cfg(test)]
pub(crate) fn select_for_test(selected: bool) {
    SELECTED_FOR_TEST.with(|cell| cell.set(selected));
}

pub fn last_fallback() -> Option<Fallback> {
    state().fallback.clone()
}

/// Uses Dropline for dictation, or stops using it.
pub fn select(selected: bool) -> Result<(), String> {
    let mut state = state();
    let Some(provider) = state.provider.as_mut() else {
        return Err("沒有設定 Dropline 私人 API".into());
    };
    if provider.selected == selected {
        return Ok(());
    }
    let saved = Provider {
        selected,
        ..provider.clone()
    };
    store::save(&saved).map_err(|error| format!("無法儲存設定：{error}"))?;
    provider.selected = selected;
    Ok(())
}

/// A local model was chosen: dictation stops using Dropline.
pub fn deselect() {
    if selected()
        && let Err(error) = select(false)
    {
        tracing::warn!(%error, "could not stop using Dropline");
    }
}

/// Saves the provider once one token fetch with `bearer` works; nothing is
/// saved otherwise. Blocks on the network: call it off the UI thread.
pub fn save(endpoint: &str, bearer: &str) -> Result<(), String> {
    let endpoint = endpoint.trim();
    let bearer = bearer.trim();
    match url::Url::parse(endpoint) {
        Ok(url) if url.scheme() == "https" && url.host_str().is_some() => {}
        _ => return Err("Token 端點不是有效的 https 網址".into()),
    }
    if bearer.is_empty() || bearer.chars().any(char::is_whitespace) {
        return Err("Bearer token 不能是空的或含空白".into());
    }
    let token = client::fetch_token(&client::Http, endpoint, bearer).map_err(|f| f.to_string())?;
    let account = keychain_account();
    let previous = keychain::read(&account).ok().flatten();
    keychain::write(&account, bearer)?;
    let provider = Provider {
        endpoint: endpoint.to_owned(),
        selected: state().provider.as_ref().is_some_and(|p| p.selected),
    };
    if let Err(error) = store::save(&provider) {
        let restored = match &previous {
            Some(previous) => keychain::write(&account, previous),
            None => keychain::delete(&account),
        };
        if let Err(restore) = restored {
            tracing::warn!(%restore, "could not restore the Dropline bearer");
        }
        return Err(format!("無法儲存設定：{error}"));
    }
    let mut state = state();
    state.provider = Some(provider);
    state.bearer = Some(bearer.to_owned());
    state.tokens = client::TokenCache::new();
    state.tokens.store(token);
    state.fallback = None;
    Ok(())
}

/// Removes the provider, its bearer, and the cached access token.
pub fn delete() -> Result<(), String> {
    store::remove().map_err(|error| format!("無法刪除設定：{error}"))?;
    {
        let mut state = state();
        state.provider = None;
        state.bearer = None;
        state.tokens = client::TokenCache::new();
        state.prepared = None;
        state.fallback = None;
    }
    keychain::delete(&keychain_account())
}

/// A capture started: tells Dropline its session early (best effort), so
/// the dictation that ends it answers sooner.
pub fn prepare() {
    if !selected() {
        return;
    }
    let session = new_session();
    state().prepared = Some((session.clone(), Instant::now()));
    let context = context(&crate::dictation::vocabulary::terms());
    let started = std::thread::Builder::new()
        .name("hex-dropline-prepare".into())
        .spawn(move || {
            let outcome = credentials()
                .and_then(|(endpoint, bearer)| access_token(&endpoint, &bearer, false))
                .map(|token| client::prepare(&client::Http, &token, &session, &context));
            match outcome {
                Ok(status) => tracing::debug!(status, "prepared a Dropline session"),
                Err(failure) => {
                    tracing::debug!(reason = %failure, "could not prepare a Dropline session")
                }
            }
        });
    if let Err(error) = started {
        tracing::warn!(%error, "could not start the Dropline prepare");
    }
}

/// One dictation's clip for Dropline, taken as the clip goes to the engine.
pub struct Job {
    samples: Vec<f32>,
    session: String,
    vocabulary: Vec<String>,
    submitted: Instant,
}

/// The clip (16 kHz mono) for Dropline while it is selected, with the
/// session its capture prepared. `submitted` is the dictation's submission
/// instant, which later names it to [`history_model`].
pub fn job(samples: &[f32], submitted: Instant) -> Option<Job> {
    if !selected() {
        return None;
    }
    let prepared = state()
        .prepared
        .take()
        .filter(|(_, at)| at.elapsed() < SESSION_AGE)
        .map(|(session, _)| session);
    Some(Job {
        samples: samples.to_vec(),
        session: prepared.unwrap_or_else(new_session),
        vocabulary: crate::dictation::vocabulary::terms(),
        submitted,
    })
}

/// A dictation's local transcript: running, or waiting for Dropline to fail.
pub enum Local {
    Running(PendingTranscript),
    Deferred(Box<dyn FnOnce() -> Result<PendingTranscript, String> + Send>),
}

impl Local {
    fn wait(self) -> Result<Transcribed, String> {
        match self {
            Self::Running(pending) => pending.wait(),
            Self::Deferred(start) => start()?.wait(),
        }
    }
}

/// The clip's local transcript. While Dropline transcribes the clip
/// (`dropline` is `Some`) and the capture streamed nothing, the local model
/// runs only if Dropline fails; otherwise the engine starts it now.
pub fn local(
    dropline: &Option<Job>,
    engine: &Arc<TranscriptionEngine>,
    stream: Option<LiveStream>,
    clip: Vec<f32>,
    offline: Offline,
) -> color_eyre::eyre::Result<Local> {
    if dropline.is_none() || stream.is_some() {
        return engine
            .finish_with(stream, clip, offline)
            .map(Local::Running);
    }
    let engine = engine.clone();
    Ok(Local::Deferred(Box::new(move || {
        engine
            .finish_with(None, clip, offline)
            .map_err(|error| error.to_string())
    })))
}

/// Dropline's text for `job`, else the local model's for the same clip.
/// When Dropline answers, a local transcript already running is still waited
/// for off this thread, so its deadlines keep a wedged engine from holding
/// later jobs; a deferred one never starts.
pub fn wait(job: Option<Job>, local: Local) -> Result<Transcribed, String> {
    answer(job, local, transcribe, |fallback| {
        state().fallback = fallback
    })
}

/// [`wait`] with Dropline's request and General's fallback status passed in.
fn answer(
    job: Option<Job>,
    local: Local,
    transcribe: impl FnOnce(&Job) -> Result<String, client::Failure>,
    status: impl FnOnce(Option<Fallback>),
) -> Result<Transcribed, String> {
    let Some(job) = job else {
        return local.wait();
    };
    let started = Instant::now();
    match transcribe(&job) {
        Ok(text) => {
            let finish_ms = started.elapsed().as_millis() as u64;
            tracing::info!(
                provider = "dropline-private",
                finish_ms,
                audio_ms = job.samples.len() / 16,
                chars = text.chars().count(),
                "transcribed dictation with Dropline"
            );
            status(None);
            remember(job.submitted, NAME.to_owned());
            if let Local::Running(pending) = local {
                let watched = std::thread::Builder::new()
                    .name("hex-dropline-local".into())
                    .spawn(move || {
                        let _ = pending.wait();
                    });
                if let Err(error) = watched {
                    tracing::warn!(%error, "could not watch the local transcript");
                }
            }
            Ok(Transcribed {
                text,
                source: Source::Offline,
                finish_ms,
            })
        }
        Err(failure) => {
            let reason = failure.to_string();
            tracing::warn!(provider = "dropline-private", %reason, "Dropline failed; using the local model");
            status(Some(Fallback {
                reason,
                at: SystemTime::now(),
            }));
            let transcribed = local.wait();
            // Read now, while the engine still holds the model that made the
            // text; a model chosen before History records it didn't.
            if transcribed.is_ok()
                && let Some(model) = crate::history::dictation_model()
            {
                remember(job.submitted, format!("{model}（Dropline 失敗後改用）"));
            }
            transcribed
        }
    }
}

fn remember(submitted: Instant, model: String) {
    let mut answers = ANSWERS.lock().unwrap_or_else(|error| error.into_inner());
    answers.push_front((submitted, model));
    answers.truncate(KEPT_ANSWERS);
}

/// The speech model History records for the dictation submitted at
/// `submitted`: Dropline when it answered, the local model marked as the
/// fallback when Dropline failed, else the local model as upstream names it.
pub fn history_model(submitted: Instant) -> Option<String> {
    let mut answers = ANSWERS.lock().unwrap_or_else(|error| error.into_inner());
    let answer = answers
        .iter()
        .position(|(at, _)| *at == submitted)
        .and_then(|index| answers.remove(index));
    drop(answers);
    answer
        .map(|(_, model)| model)
        .or_else(crate::history::dictation_model)
}

/// Dropline's text for the recording so far, for live text (blocks on the
/// network). `session` is the one the dictation's final request uses
/// ([`live_session`]), and the vocabulary is the same; a failure is only
/// logged, by reason.
pub(crate) fn live(samples: Vec<f32>, session: String) -> Option<String> {
    let job = Job {
        samples,
        session,
        vocabulary: crate::dictation::vocabulary::terms(),
        submitted: Instant::now(),
    };
    let started = Instant::now();
    match transcribe(&job) {
        Ok(text) => {
            tracing::debug!(
                provider = "dropline-private",
                finish_ms = started.elapsed().as_millis() as u64,
                audio_ms = job.samples.len() / 16,
                chars = text.chars().count(),
                "Dropline live text"
            );
            Some(text)
        }
        Err(failure) => {
            tracing::debug!(provider = "dropline-private", reason = %failure, "Dropline live text failed");
            None
        }
    }
}

/// The capture's prepared session, made now (and kept for its final request)
/// when its prepare didn't run.
pub(crate) fn live_session() -> String {
    let mut state = state();
    if let Some((session, at)) = &state.prepared
        && at.elapsed() < SESSION_AGE
    {
        return session.clone();
    }
    let session = new_session();
    state.prepared = Some((session.clone(), Instant::now()));
    session
}

fn transcribe(job: &Job) -> Result<String, client::Failure> {
    let (endpoint, bearer) = credentials()?;
    let kept = audio::shorten_pauses(&job.samples);
    if kept.len() > MAX_AUDIO_MS * 16 {
        return Err(client::Failure::TooLong);
    }
    let ogg = audio::ogg_opus(&kept).map_err(client::Failure::Encoding)?;
    let context = context(&job.vocabulary);
    let deadline = Instant::now() + DICTATE_BUDGET;
    client::dictate(
        &client::Http,
        &mut |fresh| access_token(&endpoint, &bearer, fresh),
        &ogg,
        &job.session,
        &context,
        deadline,
    )
}

/// The saved endpoint and bearer. The Keychain is read without holding the
/// state, which the audio loop reads on every chunk through [`selected`].
fn credentials() -> Result<(String, String), client::Failure> {
    let (endpoint, bearer) = {
        let state = state();
        let endpoint = state
            .provider
            .as_ref()
            .map(|provider| provider.endpoint.clone())
            .ok_or(client::Failure::NotConfigured)?;
        (endpoint, state.bearer.clone())
    };
    if let Some(bearer) = bearer {
        return Ok((endpoint, bearer));
    }
    let bearer = keychain::read(&keychain_account())
        .map_err(client::Failure::Keychain)?
        .ok_or(client::Failure::NotConfigured)?;
    let mut state = state();
    if state.provider.is_some() {
        state.bearer.get_or_insert_with(|| bearer.clone());
    }
    Ok((endpoint, bearer))
}

/// The cached access token, or a new one; `fresh` drops the cached one first
/// (Dropline answered 401).
fn access_token(endpoint: &str, bearer: &str, fresh: bool) -> Result<String, client::Failure> {
    {
        let mut state = state();
        if fresh {
            state.tokens.invalidate();
        } else if let Some(token) = state.tokens.current(client::now_ms()) {
            return Ok(token);
        }
    }
    let token = client::fetch_token(&client::Http, endpoint, bearer)?;
    let value = token.value.clone();
    state().tokens.store(token);
    Ok(value)
}

/// What helps Dropline pick this dictation's words: Hex's vocabulary.
fn context(vocabulary: &[String]) -> client::Context {
    let text = vocabulary
        .iter()
        .map(|term| term.trim())
        .filter(|term| !term.is_empty())
        .collect::<Vec<_>>()
        .join(", ");
    client::Context { text }
}

/// Keychain items belong to one data folder, so Hex Test never reads or
/// replaces the installed Hex's bearer.
fn keychain_account() -> String {
    crate::app_paths::support_dir()
        .map(|path| path.display().to_string())
        .unwrap_or_else(|_| "hex".into())
}

/// A random UUID (version 4), lowercased.
fn new_session() -> String {
    let mut bytes = [0_u8; 16];
    if getrandom::fill(&mut bytes).is_err() {
        let nanos = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        bytes = nanos.to_le_bytes();
    }
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    let hex: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
    format!(
        "{}-{}-{}-{}-{}",
        &hex[..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..]
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sessions_are_version_four_uuids() {
        let session = new_session();
        assert_eq!(session.len(), 36);
        assert_eq!(&session[14..15], "4");
        assert!(matches!(&session[19..20], "8" | "9" | "a" | "b"));
        assert_ne!(session, new_session());
    }

    use std::sync::atomic::{AtomicUsize, Ordering};

    fn engine() -> Arc<TranscriptionEngine> {
        Arc::new(TranscriptionEngine::start(Default::default()).unwrap())
    }

    /// The local model's offline run, counted in `runs`.
    fn counted(runs: &Arc<AtomicUsize>, delay: Duration) -> Offline {
        let runs = runs.clone();
        Box::new(move |_, _| {
            runs.fetch_add(1, Ordering::SeqCst);
            std::thread::sleep(delay);
            Ok("qa-本機".into())
        })
    }

    fn running(engine: &TranscriptionEngine, delay: Duration) -> Local {
        Local::Running(
            engine
                .foreground(vec![], counted(&Arc::default(), delay))
                .unwrap(),
        )
    }

    fn qa_job() -> Job {
        Job {
            samples: vec![0.0; 1_600],
            session: new_session(),
            vocabulary: Vec::new(),
            submitted: Instant::now(),
        }
    }

    #[test]
    fn local_dictation_keeps_its_original_script() {
        let engine = engine();
        let local = engine
            .foreground(vec![], Box::new(|_, _| Ok("qa-本机软件".into())))
            .unwrap();
        assert_eq!(
            wait(None, Local::Running(local)).unwrap().text,
            "qa-本机软件"
        );
    }

    #[test]
    fn without_dropline_the_local_model_starts_with_the_clip() {
        let engine = engine();
        let runs = Arc::new(AtomicUsize::new(0));
        let local = local(
            &None,
            &engine,
            None,
            vec![0.0; 1_600],
            counted(&runs, Duration::ZERO),
        )
        .unwrap();
        assert!(matches!(local, Local::Running(_)));
        let submitted = Instant::now();
        assert_eq!(wait(None, local).unwrap().text, "qa-本機");
        assert_eq!(runs.load(Ordering::SeqCst), 1);
        assert_eq!(history_model(submitted), crate::history::dictation_model());
    }

    #[test]
    fn a_dropline_answer_never_runs_the_local_model() {
        let engine = engine();
        let runs = Arc::new(AtomicUsize::new(0));
        let job = qa_job();
        let submitted = job.submitted;
        let job = Some(job);
        let local = local(
            &job,
            &engine,
            None,
            vec![0.0; 1_600],
            counted(&runs, Duration::ZERO),
        )
        .unwrap();
        let mut fallback = None;
        let started = Instant::now();
        let transcribed = answer(
            job,
            local,
            |_| {
                std::thread::sleep(Duration::from_millis(200));
                Ok("qa-Dropline".into())
            },
            |status| fallback = Some(status),
        )
        .unwrap();
        assert_eq!(transcribed.text, "qa-Dropline");
        assert!(matches!(fallback, Some(None)));
        assert!(transcribed.finish_ms >= 200, "{}", transcribed.finish_ms);
        assert!(started.elapsed() < Duration::from_secs(2));
        assert_eq!(history_model(submitted).as_deref(), Some(NAME));
        // The engine is idle: a local run started now would have counted.
        engine
            .foreground(vec![], Box::new(|_, _| Ok(String::new())))
            .unwrap()
            .wait()
            .unwrap();
        assert_eq!(runs.load(Ordering::SeqCst), 0);
    }

    #[test]
    fn a_dropline_failure_runs_the_local_model_once() {
        let engine = engine();
        let runs = Arc::new(AtomicUsize::new(0));
        let job = qa_job();
        let submitted = job.submitted;
        let job = Some(job);
        let local = local(
            &job,
            &engine,
            None,
            vec![0.0; 1_600],
            counted(&runs, Duration::ZERO),
        )
        .unwrap();
        assert_eq!(
            runs.load(Ordering::SeqCst),
            0,
            "nothing runs before Dropline fails"
        );
        let mut fallback = None;
        let transcribed = answer(
            job,
            local,
            |_| Err(client::Failure::Timeout),
            |status| fallback = status,
        )
        .unwrap();
        assert_eq!(transcribed.text, "qa-本機");
        assert_eq!(runs.load(Ordering::SeqCst), 1);
        assert_eq!(
            fallback.map(|fallback| fallback.reason),
            Some(client::Failure::Timeout.to_string())
        );
        let model = crate::history::dictation_model().unwrap();
        assert_eq!(
            history_model(submitted),
            Some(format!("{model}（Dropline 失敗後改用）"))
        );
    }

    #[test]
    fn a_running_local_transcript_is_not_waited_for_when_dropline_answers() {
        let engine = engine();
        let job = qa_job();
        let started = Instant::now();
        let transcribed = answer(
            Some(job),
            running(&engine, Duration::from_secs(3)),
            |_| Ok("qa-Dropline".into()),
            |_| {},
        )
        .unwrap();
        assert_eq!(transcribed.text, "qa-Dropline");
        assert!(started.elapsed() < Duration::from_secs(2));
    }

    #[test]
    fn tests_never_read_the_saved_selection() {
        assert!(!selected());
        select_for_test(true);
        assert!(selected());
        select_for_test(false);
        assert!(!selected());
    }

    #[test]
    fn the_context_joins_the_vocabulary() {
        let terms = vec![
            "qa-Hex".to_owned(),
            "  ".to_owned(),
            " Dropline ".to_owned(),
        ];
        assert_eq!(context(&terms).text, "qa-Hex, Dropline");
        assert_eq!(context(&[]).text, "");
    }
}
