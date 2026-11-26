//! Puts Dropline's text on the local transcript's times (ADR-0003, 0008).
//! Dropline returns no times, so each successful segment's text is aligned
//! character by character with the local entries of the same track inside
//! it, as both were before echo suppression. Each local entry's boundary
//! maps into Dropline's text and moves to nearby punctuation; an entry
//! suppression kept gets its share of Dropline's text, and the share of an
//! entry it judged echo is dropped with it. A segment whose alignment is too
//! weak keeps its local text.

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
    // An entry that crosses into a segment but gets no Dropline text of its
    // own (judged echo, or its segment failed or aligned too weakly) is
    // aligned there too, so Dropline's words for it are dropped with it
    // instead of going to a neighbour.
    let mut texted = vec![false; before.len()];
    for (index, _) in owned_shares(&before, answered, &|_| false, false) {
        texted[index] = kept_at[index].is_some();
    }
    let mut texts: Vec<Option<String>> = vec![None; kept.len()];
    for (index, share) in owned_shares(&before, answered, &|index| !texted[index], true) {
        if let Some(kept) = kept_at[index] {
            texts[kept] = Some(share);
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

/// Each entry of `before`'s share of Dropline's text in the answered
/// segment holding its middle, when that segment aligns well enough.
/// Entries `crossing` accepts also take part in a segment they only cross
/// into, and their share there is dropped.
fn owned_shares(
    before: &[TranscriptEntry],
    answered: &[Answered<'_>],
    crossing: &dyn Fn(usize) -> bool,
    log: bool,
) -> Vec<(usize, String)> {
    let mut owned = Vec::new();
    for segment in answered {
        let inside = before
            .iter()
            .enumerate()
            .filter(|(_, entry)| entry.source == segment.track)
            .filter_map(|(index, entry)| {
                let middle = (entry.start_ms + entry.end_ms) / 2;
                let owns = segment.start_ms <= middle && middle < segment.end_ms;
                let crosses = entry.start_ms < segment.end_ms && segment.start_ms < entry.end_ms;
                (owns || crosses && crossing(index)).then_some((index, entry.text.as_str(), owns))
            })
            .collect::<Vec<_>>();
        let local = inside.iter().map(|(_, text, _)| *text).collect::<Vec<_>>();
        if segment.text.trim().is_empty() {
            if log && !local.is_empty() {
                tracing::info!(
                    track = ?segment.track,
                    seq = segment.seq,
                    entries = local.len(),
                    "Dropline heard no speech where the local model did; keeping local text"
                );
            }
            continue;
        }
        let Some((ratio, shares)) = shares(&local, segment.text) else {
            if log {
                tracing::info!(
                    track = ?segment.track,
                    seq = segment.seq,
                    entries = local.len(),
                    "could not align a Dropline meeting segment; keeping local text"
                );
            }
            continue;
        };
        if log {
            tracing::info!(
                track = ?segment.track,
                seq = segment.seq,
                ratio = (ratio * 1000.0).round() / 1000.0,
                "aligned a Dropline meeting segment"
            );
        }
        if ratio < THRESHOLD {
            continue;
        }
        owned.extend(
            inside
                .iter()
                .zip(shares)
                .filter(|((_, _, owns), _)| *owns)
                .map(|((index, _, _), share)| (*index, share)),
        );
    }
    owned
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
        let cut = near_punctuation(remote, &remote_chars, at, next).max(previous);
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

/// Punctuation that ends a phrase, unlike a mark inside a word or number
/// such as `1.5` or `can't`, which sits between two ASCII letters or digits.
fn separates(text: &str, index: usize, character: char) -> bool {
    let inside_word = text[..index]
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
