//! `fork-dropline.ndjson` in the meeting folder: one owner-only line per
//! event, so a meeting Hex quit or crashed in still knows which segments
//! Dropline answered, which it was sent, and whether its memory was
//! cleared. It holds segment text, never audio or credentials, and goes to
//! the Trash with the folder. A line cut short by a crash is skipped.

use std::fs::{File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::meeting::MeetingSource;

pub(super) const FILE: &str = "fork-dropline.ndjson";

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(tag = "event", rename_all = "snake_case")]
pub(super) enum Line {
    /// The meeting started with Dropline selected.
    Start {
        provider: String,
    },
    Segment(SegmentLine),
    /// The meeting's one memory clear: `cleared`, `not_cleared` (the
    /// Worker answered `cleared: false`), or `failed` with why.
    Clear {
        result: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        reason: Option<String>,
    },
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub(super) struct SegmentLine {
    pub track: MeetingSource,
    pub seq: u32,
    /// Half-open, in samples of the track resampled to 16 kHz, on its WAV's
    /// timeline.
    pub start: u64,
    pub end: u64,
    pub state: State,
    /// Audio of this segment reached the network at least once.
    pub sent: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub(super) enum State {
    Queued,
    Sending,
    /// Dropline's text, or `""` for a segment without speech that was
    /// never sent.
    Done,
    Failed,
}

pub(super) struct Writer {
    path: PathBuf,
    file: Option<File>,
}

impl Writer {
    pub(super) fn new(directory: &Path) -> Self {
        Self {
            path: directory.join(FILE),
            file: None,
        }
    }

    /// Appends `line`; a write that fails is logged and the meeting goes on.
    pub(super) fn write(&mut self, line: &Line) {
        if let Err(error) = self.append(line) {
            tracing::warn!(%error, "could not record the meeting's Dropline progress");
        }
    }

    fn append(&mut self, line: &Line) -> std::io::Result<()> {
        if self.file.is_none() {
            let mut options = OpenOptions::new();
            options.create(true).read(true).append(true);
            #[cfg(unix)]
            std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
            self.file = Some(options.open(&self.path)?);
        }
        let file = self.file.as_mut().expect("opened above");
        let mut bytes = Vec::new();
        // After a line a crash or a failed write cut short, the record
        // starts a line of its own instead of joining it.
        let mut last = [0];
        if file.seek(SeekFrom::End(-1)).is_ok()
            && file.read_exact(&mut last).is_ok()
            && last != *b"\n"
        {
            bytes.push(b'\n');
        }
        bytes.extend(serde_json::to_vec(line).map_err(std::io::Error::other)?);
        bytes.push(b'\n');
        file.write_all(&bytes)?;
        file.sync_data()
    }
}

/// The meeting's lines, without one a crash cut short.
pub(super) fn read(directory: &Path) -> Vec<Line> {
    let Ok(bytes) = std::fs::read(directory.join(FILE)) else {
        return Vec::new();
    };
    bytes
        .split(|byte| *byte == b'\n')
        .filter_map(|line| serde_json::from_slice(line).ok())
        .collect()
}

pub(super) fn exists(directory: &Path) -> bool {
    directory.join(FILE).exists()
}

/// What the lines say in the end: each segment's last line in order, and
/// whether the memory clear has an outcome recorded, whatever it was, so it
/// never runs twice.
pub(super) struct Summary {
    pub segments: Vec<SegmentLine>,
    pub clear_recorded: bool,
}

impl Summary {
    pub(super) fn of(lines: Vec<Line>) -> Self {
        let mut segments: Vec<SegmentLine> = Vec::new();
        let mut clear_recorded = false;
        for line in lines {
            match line {
                Line::Start { .. } => {}
                Line::Clear { .. } => clear_recorded = true,
                Line::Segment(segment) => {
                    match segments
                        .iter_mut()
                        .find(|known| known.track == segment.track && known.seq == segment.seq)
                    {
                        Some(known) => {
                            let sent = known.sent || segment.sent;
                            *known = segment;
                            known.sent = sent;
                        }
                        None => segments.push(segment),
                    }
                }
            }
        }
        Self {
            segments,
            clear_recorded,
        }
    }

    pub(super) fn sent(&self) -> bool {
        self.segments.iter().any(|segment| segment.sent)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn segment(seq: u32, state: State, sent: bool, text: Option<&str>) -> Line {
        Line::Segment(SegmentLine {
            track: MeetingSource::System,
            seq,
            start: u64::from(seq) * 100,
            end: u64::from(seq) * 100 + 100,
            state,
            sent,
            text: text.map(str::to_owned),
            reason: None,
        })
    }

    #[test]
    fn the_last_line_of_each_segment_wins_and_sent_sticks() {
        let directory = super::super::tests::scratch("sidecar");
        let mut writer = Writer::new(&directory);
        for line in [
            Line::Start {
                provider: "dropline-private".into(),
            },
            segment(1, State::Queued, false, None),
            segment(1, State::Sending, true, None),
            segment(2, State::Queued, false, None),
            segment(1, State::Failed, false, None),
            segment(2, State::Done, false, Some("")),
        ] {
            writer.write(&line);
        }
        let summary = Summary::of(read(&directory));
        assert_eq!(summary.segments.len(), 2);
        assert_eq!(summary.segments[0].state, State::Failed);
        assert!(summary.segments[0].sent);
        assert_eq!(summary.segments[1].text.as_deref(), Some(""));
        assert!(!summary.segments[1].sent);
        assert!(summary.sent() && !summary.clear_recorded);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(directory.join(FILE))
                .unwrap()
                .permissions()
                .mode();
            assert_eq!(mode & 0o777, 0o600);
        }
    }

    #[test]
    fn a_line_cut_short_is_skipped() {
        let directory = super::super::tests::scratch("sidecar");
        let mut writer = Writer::new(&directory);
        writer.write(&segment(1, State::Done, true, Some("qa-完成")));
        writer.write(&Line::Clear {
            result: "cleared".into(),
            reason: None,
        });
        let path = directory.join(FILE);
        let mut text = std::fs::read_to_string(&path).unwrap();
        text.push_str(r#"{"event":"segment","track":"system","seq":2,"sta"#);
        std::fs::write(path, text).unwrap();
        let summary = Summary::of(read(&directory));
        assert_eq!(summary.segments.len(), 1);
        assert_eq!(summary.segments[0].text.as_deref(), Some("qa-完成"));
        assert!(summary.clear_recorded);
        assert!(
            Summary::of(read(&directory.join("qa-missing")))
                .segments
                .is_empty()
        );
    }

    #[test]
    fn a_record_after_a_line_cut_short_starts_a_line_of_its_own() {
        let directory = super::super::tests::scratch("sidecar-tail");
        Writer::new(&directory).write(&segment(1, State::Done, true, Some("qa-完成")));
        let path = directory.join(FILE);
        let mut text = std::fs::read_to_string(&path).unwrap();
        text.push_str(r#"{"event":"segment","track":"system","seq":2,"sta"#);
        std::fs::write(&path, text).unwrap();
        Writer::new(&directory).write(&Line::Clear {
            result: "cleared".into(),
            reason: None,
        });
        let summary = Summary::of(read(&directory));
        assert_eq!(summary.segments.len(), 1);
        assert!(summary.clear_recorded);
    }

    #[test]
    fn a_line_cut_inside_a_character_keeps_the_lines_before_it() {
        let directory = super::super::tests::scratch("sidecar-utf8");
        let mut writer = Writer::new(&directory);
        writer.write(&segment(1, State::Done, true, Some("qa-完成")));
        writer.write(&Line::Clear {
            result: "cleared".into(),
            reason: None,
        });
        let path = directory.join(FILE);
        let mut bytes = std::fs::read(&path).unwrap();
        let cut = serde_json::to_vec(&segment(2, State::Done, true, Some("qa-第二段"))).unwrap();
        let inside = cut
            .windows(3)
            .position(|window| window == "第".as_bytes())
            .unwrap()
            + 1;
        bytes.extend_from_slice(&cut[..inside]);
        std::fs::write(path, bytes).unwrap();
        let summary = Summary::of(read(&directory));
        assert_eq!(summary.segments.len(), 1);
        assert_eq!(summary.segments[0].text.as_deref(), Some("qa-完成"));
        assert!(summary.clear_recorded);
    }
}
