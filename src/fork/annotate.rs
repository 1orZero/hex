//! Annotate's transcript in Traditional Chinese. The capture engine and the
//! replay narration transcribe through [`Traditional`], so every reader of
//! the bundle (`summary.md`, `scrawl.json`, each keyframe's narration, the
//! clipboard and Paste) gets the converted text, and every word keeps its
//! times.

use std::path::Path;
use std::sync::Arc;

use scrawl_capture::audio::RecordedAudio;
use scrawl_capture::model::TranscriptData;
use scrawl_capture::transcribe::Transcriber;

/// Hex's chosen transcriber (Hex's model or Apple Speech) with its text,
/// segments, and words converted.
pub(crate) struct Traditional(pub(crate) Arc<dyn Transcriber>);

/// The capture engine's transcriber, converted.
pub(crate) fn traditional(transcriber: Arc<dyn Transcriber>) -> Arc<dyn Transcriber> {
    Arc::new(Traditional(transcriber))
}

impl Transcriber for Traditional {
    fn transcribe(&self, audio: &RecordedAudio) -> anyhow::Result<Option<TranscriptData>> {
        Ok(self.0.transcribe(audio)?.map(convert))
    }

    fn transcribe_wav(
        &self,
        wav_path: &Path,
        duration_ms: u64,
    ) -> anyhow::Result<Option<TranscriptData>> {
        Ok(self.0.transcribe_wav(wav_path, duration_ms)?.map(convert))
    }
}

fn convert(mut transcript: TranscriptData) -> TranscriptData {
    transcript.text = super::traditional::text(&transcript.text);
    for segment in &mut transcript.segments {
        segment.text = super::traditional::text(&segment.text);
    }
    super::traditional::words(transcript.words.iter_mut().map(|word| &mut word.text));
    transcript
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex;

    use scrawl_capture::model::{MissingTranscript, TranscriptSegment, WordTiming};

    use super::*;

    /// Answers like a backend: Hex's model gives words, Apple Speech gives
    /// segments too, and either can be missing.
    struct Scripted {
        answer: Option<TranscriptData>,
        calls: Mutex<Vec<&'static str>>,
    }

    impl Transcriber for Scripted {
        fn transcribe(&self, _: &RecordedAudio) -> anyhow::Result<Option<TranscriptData>> {
            self.calls.lock().unwrap().push("audio");
            Ok(self.answer.clone())
        }

        fn transcribe_wav(&self, _: &Path, _: u64) -> anyhow::Result<Option<TranscriptData>> {
            self.calls.lock().unwrap().push("wav");
            Ok(self.answer.clone())
        }
    }

    fn word(t0: u64, t1: u64, text: &str) -> WordTiming {
        WordTiming {
            t0,
            t1,
            text: text.into(),
        }
    }

    fn scripted(answer: Option<TranscriptData>) -> Arc<Scripted> {
        Arc::new(Scripted {
            answer,
            calls: Mutex::new(Vec::new()),
        })
    }

    fn audio() -> RecordedAudio {
        RecordedAudio::new(vec![0.0; 160], 16_000, 0, Vec::new())
    }

    #[test]
    fn hex_words_convert_as_a_phrase_and_keep_their_times() {
        let inner = scripted(Some(TranscriptData {
            source: "hex".into(),
            model: Some("qa-model".into()),
            text: "qa-头发很好 软件".into(),
            words: vec![
                word(1_000, 1_200, "qa-头"),
                word(1_200, 1_400, "发"),
                word(1_400, 1_600, "很"),
                word(1_600, 1_800, "好"),
                word(2_000, 2_400, "软件"),
            ],
            ..TranscriptData::default()
        }));
        let converted = Traditional(inner.clone())
            .transcribe(&audio())
            .unwrap()
            .unwrap();
        assert_eq!(converted.text, "qa-頭髮很好 軟件");
        assert_eq!(
            converted.words,
            [
                word(1_000, 1_200, "qa-頭"),
                word(1_200, 1_400, "髮"),
                word(1_400, 1_600, "很"),
                word(1_600, 1_800, "好"),
                word(2_000, 2_400, "軟件"),
            ]
        );
        assert_eq!(converted.source, "hex");
        assert_eq!(converted.model.as_deref(), Some("qa-model"));
        assert_eq!(*inner.calls.lock().unwrap(), ["audio"]);
    }

    #[test]
    fn apple_segments_and_estimated_words_convert_and_keep_their_flags() {
        let inner = scripted(Some(TranscriptData {
            source: "apple".into(),
            text: "qa-请打开软件。皇后".into(),
            segments: vec![
                TranscriptSegment {
                    t0: 0,
                    t1: 900,
                    text: "qa-请打开软件。".into(),
                },
                TranscriptSegment {
                    t0: 900,
                    t1: 1_500,
                    text: "皇后".into(),
                },
            ],
            words: vec![word(0, 400, "qa-请打开"), word(400, 900, "软件。")],
            estimated: true,
            ..TranscriptData::default()
        }));
        let converted = Traditional(inner.clone())
            .transcribe_wav(Path::new("qa-annotate.wav"), 1_500)
            .unwrap()
            .unwrap();
        assert_eq!(converted.text, "qa-請打開軟件。皇后");
        assert_eq!(
            converted.segments,
            [
                TranscriptSegment {
                    t0: 0,
                    t1: 900,
                    text: "qa-請打開軟件。".into(),
                },
                TranscriptSegment {
                    t0: 900,
                    t1: 1_500,
                    text: "皇后".into(),
                },
            ]
        );
        assert_eq!(
            converted.words,
            [word(0, 400, "qa-請打開"), word(400, 900, "軟件。")]
        );
        assert!(converted.estimated);
        assert_eq!(*inner.calls.lock().unwrap(), ["wav"]);
    }

    #[test]
    fn a_missing_transcript_and_no_transcriber_pass_through() {
        let missing = MissingTranscript {
            reason: "qa-no speech model yet".into(),
            retry: true,
        };
        let inner = scripted(Some(TranscriptData {
            source: "apple".into(),
            missing: Some(missing.clone()),
            ..TranscriptData::default()
        }));
        let converted = Traditional(inner).transcribe(&audio()).unwrap().unwrap();
        assert_eq!(converted.missing, Some(missing));
        assert!(converted.text.is_empty());
        assert_eq!(
            Traditional(scripted(None)).transcribe(&audio()).unwrap(),
            None
        );
    }

    #[test]
    fn the_capture_pipeline_normalizes_the_converted_words_into_segments() {
        let transcriber = traditional(scripted(Some(TranscriptData {
            source: "hex".into(),
            text: "qa-头发".into(),
            words: vec![word(0, 300, "qa-头"), word(300, 600, "发")],
            ..TranscriptData::default()
        })));
        let audio = audio();
        let transcript =
            scrawl_capture::transcribe::transcribe_with(None, Some(&audio), transcriber.as_ref());
        assert_eq!(transcript.text, "qa-頭髮");
        assert!(
            transcript
                .segments
                .iter()
                .all(|segment| !segment.text.contains('发')),
            "{:?}",
            transcript.segments
        );
        assert!(!transcript.segments.is_empty());
    }
}
