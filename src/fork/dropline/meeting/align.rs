//! Puts Dropline's text on the local transcript's times (ADR-0003, 0008).
//! Dropline returns no times, so each successful segment's text is aligned
//! character by character with the local entries of the same track inside
//! it, as both were before echo suppression. Each local entry's boundary
//! maps into Dropline's text and moves to nearby punctuation; an entry
//! suppression kept gets its share of Dropline's text, and the share of an
//! entry it judged echo is dropped with it. An entry spanning segments joins
//! its shares, and keeps its local text when a stretch it overlaps gave it
//! none. A segment whose alignment is too weak keeps its local text.

use crate::meeting::{MeetingSource, TranscriptEntry};

/// A segment whose aligned characters are fewer than this share of its
/// longer side keeps its local text.
pub(super) const THRESHOLD: f64 = 0.4;
/// Sides longer than this together are not aligned (memory), so the segment
/// keeps its local text.
const MAX_CELLS: usize = 16_000_000;
/// How many characters a boundary may move to reach punctuation.
const PUNCTUATION_REACH: usize = 3;

/// One answered segment, on the capture clock.
pub(super) struct Answered<'a> {
    pub track: MeetingSource,
    pub seq: u32,
    pub start_ms: u64,
    pub end_ms: u64,
    pub text: &'a str,
}

/// `kept` (meeting clock, after echo suppression) with Dropline's text in
/// place of the local text inside each answered segment it aligns with.
/// `before_echo` is the same transcript on the capture clock before
/// suppression; `origin_ms` moves one clock onto the other.
pub(super) fn merge(
    before_echo: &[TranscriptEntry],
    kept: Vec<TranscriptEntry>,
    origin_ms: u64,
    answered: &[Answered<'_>],
) -> Vec<TranscriptEntry> {
    let mut before = before_echo.to_vec();
    before.sort_by_key(|entry| entry.start_ms);
    // Suppression keeps a subsequence of the sorted entries and only moves
    // their times.
    let mut kept_at = vec![None; before.len()];
    let mut next = 0;
    for (index, entry) in kept.iter().enumerate() {
        while let Some(candidate) = before.get(next) {
            next += 1;
            if candidate.source == entry.source
                && candidate.text == entry.text
                && candidate.start_ms.saturating_sub(origin_ms) == entry.start_ms
                && candidate.end_ms.saturating_sub(origin_ms) == entry.end_ms
            {
                kept_at[next - 1] = Some(index);
                break;
            }
        }
    }
    let mut parts = vec![Vec::new(); before.len()];
    for (index, share) in segment_shares(&before, answered) {
        parts[index].push(share);
    }
    // A kept entry takes Dropline's text only when every stretch it overlaps
    // gave it a share. Either way it took part in each segment's alignment,
    // so Dropline's words for it never go to a neighbour.
    let mut texts: Vec<Option<String>> = vec![None; kept.len()];
    for (index, entry) in before.iter().enumerate() {
        if let Some(kept) = kept_at[index]
            && !parts[index].is_empty()
            && covered(entry, answered)
        {
            texts[kept] = parts[index]
                .iter()
                .cloned()
                .collect::<Option<Vec<_>>>()
                .map(|shares| joined(&shares));
        }
    }
    kept.into_iter()
        .zip(texts)
        .filter_map(|(mut entry, text)| match text {
            None => Some(entry),
            Some(text) if text.is_empty() => None,
            Some(text) => {
                entry.text = text;
                Some(entry)
            }
        })
        .collect()
}

/// Each entry of `before`'s share of Dropline's text in every answered
/// segment it overlaps, in time order: `None` where the segment aligns too
/// weakly, or where Dropline heard nothing in the segment holding the
/// entry's middle.
fn segment_shares(
    before: &[TranscriptEntry],
    answered: &[Answered<'_>],
) -> Vec<(usize, Option<String>)> {
    let mut segments = answered.iter().collect::<Vec<_>>();
    segments.sort_by_key(|segment| segment.start_ms);
    let mut found = Vec::new();
    for segment in segments {
        let inside = before
            .iter()
            .enumerate()
            .filter(|(_, entry)| entry.source == segment.track)
            .filter_map(|(index, entry)| {
                let middle = (entry.start_ms + entry.end_ms) / 2;
                let owns = segment.start_ms <= middle && middle < segment.end_ms;
                let crosses = entry.start_ms < segment.end_ms && segment.start_ms < entry.end_ms;
                (owns || crosses).then_some((index, entry.text.as_str(), owns))
            })
            .collect::<Vec<_>>();
        let local = inside.iter().map(|(_, text, _)| *text).collect::<Vec<_>>();
        if segment.text.trim().is_empty() {
            if !local.is_empty() {
                tracing::info!(
                    track = ?segment.track,
                    seq = segment.seq,
                    entries = local.len(),
                    "Dropline heard no speech where the local model did; keeping local text"
                );
            }
            found.extend(
                inside
                    .iter()
                    .map(|(index, _, owns)| (*index, (!owns).then(String::new))),
            );
            continue;
        }
        let aligned = shares(&local, segment.text);
        match &aligned {
            None => tracing::info!(
                track = ?segment.track,
                seq = segment.seq,
                entries = local.len(),
                "could not align a Dropline meeting segment; keeping local text"
            ),
            Some((ratio, _)) => tracing::info!(
                track = ?segment.track,
                seq = segment.seq,
                ratio = (ratio * 1000.0).round() / 1000.0,
                "aligned a Dropline meeting segment"
            ),
        }
        match aligned {
            Some((ratio, shares)) if ratio >= THRESHOLD => found.extend(
                inside
                    .iter()
                    .zip(shares)
                    .map(|((index, _, _), share)| (*index, Some(share))),
            ),
            _ => found.extend(inside.iter().map(|(index, _, _)| (*index, None))),
        }
    }
    found
}

/// Whether answered segments of `entry`'s track cover all of it.
fn covered(entry: &TranscriptEntry, answered: &[Answered<'_>]) -> bool {
    let mut segments = answered
        .iter()
        .filter(|segment| segment.track == entry.source)
        .map(|segment| (segment.start_ms, segment.end_ms))
        .collect::<Vec<_>>();
    segments.sort_unstable();
    let mut reached = entry.start_ms;
    for (start_ms, end_ms) in segments {
        if start_ms <= reached && reached < end_ms {
            reached = end_ms;
        }
    }
    reached >= entry.end_ms
}

/// `shares` in order, with a space where a word of a script written with
/// spaces, such as `café`, meets the next word, and none after an opening
/// bracket or before closing punctuation.
fn joined(shares: &[String]) -> String {
    let opening = |character: char| matches!(character, '(' | '[' | '{');
    let mut text = String::new();
    for share in shares.iter().filter(|share| !share.is_empty()) {
        let ends_word = text.chars().next_back().is_some_and(|character| {
            !character.is_whitespace() && !unspaced(character) && !opening(character)
        });
        let starts_word = share.chars().next().is_some_and(|character| {
            (character.is_alphanumeric() || opening(character)) && !unspaced(character)
        });
        if ends_word && starts_word {
            text.push(' ');
        }
        text.push_str(share);
    }
    text
}

/// Each of `local`'s entries' share of `remote`, and the share of
/// characters that aligned; `None` when there is nothing to align.
fn shares(local: &[&str], remote: &str) -> Option<(f64, Vec<String>)> {
    let local_chars = local
        .iter()
        .enumerate()
        .flat_map(|(entry, text)| normalized(text).into_iter().map(move |(c, _)| (c, entry)))
        .collect::<Vec<_>>();
    let remote_chars = normalized(remote);
    let (n, m) = (local_chars.len(), remote_chars.len());
    if n == 0 || m == 0 || n.saturating_mul(m) > MAX_CELLS {
        return None;
    }
    let pairs = common_subsequence(
        &local_chars.iter().map(|(c, _)| *c).collect::<Vec<_>>(),
        &remote_chars.iter().map(|(c, _)| *c).collect::<Vec<_>>(),
    );
    let ratio = pairs.len() as f64 / n.max(m) as f64;
    // Where each entry starts among the local characters.
    let mut firsts = vec![None; local.len()];
    for (index, (_, entry)) in local_chars.iter().enumerate().rev() {
        firsts[*entry] = Some(index);
    }
    let mut cuts = Vec::with_capacity(local.len() + 1);
    cuts.push(0);
    for first in firsts.iter().skip(1) {
        let previous = *cuts.last().unwrap();
        let Some(first) = *first else {
            cuts.push(previous);
            continue;
        };
        // After the last remote character aligned before this entry.
        let at = pairs
            .iter()
            .rev()
            .find(|(i, _)| *i < first)
            .map_or(0, |(_, j)| remote_chars[*j].1.end);
        let next = pairs
            .iter()
            .find(|(i, _)| *i >= first)
            .map_or(remote.len(), |(_, j)| remote_chars[*j].1.start);
        let cut = near_punctuation(remote, &remote_chars, at, next);
        let cut = outside_word(remote, cut, next).max(previous);
        cuts.push(cut);
    }
    cuts.push(remote.len());
    let shares = cuts
        .windows(2)
        .map(|cut| remote[cut[0]..cut[1].max(cut[0])].trim().to_owned())
        .collect();
    Some((ratio, shares))
}

/// A boundary at byte `at` of `text`, moved just past punctuation within
/// a few characters when there is some, and never past `next`, the next
/// entry's first aligned character.
fn near_punctuation(
    text: &str,
    characters: &[(char, std::ops::Range<usize>)],
    at: usize,
    next: usize,
) -> usize {
    let lower = characters
        .iter()
        .rev()
        .filter(|(_, range)| range.end <= at)
        .nth(PUNCTUATION_REACH - 1)
        .map_or(0, |(_, range)| range.start);
    let upper = characters
        .iter()
        .filter(|(_, range)| range.start >= next)
        .nth(PUNCTUATION_REACH - 1)
        .map_or(text.len(), |(_, range)| range.end)
        .min(next.max(at));
    text.char_indices()
        .filter(|(index, character)| {
            *index >= lower && *index < upper && separates(text, *index, *character)
        })
        .map(|(index, character)| index + character.len_utf8())
        .filter(|end| *end <= next.max(at))
        .min_by_key(|end| end.abs_diff(at))
        .unwrap_or(at)
}

/// A boundary at byte `cut` of `text` moved out of a word it falls inside,
/// a run of letters and digits of a script written with spaces and marks
/// that `joins`: to the word's end when that comes no later than `next`,
/// else to its start.
fn outside_word(text: &str, cut: usize, next: usize) -> usize {
    let word =
        |character: char| (character.is_alphanumeric() && !unspaced(character)) || joins(character);
    let (before, after) = text.split_at(cut);
    if !before.ends_with(word) || !after.starts_with(word) {
        return cut;
    }
    let end = text.len() - after.trim_start_matches(word).len();
    if end <= next.max(cut) {
        end
    } else {
        before.trim_end_matches(word).len()
    }
}

/// A mark that can sit inside a word or number, such as the `'` in `can't`
/// or the `.` in `1.5`, unlike a dash or ellipsis.
fn joins(character: char) -> bool {
    character.is_ascii_punctuation() || character == '’'
}

/// A character of a script written without spaces between words (Thai,
/// Lao, Tibetan, Burmese, Khmer, Chinese, Japanese) or a full-width form,
/// such as `，`.
fn unspaced(character: char) -> bool {
    matches!(
        character,
        '\u{0E00}'..='\u{0FFF}'
            | '\u{1000}'..='\u{109F}'
            | '\u{1780}'..='\u{17FF}'
            | '\u{2E80}'..='\u{9FFF}'
            | '\u{F900}'..='\u{FAFF}'
            | '\u{FE30}'..='\u{FE4F}'
            | '\u{FF00}'..='\u{FFEF}'
            | '\u{20000}'..='\u{3FFFF}'
    )
}

/// Punctuation that ends a phrase, unlike a mark that `joins` between two
/// ASCII letters or digits, as in `1.5` or `can't`.
fn separates(text: &str, index: usize, character: char) -> bool {
    let inside_word = joins(character)
        && text[..index]
            .chars()
            .next_back()
            .is_some_and(|before| before.is_ascii_alphanumeric())
        && text[index + character.len_utf8()..]
            .chars()
            .next()
            .is_some_and(|after| after.is_ascii_alphanumeric());
    !character.is_alphanumeric() && !character.is_whitespace() && !inside_word
}

/// The characters alignment compares, each with its bytes in `text`:
/// simplified, lowercase, without spaces and punctuation, so 乾/幹/干 and
/// letter case never count as differences.
fn normalized(text: &str) -> Vec<(char, std::ops::Range<usize>)> {
    let simple = simplified(text);
    let same_length = simple.chars().count() == text.chars().count();
    text.char_indices()
        .zip(simple.chars().chain(std::iter::repeat(' ')))
        .filter(|((_, original), _)| original.is_alphanumeric())
        .map(|((index, original), simple)| {
            let compared = if same_length { simple } else { original };
            (
                compared.to_lowercase().next().unwrap_or(compared),
                index..index + original.len_utf8(),
            )
        })
        .collect()
}

fn simplified(text: &str) -> String {
    use objc2_foundation::{NSString, ns_string};
    if text.is_ascii() {
        return text.to_owned();
    }
    objc2::rc::autoreleasepool(|_| {
        NSString::from_str(text)
            .stringByApplyingTransform_reverse(ns_string!("Hant-Hans"), false)
            .map_or_else(|| text.to_owned(), |simple| simple.to_string())
    })
}

/// The longest common subsequence of `a` and `b` as index pairs, in order.
fn common_subsequence(a: &[char], b: &[char]) -> Vec<(usize, usize)> {
    let (n, m) = (a.len(), b.len());
    let mut lengths = vec![0_u32; (n + 1) * (m + 1)];
    let at = |i: usize, j: usize| i * (m + 1) + j;
    for i in (0..n).rev() {
        for j in (0..m).rev() {
            lengths[at(i, j)] = if a[i] == b[j] {
                lengths[at(i + 1, j + 1)] + 1
            } else {
                lengths[at(i + 1, j)].max(lengths[at(i, j + 1)])
            };
        }
    }
    let (mut i, mut j) = (0, 0);
    let mut pairs = Vec::new();
    while i < n && j < m {
        if a[i] == b[j] {
            pairs.push((i, j));
            i += 1;
            j += 1;
        } else if lengths[at(i + 1, j)] >= lengths[at(i, j + 1)] {
            i += 1;
        } else {
            j += 1;
        }
    }
    pairs
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(source: MeetingSource, start_ms: u64, end_ms: u64, text: &str) -> TranscriptEntry {
        TranscriptEntry {
            source,
            start_ms,
            end_ms,
            text: text.into(),
        }
    }

    const YOU: MeetingSource = MeetingSource::Microphone;
    const THEM: MeetingSource = MeetingSource::System;

    fn shifted(entries: &[TranscriptEntry], origin_ms: u64) -> Vec<TranscriptEntry> {
        entries
            .iter()
            .map(|entry| TranscriptEntry {
                start_ms: entry.start_ms - origin_ms,
                end_ms: entry.end_ms - origin_ms,
                ..entry.clone()
            })
            .collect()
    }

    fn texts(entries: &[TranscriptEntry]) -> Vec<(MeetingSource, u64, &str)> {
        entries
            .iter()
            .map(|entry| (entry.source, entry.start_ms, entry.text.as_str()))
            .collect()
    }

    #[test]
    fn local_boundaries_split_dropline_text_at_punctuation() {
        let before = [
            entry(THEM, 10_000, 12_000, "qa 今天 我們 討論 頭 發"),
            entry(THEM, 12_500, 15_000, "還有 軟體 發布 的 時間"),
        ];
        let merged = merge(
            &before,
            shifted(&before, 10_000),
            10_000,
            &[Answered {
                track: THEM,
                seq: 1,
                start_ms: 9_000,
                end_ms: 20_000,
                text: "QA 今天我們討論頭髮，還有軟體發佈的時間。",
            }],
        );
        assert_eq!(
            texts(&merged),
            [
                (THEM, 0, "QA 今天我們討論頭髮，"),
                (THEM, 2_500, "還有軟體發佈的時間。"),
            ]
        );
    }

    #[test]
    fn marks_inside_words_and_numbers_do_not_end_a_phrase() {
        for (local, remote, expected) in [
            (
                ["qa It costs 1.5", "million dollars"],
                "QA It costs 1.5 million dollars.",
                ["QA It costs 1.5", "million dollars."],
            ),
            (
                ["qa I can't", "go"],
                "QA I can't go.",
                ["QA I can't", "go."],
            ),
            (
                ["qa I can’t", "go"],
                "QA I can’t go.",
                ["QA I can’t", "go."],
            ),
        ] {
            let (_, shared) = shares(&local, remote).unwrap();
            assert_eq!(shared, expected);
        }
    }

    #[test]
    fn a_boundary_never_splits_a_word_dropline_corrected_or_joined() {
        for (local, remote, expected) in [
            (
                ["qa I saw a cat", "yesterday"],
                "QA I saw a kitten yesterday.",
                ["QA I saw a kitten", "yesterday."],
            ),
            (
                ["qa see the pre", "view"],
                "QA see the preview",
                ["QA see the", "preview"],
            ),
            (
                ["qa say hello", "world now"],
                "QA say hello—world now",
                ["QA say hello—", "world now"],
            ),
            (
                ["qa un cafe", "noir"],
                "QA un café noir",
                ["QA un café", "noir"],
            ),
        ] {
            let (_, shared) = shares(&local, remote).unwrap();
            assert_eq!(shared, expected);
        }
    }

    #[test]
    fn echo_text_goes_with_the_local_entry_suppression_dropped() {
        // The microphone heard the speaker (echo) and then the user.
        let before = [
            entry(THEM, 1_000, 3_000, "qa 我們 下週 上線"),
            entry(YOU, 1_200, 3_200, "我們 下週 上線"),
            entry(YOU, 3_600, 5_000, "好 的 沒 問題"),
        ];
        let kept = shifted(&[before[0].clone(), before[2].clone()], 1_000);
        let merged = merge(
            &before,
            kept,
            1_000,
            &[Answered {
                track: YOU,
                seq: 1,
                start_ms: 0,
                end_ms: 6_000,
                text: "我們下週上線。好的，沒問題！",
            }],
        );
        assert_eq!(
            texts(&merged),
            [
                (THEM, 0, "qa 我們 下週 上線"),
                (YOU, 2_600, "好的，沒問題！")
            ]
        );
    }

    fn segment(seq: u32, start_ms: u64, end_ms: u64, text: &str) -> Answered<'_> {
        Answered {
            track: YOU,
            seq,
            start_ms,
            end_ms,
            text,
        }
    }

    #[test]
    fn echo_crossing_into_a_segment_takes_its_words_there_with_it() {
        // The echoed entry starts in the first segment; its middle is in the
        // second.
        let before = [
            entry(YOU, 1_000, 3_000, "qa 好 的 我 知道"),
            entry(YOU, 4_000, 8_000, "我們 下週 一起 上線"),
            entry(YOU, 8_500, 9_500, "沒 問題"),
        ];
        let kept = shifted(&[before[0].clone(), before[2].clone()], 1_000);
        let merged = merge(
            &before,
            kept,
            1_000,
            &[
                segment(1, 0, 5_000, "QA 好的我知道。我們下週"),
                segment(2, 5_000, 10_000, "一起上線。沒問題！"),
            ],
        );
        assert_eq!(
            texts(&merged),
            [(YOU, 0, "QA 好的我知道。"), (YOU, 7_500, "沒問題！")]
        );
    }

    #[test]
    fn an_entry_crossing_from_a_failed_segment_keeps_its_words_from_its_neighbour() {
        let before = [
            entry(YOU, 1_000, 3_000, "qa 好 的 我 知道"),
            entry(YOU, 4_000, 8_000, "我們 下週 一起 上線"),
        ];
        let merged = merge(
            &before,
            shifted(&before, 1_000),
            1_000,
            &[segment(1, 0, 5_000, "QA 好的我知道。我們下週")],
        );
        assert_eq!(
            texts(&merged),
            [
                (YOU, 0, "QA 好的我知道。"),
                (YOU, 3_000, "我們 下週 一起 上線")
            ]
        );
    }

    #[test]
    fn an_entry_spanning_two_segments_joins_its_words_from_both() {
        let before = [
            entry(YOU, 0, 3_500, "qa Good morning everyone"),
            entry(YOU, 4_000, 8_000, "we will deploy tomorrow morning"),
        ];
        let merged = merge(
            &before,
            shifted(&before, 0),
            0,
            &[
                segment(1, 0, 5_000, "QA Good morning everyone, we will"),
                segment(2, 5_000, 10_000, "deploy tomorrow morning."),
            ],
        );
        assert_eq!(
            texts(&merged),
            [
                (YOU, 0, "QA Good morning everyone,"),
                (YOU, 4_000, "we will deploy tomorrow morning."),
            ]
        );
        // Alone in a short segment, the entry aligns too weakly there and
        // keeps all of its local text.
        let before = [entry(
            YOU,
            4_000,
            8_000,
            "qa We will deploy tomorrow morning",
        )];
        let merged = merge(
            &before,
            shifted(&before, 0),
            0,
            &[
                segment(1, 0, 5_000, "QA We will"),
                segment(2, 5_000, 10_000, "deploy tomorrow morning."),
            ],
        );
        assert_eq!(
            texts(&merged),
            [(YOU, 4_000, "qa We will deploy tomorrow morning")]
        );
    }

    #[test]
    fn shares_join_with_a_space_only_between_words_of_scripts_written_with_spaces() {
        for (shares, expected) in [
            (["we will", "deploy."], "we will deploy."),
            (
                ["Nous aimons le café", "vraiment délicieux."],
                "Nous aimons le café vraiment délicieux.",
            ),
            (["OK,", "then"], "OK, then"),
            (["hello (", "world)"], "hello (world)"),
            (["done", "."], "done."),
            (["我們下週", "一起上線。"], "我們下週一起上線。"),
            (["上線。", "OK"], "上線。OK"),
            (["สวัสดี", "ครับ"], "สวัสดีครับ"),
            (["", "alone"], "alone"),
        ] {
            assert_eq!(joined(&shares.map(String::from)), expected);
        }
    }

    #[test]
    fn an_entry_reaching_into_a_failed_segment_keeps_its_local_text() {
        let before = [
            entry(YOU, 0, 3_000, "qa 我們 下週"),
            entry(YOU, 4_000, 7_000, "一起 上線 吧"),
        ];
        let merged = merge(
            &before,
            shifted(&before, 0),
            0,
            &[segment(1, 0, 6_000, "QA 我們下週。一起上線")],
        );
        assert_eq!(
            texts(&merged),
            [(YOU, 0, "QA 我們下週。"), (YOU, 4_000, "一起 上線 吧")]
        );
    }

    #[test]
    fn an_unaligned_segment_keeps_local_text_and_entries_outside_stay_local() {
        let before = [
            entry(THEM, 0, 2_000, "qa 完全 不同 的 內容"),
            entry(THEM, 9_000, 9_800, "段外 的 句子"),
        ];
        let kept = shifted(&before, 0);
        let merged = merge(
            &before,
            kept.clone(),
            0,
            &[Answered {
                track: THEM,
                seq: 1,
                start_ms: 0,
                end_ms: 5_000,
                text: "這是另一段毫無關係的話語呢",
            }],
        );
        assert_eq!(merged, kept);
    }

    #[test]
    fn dropline_hearing_nothing_keeps_local_speech() {
        let before = [entry(YOU, 0, 2_000, "qa 本機 有 聽到")];
        let kept = shifted(&before, 0);
        let answered = [Answered {
            track: YOU,
            seq: 1,
            start_ms: 0,
            end_ms: 5_000,
            text: "",
        }];
        assert_eq!(merge(&before, kept.clone(), 0, &answered), kept);
    }

    #[test]
    fn an_entry_belongs_to_the_segment_holding_its_middle() {
        let before = [
            entry(THEM, 0, 4_000, "qa 第一 段 的 話"),
            entry(THEM, 4_500, 6_500, "跨 段 的 句子"),
            entry(THEM, 7_000, 9_000, "第二 段 的 話"),
        ];
        let merged = merge(
            &before,
            shifted(&before, 0),
            0,
            &[
                Answered {
                    track: THEM,
                    seq: 1,
                    start_ms: 0,
                    end_ms: 5_000,
                    text: "QA 第一段的話。",
                },
                Answered {
                    track: THEM,
                    seq: 2,
                    start_ms: 5_000,
                    end_ms: 10_000,
                    text: "跨段的句子，第二段的話。",
                },
            ],
        );
        assert_eq!(
            texts(&merged),
            [
                (THEM, 0, "QA 第一段的話。"),
                (THEM, 4_500, "跨段的句子，"),
                (THEM, 7_000, "第二段的話。"),
            ]
        );
    }

    #[test]
    fn mixed_scripts_and_case_still_align() {
        let before = [
            entry(YOU, 0, 1_000, "qa 打開 api v2"),
            entry(YOU, 1_200, 2_000, "然後 部署"),
        ];
        let merged = merge(
            &before,
            shifted(&before, 0),
            0,
            &[Answered {
                track: YOU,
                seq: 1,
                start_ms: 0,
                end_ms: 3_000,
                text: "QA 打开 API v2，然后部署。",
            }],
        );
        assert_eq!(
            texts(&merged),
            [(YOU, 0, "QA 打开 API v2，"), (YOU, 1_200, "然后部署。")]
        );
    }

    #[test]
    fn the_ratio_counts_aligned_characters_over_the_longer_side() {
        let (ratio, parts) = shares(&["qa甲乙丙丁"], "qa甲乙丙丁戊己庚辛壬癸").unwrap();
        assert!((ratio - 0.5).abs() < 1e-9, "{ratio}");
        assert_eq!(parts, ["qa甲乙丙丁戊己庚辛壬癸"]);
        assert!(shares(&[], "qa").is_none());
        assert!(shares(&["。，"], "qa").is_none());
    }
}
