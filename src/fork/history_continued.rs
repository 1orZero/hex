//! Continued dictations in History (macOS): a dictation whose paste joins
//! the one before it (`crate::continuation`: no typing, clicking, or focus
//! change between them) reads as one sentence in the app, so History keeps
//! it as one entry too. The earlier entry takes the new text, audio, and
//! timings instead of a new entry being recorded.
//!
//! This is `crate::history`'s child (`history.rs` names this file), so it
//! changes the store's entries directly. The paster reports each paste
//! ([`paste`]) and `record_history` records its dictation through [`record`].

use std::io;
use std::path::Path;
use std::sync::{Mutex, MutexGuard};

use hound::{SampleFormat, WavReader, WavSpec, WavWriter};

use super::{
    History, HistoryDraft, HistoryKind, HistoryStore, MAX_TEXT_BYTES, PasteReuse, recordings,
    restrict_to_owner, stats, truncated, usage,
};
use crate::continuation::Continuation;

/// Where the new part's audio is written before it joins the earlier
/// recording; above every id, so a sweep leaves it alone.
const SCRATCH_ID: u64 = u64::MAX;

/// The pastes since Hex started and the entry the newest dictation made.
#[derive(Default)]
struct State {
    pastes: u64,
    paste: Option<Paste>,
    recorded: Option<Recorded>,
}

/// One paste: its number, the text it was asked to insert, and whether it
/// joined the paste before it.
struct Paste {
    number: u64,
    text: String,
    joined: bool,
}

/// The entry a dictation's paste was recorded as.
#[derive(Clone, Copy)]
struct Recorded {
    id: u64,
    paste: u64,
}

static STATE: Mutex<State> = Mutex::new(State {
    pastes: 0,
    paste: None,
    recorded: None,
});

fn state() -> MutexGuard<'static, State> {
    STATE.lock().unwrap_or_else(|error| error.into_inner())
}

/// Every paste into another app (`Paster::insert_text`), before it lands:
/// `text` as asked, and whether it continues the paste before it.
pub(crate) fn paste(text: &str, joined: bool) {
    state().note_paste(text, joined);
}

/// Records a delivered dictation whose text was `text`: into the entry the
/// previous dictation made when this dictation's paste joined that
/// dictation's paste, else as a new entry.
pub(crate) fn record(
    history: &History,
    draft: HistoryDraft,
    text: &str,
) -> io::Result<Option<u64>> {
    let mut state = state();
    let (paste, continues) = state.take(text);
    let result = match continues {
        Some(id) => match history.continue_entry(id, &draft) {
            Ok(true) => Ok(Some(id)),
            Ok(false) => history.record(draft),
            Err(error) => Err(error),
        },
        None => history.record(draft),
    };
    state.recorded = match (&result, paste) {
        (Ok(Some(id)), Some(paste)) => Some(Recorded { id: *id, paste }),
        _ => None,
    };
    result
}

impl State {
    fn note_paste(&mut self, text: &str, joined: bool) {
        self.pastes += 1;
        self.paste = Some(Paste {
            number: self.pastes,
            text: text.to_owned(),
            joined,
        });
    }

    /// The newest paste's number when it inserted `text`, and the entry it
    /// continues: the previous dictation's, when that dictation made the
    /// paste right before and this paste joined it.
    fn take(&mut self, text: &str) -> (Option<u64>, Option<u64>) {
        let Some(paste) = self.paste.take().filter(|paste| paste.text == text) else {
            return (None, None);
        };
        let continues = self
            .recorded
            .filter(|recorded| paste.joined && recorded.paste + 1 == paste.number)
            .map(|recorded| recorded.id);
        (Some(paste.number), continues)
    }
}

impl History {
    /// Adds `draft` to entry `id` ([`HistoryStore::continue_entry`]).
    fn continue_entry(&self, id: u64, draft: &HistoryDraft) -> io::Result<bool> {
        self.synced()
            .continue_entry(id, draft, super::now_ms(), crate::labs::history_stats())
    }
}

impl HistoryStore {
    /// Adds `draft` to entry `id` as the rest of its sentence: the texts
    /// joined as a paste continuation joins them, the audio, inference, and
    /// total times added, and the new audio appended to the kept recording.
    /// `yearly` (Labs › Dictation stats) adds the new words and audio to the
    /// day's rollup without counting another dictation. False, changing
    /// nothing, unless `id` is the newest entry, of the same kind, neither
    /// cancelled nor transcribed again.
    fn continue_entry(
        &mut self,
        id: u64,
        draft: &HistoryDraft,
        now_ms: u64,
        yearly: bool,
    ) -> io::Result<bool> {
        if self.retention.is_off() {
            return Ok(false);
        }
        let Some(index) = self.entries.len().checked_sub(1) else {
            return Ok(false);
        };
        let entry = &self.entries[index];
        if entry.id != id
            || entry.kind != draft.kind
            || !matches!(entry.kind, HistoryKind::Dictation | HistoryKind::Raw)
            || entry.cancelled
            || !entry.versions.is_empty()
        {
            return Ok(false);
        }
        let previous = entry.clone();
        let recording_bytes = match &draft.recording {
            Some(recording) if previous.has_recording() => {
                append_recording(&self.recordings, id, recording).unwrap_or_else(|error| {
                    tracing::warn!(%error, "could not add the continued dictation's audio");
                    0
                })
            }
            _ => 0,
        };
        let entry = &mut self.entries[index];
        entry.raw_text = truncated(&joined(&entry.raw_text, &draft.raw_text), MAX_TEXT_BYTES);
        entry.final_text = truncated(
            &joined(&entry.final_text, &draft.final_text),
            MAX_TEXT_BYTES,
        );
        entry.audio_ms = entry.audio_ms.saturating_add(draft.audio_ms);
        entry.inference_ms = entry.inference_ms.saturating_add(draft.inference_ms);
        entry.total_ms = entry.total_ms.saturating_add(draft.total_ms);
        entry.recording_bytes = recording_bytes;
        self.prune(now_ms);
        if let Err(error) = self.persist() {
            if let Some(entry) = self.entries.iter_mut().find(|entry| entry.id == id) {
                *entry = previous;
            }
            return Err(error);
        }
        if yearly {
            add_to_today(
                &self.usage,
                now_ms,
                draft.final_text.split_whitespace().count() as u64,
                draft.audio_ms,
            );
        }
        if self.entries.last().is_some_and(|entry| {
            entry.id == id && self.paste_reuse(entry, now_ms) == PasteReuse::Paste
        }) {
            self.recovery = None;
        }
        Ok(true)
    }
}

/// `next` after `previous`, with the space and capitalization a paste
/// continuation gives it.
fn joined(previous: &str, next: &str) -> String {
    let mut continuation = Continuation::default();
    continuation.record(0, true, previous.to_owned());
    let next = continuation
        .join(0, true, next)
        .unwrap_or_else(|| next.to_owned());
    format!("{previous}{next}")
}

/// Appends `recording` to entry `id`'s kept WAV in `directory`, atomically
/// and owner-only; returns the file's new size.
fn append_recording(
    directory: &Path,
    id: u64,
    recording: &recordings::Recording,
) -> io::Result<u64> {
    let scratch = recordings::path(directory, SCRATCH_ID);
    let result = recordings::write(directory, SCRATCH_ID, recording).and_then(|_| {
        let target = recordings::path(directory, id);
        let temporary = target.with_extension("wav.tmp");
        let written = (|| {
            let file = std::fs::File::create(&temporary)?;
            restrict_to_owner(&file)?;
            let spec = WavSpec {
                channels: 1,
                sample_rate: 16_000,
                bits_per_sample: 16,
                sample_format: SampleFormat::Int,
            };
            let mut writer =
                WavWriter::new(io::BufWriter::new(&file), spec).map_err(io::Error::other)?;
            for path in [&target, &scratch] {
                let mut reader = WavReader::open(path).map_err(io::Error::other)?;
                for sample in reader.samples::<i16>() {
                    writer
                        .write_sample(sample.map_err(io::Error::other)?)
                        .map_err(io::Error::other)?;
                }
            }
            writer.finalize().map_err(io::Error::other)?;
            file.sync_all()?;
            std::fs::rename(&temporary, &target)?;
            Ok(std::fs::metadata(&target)?.len())
        })();
        if written.is_err() {
            let _ = std::fs::remove_file(&temporary);
        }
        written
    });
    let _ = std::fs::remove_file(&scratch);
    result
}

/// Adds `words` and `audio_ms` to today's rollup day, when it has one; the
/// continued entry already counted there as a dictation.
fn add_to_today(path: &Path, now_ms: u64, words: u64, audio_ms: u64) {
    let today = stats::local_day(now_ms);
    let rollup = usage::Usage::load(path, today);
    if rollup.day(today).is_none() {
        return;
    }
    let days: Vec<_> = rollup
        .days()
        .iter()
        .map(|day| {
            let mut day = *day;
            if day.day == today {
                day.words = day.words.saturating_add(words);
                day.audio_ms = day.audio_ms.saturating_add(audio_ms);
            }
            day
        })
        .collect();
    if let Err(error) = usage::Usage::from_days(days).save(path, today) {
        tracing::warn!(%error, "could not add the continued dictation to the usage rollup");
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::super::{HistoryRetention, Recording};
    use super::*;

    const NOW: u64 = 1_800_000_000_000;

    fn temp_path(name: &str) -> std::path::PathBuf {
        let directory = std::env::temp_dir().join(format!(
            "hex-fork-history-continued-{name}-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&directory);
        std::fs::create_dir_all(&directory).unwrap();
        directory.join("history.json")
    }

    fn draft(raw: &str, text: &str, audio_ms: u64, recording: Option<Recording>) -> HistoryDraft {
        HistoryDraft {
            kind: HistoryKind::Dictation,
            raw_text: raw.into(),
            final_text: text.into(),
            application: Some("qa-TextEdit".into()),
            processing: None,
            audio_ms,
            inference_ms: 100,
            total_ms: 500,
            recording,
            model: Some("qa-model".into()),
        }
    }

    #[test]
    fn only_a_joined_paste_right_after_the_recorded_one_continues_its_entry() {
        let mut state = State::default();
        state.note_paste("qa-first", false);
        let (paste, continues) = state.take("qa-first");
        assert_eq!(continues, None);
        state.recorded = Some(Recorded {
            id: 7,
            paste: paste.unwrap(),
        });

        state.note_paste("qa-second", true);
        assert_eq!(state.take("qa-second"), (Some(2), Some(7)));

        state.recorded = Some(Recorded { id: 8, paste: 2 });
        state.note_paste("qa-paste-last", true);
        state.note_paste("qa-third", true);
        assert_eq!(
            state.take("qa-third"),
            (Some(4), None),
            "another paste came between"
        );

        state.recorded = Some(Recorded { id: 9, paste: 4 });
        state.note_paste("qa-fourth", false);
        assert_eq!(
            state.take("qa-fourth"),
            (Some(5), None),
            "typing ended the sentence"
        );

        state.recorded = Some(Recorded { id: 10, paste: 5 });
        state.note_paste("qa-pasted", true);
        assert_eq!(
            state.take("qa-copied"),
            (None, None),
            "this dictation didn't paste"
        );
        assert_eq!(
            state.take("qa-pasted"),
            (None, None),
            "a paste is taken once"
        );
    }

    #[test]
    fn a_continued_dictation_joins_the_entry_without_counting_another() {
        let path = temp_path("joins");
        let mut store = HistoryStore::open(path.clone(), HistoryRetention::Day, NOW);
        let id = store
            .record(draft("qa first part", "qa first part.", 16_000, None), NOW)
            .unwrap()
            .unwrap();
        let rollup = usage::path(&path);
        if !rollup.exists() {
            usage::count(&rollup, NOW, 3, 16_000).unwrap();
        }

        let second = draft("qa second part", "qa second part.", 4_000, None);
        assert!(
            store
                .continue_entry(id, &second, NOW + 9_000, true)
                .unwrap()
        );

        let entries: Vec<_> = store.entries().collect();
        assert_eq!(entries.len(), 1);
        let entry = entries[0];
        assert_eq!(entry.id, id);
        assert_eq!(entry.final_text, "qa first part. Qa second part.");
        assert_eq!(entry.raw_text, "qa first part qa second part");
        assert_eq!(
            (entry.audio_ms, entry.inference_ms, entry.total_ms),
            (20_000, 200, 1_000)
        );
        assert_eq!(entry.timestamp_ms, NOW);
        let reopened = HistoryStore::open(path.clone(), HistoryRetention::Day, NOW + 10_000);
        assert_eq!(
            reopened.entries().next().unwrap().final_text,
            "qa first part. Qa second part."
        );
        let rollup = usage::Usage::load(&usage::path(&path), stats::local_day(NOW));
        assert_eq!(
            (rollup.dictations(), rollup.words(), rollup.audio_ms()),
            (1, 6, 20_000)
        );
    }

    #[test]
    fn only_the_newest_plain_entry_is_continued() {
        let path = temp_path("newest");
        let mut store = HistoryStore::open(path, HistoryRetention::Day, NOW);
        let first = store
            .record(draft("qa one", "qa one", 1_000, None), NOW)
            .unwrap()
            .unwrap();
        let second = store
            .record(draft("qa two", "qa two", 1_000, None), NOW)
            .unwrap()
            .unwrap();
        let more = draft("qa more", "qa more", 1_000, None);
        assert!(!store.continue_entry(first, &more, NOW, false).unwrap());
        let mut sent = more.clone();
        sent.kind = HistoryKind::Send;
        assert!(!store.continue_entry(second, &sent, NOW, false).unwrap());
        assert_eq!(store.entries().count(), 2);
        assert!(store.entries().all(|entry| entry.audio_ms == 1_000));
    }

    #[test]
    fn the_continued_audio_is_appended_to_the_kept_recording() {
        let path = temp_path("audio");
        let mut store = HistoryStore::open(path, HistoryRetention::Day, NOW);
        let first = Recording::from_samples(vec![0.25; 1_600]);
        let id = store
            .record(draft("qa a", "qa a", 100, Some(first)), NOW)
            .unwrap()
            .unwrap();
        let second = Recording::from_samples(vec![-0.5; 800]);

        assert!(
            store
                .continue_entry(id, &draft("qa b", "qa b", 50, Some(second)), NOW, false)
                .unwrap()
        );

        let file = store.recording_path(id).unwrap();
        let audio: Vec<i16> = WavReader::open(&file)
            .unwrap()
            .samples::<i16>()
            .map(Result::unwrap)
            .collect();
        assert_eq!(audio.len(), 2_400);
        assert_eq!(audio[0], (0.25 * f32::from(i16::MAX)).round() as i16);
        assert_eq!(audio[2_399], (-0.5 * f32::from(i16::MAX)).round() as i16);
        let entry = store.entries().next().unwrap();
        assert_eq!(
            entry.recording_bytes,
            std::fs::metadata(&file).unwrap().len()
        );
        assert!(!recordings::path(&store.recordings, SCRATCH_ID).exists());
    }

    #[test]
    fn a_continued_dictation_without_audio_leaves_the_entry_without_audio() {
        let path = temp_path("no-audio");
        let mut store = HistoryStore::open(path, HistoryRetention::Day, NOW);
        let first = Recording::from_samples(vec![0.25; 1_600]);
        let id = store
            .record(draft("qa a", "qa a", 100, Some(first)), NOW)
            .unwrap()
            .unwrap();

        assert!(
            store
                .continue_entry(id, &draft("qa b", "qa b", 50, None), NOW, false)
                .unwrap()
        );

        assert_eq!(store.recording_path(id), None);
        assert!(!recordings::path(&store.recordings, id).exists());
    }
}
