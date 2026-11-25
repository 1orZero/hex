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

/// A meeting sent to Dropline, through the real WAV writer: two different
/// `qa-` tracks in 10 ms packets, a capture gap the writer pads, a
/// segment without speech, a segment Dropline fails, and echo. The final
/// pass takes `transcript::transcribe`'s join, as the hook runs it.
#[test]
fn a_dropline_meeting_through_the_wav_writer_keeps_times_sources_and_order() {
    use std::sync::{Arc, mpsc};

    use crate::fork::dropline::meeting::tests::{Fake, recording, scratch};

    const RATE: u32 = 16_000;
    const BLOCK: usize = 320;
    let speech = |blocks: usize| -> Vec<f32> {
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
    };
    let quiet = |blocks: usize| vec![0.0001_f32; blocks * BLOCK];
    let directory = scratch("writer");
    let fake = Arc::new(Fake::answers(&[
        Some("QA 今天我們討論頭髮，還有軟體發佈的時間。"),
        None,
        Some("我們下週上線。好的，沒問題！"),
    ]));
    let recording = recording(&directory, fake.clone());

    // System: speech, a pause (cut at block 122), 1.5 s the capture lost,
    // then speech again. Microphone: echo of the speaker, then the user.
    let mut system = speech(110);
    system.extend(quiet(40));
    let after_gap = speech(60);
    let mut microphone = quiet(25);
    microphone.extend(speech(40));
    microphone.extend(quiet(10));
    microphone.extend(speech(40));
    microphone.extend(quiet(5));

    let (sender, receiver) = mpsc::sync_channel::<AudioPacket>(64);
    let writer_directory = directory.clone();
    let writer = std::thread::spawn(move || write_tracks(&writer_directory, receiver, None));
    let start_us = 5_000_000_u64;
    let packet = |source, arrival_us, samples: &[f32]| AudioPacket {
        source,
        pts_us: None,
        arrival_us,
        position: 0,
        sample_rate: RATE,
        samples: samples.to_vec(),
    };
    let step = RATE as usize / 100;
    let mut system_done = 0_u64;
    let mut microphone_done = 0_u64;
    let system_packets = system
        .chunks(step)
        .map(|p| (false, p))
        .chain(after_gap.chunks(step).map(|p| (true, p)));
    let mut microphone_packets = microphone.chunks(step);
    for (resumed, samples) in system_packets {
        system_done += samples.len() as u64;
        let lost = if resumed { 1_500_000 } else { 0 };
        sender
            .send(packet(
                MeetingSource::System,
                start_us + lost + system_done * 1_000_000 / u64::from(RATE),
                samples,
            ))
            .unwrap();
        if let Some(samples) = microphone_packets.next() {
            microphone_done += samples.len() as u64;
            sender
                .send(packet(
                    MeetingSource::Microphone,
                    start_us + 200_000 + microphone_done * 1_000_000 / u64::from(RATE),
                    samples,
                ))
                .unwrap();
        }
    }
    drop(sender);
    let stats = writer.join().unwrap().unwrap();
    assert_eq!(stats.system.gaps.len(), 1, "{:?}", stats.system.gaps);
    let padded = stats.system.gaps[0].duration_ms * u64::from(RATE) / 1_000;

    let mut manifest = manifest("qa-dropline-writer");
    manifest.system = stats.system.clone();
    manifest.microphone = stats.microphone.clone();
    let system_origin = stats.system.first_arrival_us.unwrap() / 1_000;
    let microphone_origin = stats.microphone.first_arrival_us.unwrap() / 1_000;
    let resumed_ms = system_origin + (150 * BLOCK as u64 + padded) * 1_000 / u64::from(RATE);
    let local = |source, start_ms: u64, end_ms: u64, text: &str| TranscriptEntry {
        source,
        start_ms,
        end_ms,
        text: text.into(),
    };
    let entries = vec![
        local(
            MeetingSource::System,
            system_origin + 100,
            system_origin + 1_200,
            "qa 今天 我們 討論 頭 髮",
        ),
        local(
            MeetingSource::Microphone,
            microphone_origin + 500,
            microphone_origin + 1_300,
            "我們 下週 上線",
        ),
        local(
            MeetingSource::System,
            system_origin + 1_300,
            system_origin + 2_200,
            "還有 軟體 發布 的 時間",
        ),
        local(
            MeetingSource::Microphone,
            microphone_origin + 1_500,
            microphone_origin + 2_300,
            "好 的 沒 問題",
        ),
        local(
            MeetingSource::System,
            resumed_ms + 100,
            resumed_ms + 1_100,
            "qa 斷線 之後 的 本機 句子",
        ),
    ];
    let origin_ms = system_origin.min(microphone_origin);
    let in_call = entries[..1]
        .iter()
        .map(|entry| TranscriptEntry {
            start_ms: entry.start_ms - origin_ms,
            end_ms: entry.end_ms - origin_ms,
            ..entry.clone()
        })
        .collect::<Vec<_>>();
    let join = |mut entries: Vec<TranscriptEntry>, origin_ms: u64, (): ()| {
        entries.retain(|entry| entry.text != "我們 下週 上線");
        entries.sort_by_key(|entry| entry.start_ms);
        for entry in &mut entries {
            entry.start_ms -= origin_ms;
            entry.end_ms -= origin_ms;
        }
        (entries, 1)
    };
    let (merged, dropped) =
        crate::fork::dropline::meeting::join(&directory, &manifest, entries, origin_ms, (), join);
    assert_eq!(dropped, 1);
    let shown = merged
        .iter()
        .map(|entry| {
            (
                entry.source,
                entry.start_ms + origin_ms,
                entry.text.as_str(),
            )
        })
        .collect::<Vec<_>>();
    assert_eq!(
        shown,
        [
            (
                MeetingSource::System,
                system_origin + 100,
                "QA 今天我們討論頭髮，"
            ),
            (
                MeetingSource::System,
                system_origin + 1_300,
                "還有軟體發佈的時間。"
            ),
            (
                MeetingSource::Microphone,
                microphone_origin + 1_500,
                "好的，沒問題！"
            ),
            (
                MeetingSource::System,
                resumed_ms + 100,
                "qa 斷線 之後 的 本機 句子"
            ),
        ]
    );
    // Each segment sits where its audio is in the WAV, the gap included.
    let lines = std::fs::read_to_string(directory.join("fork-dropline.ndjson")).unwrap();
    let last = |seq: u32| {
        lines
            .lines()
            .filter_map(|line| serde_json::from_str::<serde_json::Value>(line).ok())
            .rfind(|line| line["seq"] == seq)
            .unwrap()
    };
    let block = BLOCK as u64;
    assert_eq!(
        (last(1)["start"].as_u64(), last(1)["end"].as_u64()),
        (Some(0), Some(122 * block))
    );
    assert_eq!(last(1)["state"], "done");
    assert_eq!(
        (last(2)["start"].as_u64(), last(2)["end"].as_u64()),
        (Some(122 * block), Some(150 * block))
    );
    assert_eq!(
        (last(2)["state"].as_str(), last(2)["sent"].as_bool()),
        (Some("done"), Some(false))
    );
    assert_eq!(last(3)["start"].as_u64(), Some(150 * block + padded));
    assert_eq!(
        (last(3)["state"].as_str(), last(3)["track"].as_str()),
        (Some("failed"), Some("system"))
    );
    assert_eq!(
        (last(4)["track"].as_str(), last(4)["state"].as_str()),
        (Some("microphone"), Some("done"))
    );
    assert_eq!(
        fake.log(),
        ["token", "dictate", "dictate", "dictate", "clear"]
    );
    drop(recording);

    // Copy new before Stop pastes the local text; after Stop it pastes only
    // the rest, in Dropline's words, by the local entries' times.
    let mut cursor = MeetingPasteCursor::default();
    let before = cursor
        .consume_entries("qa-dropline-writer", &in_call, |_| Ok(()))
        .unwrap();
    assert!(before.ends_with("qa 今天 我們 討論 頭 髮"), "{before}");
    let after = cursor
        .consume_entries("qa-dropline-writer", &merged, |_| Ok(()))
        .unwrap();
    assert!(!after.contains("今天"), "{after}");
    for text in [
        "還有軟體發佈的時間。",
        "好的，沒問題！",
        "qa 斷線 之後 的 本機 句子",
    ] {
        assert_eq!(after.matches(text).count(), 1, "{after}");
    }
}
