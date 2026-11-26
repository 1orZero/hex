//! Live drafts while a dictation records with Dropline selected (macOS).
//!
//! The capture opens no local live stream then (the fork's hook in
//! `DictationCapture::begin_stream`). While the live text plate wants text
//! (Labs › Live text, or the first run's practice), every 4 s of audio the
//! recording so far goes to Dropline in the session its final text will use,
//! and the answer is what the plate shows; until the first answer it says
//! Listening…. A round whose time comes while the previous request is still
//! out is skipped. Past 180 s of audio no request goes out and the last text
//! stays, as it does after a failure no later round can get past. Without
//! the plate, no draft goes out.

use std::sync::{Arc, Mutex, MutexGuard};

use super::client::Failure;
use crate::dictation::live_text::Publisher;
use crate::transcription::engine::Partial;

/// Audio between drafts (16 kHz samples).
const INTERVAL: usize = 4 * 16_000;
/// No draft past this much audio (16 kHz samples).
const LONGEST: usize = 180 * 16_000;

/// One draft request: the recording so far (16 kHz mono) in a session.
type Request = Arc<dyn Fn(Vec<f32>, &str) -> Result<String, Failure> + Send + Sync>;

/// One recording's drafts; dropping them (the recording ends) clears the
/// plate, and an answer still out is never shown.
pub struct Drafts {
    request: Request,
    session: String,
    /// The plate, while it wants text; without it no draft goes out.
    publisher: Option<Publisher>,
    reply: Arc<Mutex<Reply>>,
    listening: bool,
    next_round: usize,
    sending: bool,
    sent: usize,
    skipped: usize,
}

#[derive(Default)]
struct Reply {
    out: bool,
    text: Option<String>,
    ended: bool,
}

impl Drafts {
    /// Puts this recording's drafts in `slot` while Dropline is selected and
    /// says whether they are there: the capture then streams nothing to the
    /// local model.
    pub fn begin(slot: &mut Option<Drafts>) -> bool {
        if slot.is_none() {
            if !selected() {
                return false;
            }
            let plate = crate::labs::live_text() || crate::dictation::live_text::board_demanded();
            let vocabulary = crate::dictation::vocabulary::terms();
            *slot = Some(Self::new(
                plate,
                super::shared_session(),
                Arc::new(move |samples, session| super::transcribe(&samples, session, &vocabulary)),
            ));
        }
        true
    }

    fn new(plate: bool, session: String, request: Request) -> Self {
        Self {
            request,
            session,
            publisher: plate.then(Publisher::new),
            reply: Arc::default(),
            listening: false,
            next_round: 1,
            sending: plate,
            sent: 0,
            skipped: 0,
        }
    }

    /// After each chunk, with the recording's 16 kHz audio so far: shows
    /// Listening… or the newest answer and sends the rounds that are due.
    /// Returns the text it showed, when it changed.
    pub fn report(&mut self, recorded: &[f32]) -> Option<Partial> {
        let publisher = self.publisher.as_ref()?;
        let mut shown = None;
        if !self.listening {
            self.listening = true;
            shown = Some(Partial {
                stable: String::new(),
                tentative: crate::desktop::i18n::tr("Listening…").to_owned(),
            });
        }
        let (text, ended, mut out) = {
            let mut reply = lock(&self.reply);
            (reply.text.take(), reply.ended, reply.out)
        };
        if let Some(text) = text {
            shown = Some(Partial {
                stable: text,
                tentative: String::new(),
            });
        }
        if let Some(partial) = &shown {
            publisher.show(partial);
        }
        if ended {
            self.stop_sending("a request failed");
        }
        while self.sending && recorded.len() >= self.next_round * INTERVAL {
            let at = self.next_round * INTERVAL;
            self.next_round += 1;
            if at > LONGEST {
                break;
            }
            if out {
                self.skipped += 1;
                tracing::debug!(
                    at_s = at / 16_000,
                    "Dropline draft skipped; the last one is still out"
                );
                continue;
            }
            self.start(recorded.to_vec());
            out = true;
        }
        if recorded.len() > LONGEST {
            self.stop_sending("over 180 s of audio");
        }
        shown
    }

    fn start(&mut self, audio: Vec<f32>) {
        self.sent += 1;
        lock(&self.reply).out = true;
        let request = self.request.clone();
        let session = self.session.clone();
        let reply = self.reply.clone();
        let audio_ms = audio.len() / 16;
        tracing::debug!(request = self.sent, audio_ms, "Dropline draft");
        let started = std::thread::Builder::new()
            .name("hex-dropline-draft".into())
            .spawn(move || {
                let result = request(audio, &session);
                let mut reply = lock(&reply);
                reply.out = false;
                match result {
                    Ok(text) => {
                        let text = text.trim();
                        if !text.is_empty() {
                            reply.text = Some(text.to_owned());
                        }
                    }
                    Err(failure) => {
                        tracing::warn!(reason = %failure, "Dropline draft failed");
                        reply.ended |= ends_drafts(&failure);
                    }
                }
            });
        if let Err(error) = started {
            tracing::warn!(%error, "could not start a Dropline draft");
            lock(&self.reply).out = false;
        }
    }

    /// No more requests for this recording; one already out still shows its
    /// text.
    fn stop_sending(&mut self, reason: &str) {
        if self.sending {
            self.sending = false;
            tracing::info!(reason, "no more Dropline drafts for this dictation");
        }
    }
}

impl Drop for Drafts {
    fn drop(&mut self) {
        if self.publisher.is_some() {
            tracing::info!(
                sent = self.sent,
                skipped = self.skipped,
                "Dropline drafts ended with the recording"
            );
        }
    }
}

/// A failure no later round gets past: Dropline refusing more requests, the
/// bearer or token, or audio Dropline would refuse.
fn ends_drafts(failure: &Failure) -> bool {
    failure.is_authorization()
        || matches!(
            failure,
            Failure::Http(429)
                | Failure::Token(_)
                | Failure::TooLong
                | Failure::Encoding(_)
                | Failure::Cancelled
        )
}

fn lock(reply: &Mutex<Reply>) -> MutexGuard<'_, Reply> {
    reply.lock().unwrap_or_else(|error| error.into_inner())
}

#[cfg(not(test))]
fn selected() -> bool {
    super::selected()
}

#[cfg(test)]
thread_local! {
    static SELECTED: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

/// Tests never read the provider saved on this Mac; one selects Dropline
/// for its own thread.
#[cfg(test)]
fn selected() -> bool {
    SELECTED.get()
}

#[cfg(test)]
mod tests;
