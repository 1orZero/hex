//! The fork's checks of meeting behaviour that only the meeting module can
//! reach: every generated title and summary in Traditional Chinese, for
//! either notes writer, while what the user typed stays as typed.

use std::time::{Duration, Instant};

use super::chapters::{Chaptering, pass_window, run_pass};
use super::generator::{GeneratedChapter, GeneratedNotes, NotesWriter};
use super::notes::{display_title, provisional_title, summarize_entries};
use super::*;

fn entry(source: MeetingSource, start_ms: u64, text: &str) -> TranscriptEntry {
    TranscriptEntry {
        source,
        start_ms,
        end_ms: start_ms + 4_000,
        text: text.into(),
    }
}

fn conversation() -> Vec<TranscriptEntry> {
    (0..6)
        .map(|turn| {
            let source = if turn % 2 == 0 {
                MeetingSource::Microphone
            } else {
                MeetingSource::System
            };
            entry(source, turn * 5_000, "qa-我们讨论软件发布和文件。")
        })
        .collect()
}

fn writers() -> [NotesWriter; 2] {
    [
        NotesWriter::AppleIntelligence,
        NotesWriter::OpenCode {
            model: Some("qa-provider/qa-model".into()),
        },
    ]
}

fn later() -> Instant {
    Instant::now() + Duration::from_secs(30)
}

#[test]
fn notes_from_either_writer_are_traditional() {
    for writer in writers() {
        let summary = summarize_entries(&conversation(), 8_000, later(), |_, _, _| {
            Ok(GeneratedNotes {
                title: "qa-软件会议".into(),
                summary: "qa-讨论了头发和软件。会后再说。".into(),
                written_by: Some(writer.clone()),
            })
        })
        .unwrap();
        assert_eq!(summary.notes.title, "qa-軟件會議");
        assert_eq!(summary.notes.summary, "qa-討論了頭髮和軟件。會後再說。");
        assert_eq!(summary.notes.written_by, Some(writer));
    }
}

#[test]
fn a_long_chinese_summary_without_spaces_is_cut_at_a_character() {
    // 3 + 3 × 199 bytes: byte 400 falls inside a character.
    let long = format!("qa-{}", "这是一个很长的会议摘要".repeat(20));
    let summary = summarize_entries(&conversation(), 8_000, later(), |_, _, _| {
        Ok(GeneratedNotes {
            title: "qa-长摘要".into(),
            summary: long.clone(),
            written_by: Some(NotesWriter::AppleIntelligence),
        })
    })
    .unwrap()
    .notes
    .summary;
    assert!(summary.ends_with('…'), "{summary}");
    assert!(summary.len() <= 400 + '…'.len_utf8(), "{}", summary.len());
    assert!(
        summary.starts_with("qa-這是一個很長的會議摘要"),
        "{summary}"
    );
}

#[test]
fn a_provisional_title_is_traditional() {
    let title = provisional_title(&conversation(), 5_000, Duration::from_secs(5), |_, _, _| {
        Ok("qa-软件发布".into())
    })
    .unwrap();
    assert!(title.starts_with("qa-軟件"), "{title}");
    assert!(!title.contains('软'), "{title}");
}

#[test]
fn live_chapter_titles_and_summaries_are_traditional() {
    let mut state = Chaptering::default();
    let window = pass_window(&conversation(), 0, 4_000).unwrap();
    run_pass(&mut state, &window, &[], |_, _, _| {
        Ok(GeneratedChapter {
            title: "qa-软件会议".into(),
            summary: "qa-讨论头发和文件。".into(),
            same_topic: false,
        })
    })
    .unwrap();
    assert_eq!(state.chapters.len(), 1);
    assert_eq!(state.chapters[0].title, "qa-軟件會議");
    assert_eq!(state.chapters[0].summary, "qa-討論頭髮和文件。");
}

#[test]
fn a_title_the_user_typed_keeps_its_script() {
    let notes = summarize_entries(&conversation(), 8_000, later(), |_, _, _| {
        Ok(GeneratedNotes {
            title: "qa-软件发布".into(),
            summary: "qa-讨论头发。".into(),
            written_by: Some(NotesWriter::AppleIntelligence),
        })
    })
    .unwrap()
    .notes;
    let mut manifest = manifest("qa-typed");
    manifest.title = "qa-我的软件会议".into();
    manifest.title_source = Some(TitleSource::User);
    manifest.notes = Some(
        serde_json::from_value(serde_json::json!({
            "title": notes.title,
            "summary": notes.summary,
        }))
        .unwrap(),
    );
    manifest.chapters = vec![Chapter {
        title: "qa-軟件會議".into(),
        summary: String::new(),
        start_ms: 0,
    }];
    assert_eq!(display_title(&manifest), "qa-我的软件会议");
    // The same meeting without a typed title shows the generated one, converted.
    manifest.title_source = Some(TitleSource::Default);
    let shown = display_title(&manifest);
    assert!(shown.starts_with("qa-軟件"), "{shown}");
    assert!(!shown.contains('软'), "{shown}");
}

#[test]
fn every_meeting_chunk_is_traditional_before_its_words_are_joined() {
    use super::transcript::{ReplayChunk, replay_envelope, replay_track, replay_views};

    let chunk: ReplayChunk = serde_json::from_value(serde_json::json!({
        "start": 0,
        "overlap": 0,
        "len": 48_000,
        "transcript": {
            "text": "qa-头发很好",
            "segments": [{ "startMs": 0, "endMs": 2_000, "text": "qa-头发很好" }],
            "words": [
                { "startMs": 0, "endMs": 500, "text": "qa-头" },
                { "startMs": 500, "endMs": 1_000, "text": "发" },
                { "startMs": 1_000, "endMs": 1_500, "text": "很" },
                { "startMs": 1_500, "endMs": 2_000, "text": "好" }
            ]
        }
    }))
    .unwrap();
    let system = replay_track(MeetingSource::System, &[chunk], u64::MAX);
    let microphone = replay_track(MeetingSource::Microphone, &[], u64::MAX);
    let (_, kept, _) = replay_views(&system, &microphone, &replay_envelope(&[], &[]));
    let shown = kept
        .iter()
        .map(|entry| (entry.start_ms, entry.end_ms, entry.text.as_str()))
        .collect::<Vec<_>>();
    assert_eq!(shown, [(0, 2_000, "qa-頭 髮 很 好")]);
}

pub(super) fn manifest(id: &str) -> MeetingManifest {
    MeetingManifest {
        schema_version: 1,
        id: id.into(),
        title: "qa-meeting".into(),
        status: MeetingStatus::Recording,
        created_at_ms: 1_000,
        ended_at_ms: None,
        duration_ms: None,
        system: TrackManifest {
            file: "system.wav".into(),
            ..TrackManifest::default()
        },
        microphone: TrackManifest {
            file: "microphone.wav".into(),
            ..TrackManifest::default()
        },
        live_transcription_error: None,
        error: None,
        app: None,
        export_path: None,
        export_error: None,
        echo_suppressed_utterances: 0,
        provisional_title: None,
        notes: None,
        notes_error: None,
        calendar: None,
        title_source: None,
        chapters: Vec::new(),
        chapters_refined: false,
        retention_applies: false,
        export_sha256: None,
        notes_export_path: None,
        notes_export_sha256: None,
        notes_export_removed: false,
        audio_removed_at_ms: None,
        imported: false,
    }
}
