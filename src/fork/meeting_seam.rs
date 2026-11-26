//! Meeting chunks that join at a hard cut. Upstream joins a segmented chunk at
//! the middle of the 2 s overlap by each segment's start, which assumes
//! segments are short. A segment that starts inside the overlap and runs past
//! it is dropped with all of its new speech, so a model that answers a whole
//! chunk as one segment (Qwen3-ASR) loses every chunk after a hard cut. This
//! keeps that segment from the seam on, without the speech the previous chunk
//! already ends with.

use crate::meeting::TranscriptEntry;

/// Units compared on either side of the seam: 2 s of overlap holds about a
/// dozen Chinese characters or six words.
const WINDOW: usize = 32;
/// Units a cut may have garbled at the end of the previous chunk and at the
/// start of the next.
const SLACK: usize = 2;

/// Moves the segment that straddles `seam` to start there, without the speech
/// the `previous` entries already end with, so the join keeps it. A segment
/// left with no new speech stays before the seam, and the join drops it as
/// before.
pub(crate) fn keep_across(
    incoming: &mut [TranscriptEntry],
    previous: &[TranscriptEntry],
    seam: u64,
) {
    let Some(entry) = incoming
        .iter_mut()
        .find(|entry| entry.start_ms < seam && entry.end_ms > seam)
    else {
        return;
    };
    let mut ending = String::new();
    for previous in previous.iter().rev() {
        ending = format!("{} {ending}", previous.text);
        if units(&ending).len() >= WINDOW {
            break;
        }
    }
    let text = strip_repeated_speech(&ending, &entry.text);
    if text.is_empty() {
        return;
    }
    entry.text = text.to_string();
    entry.start_ms = seam;
}

/// `next` without the speech it repeats from the end of `previous`: the
/// longest run of at least two units and three characters that ends
/// `previous` and starts `next`, each allowed up to `SLACK` garbled units at
/// the cut. Units the previous chunk heard after the run are repeated too, so
/// they go as well. Without such a run `next` is kept whole.
fn strip_repeated_speech<'a>(previous: &str, next: &'a str) -> &'a str {
    let before = units(previous);
    let before = &before[before.len().saturating_sub(WINDOW)..];
    let after = units(next);
    let window = &after[..after.len().min(WINDOW)];
    let mut best: Option<(usize, usize)> = None;
    for garbled_end in 0..=SLACK.min(before.len()) {
        let before = &before[..before.len() - garbled_end];
        for garbled_start in 0..=SLACK.min(window.len()) {
            let window = &window[garbled_start..];
            let run = (2..=before.len().min(window.len())).rev().find(|&count| {
                before[before.len() - count..]
                    .iter()
                    .map(|unit| &unit.text)
                    .eq(window[..count].iter().map(|unit| &unit.text))
                    && window[..count]
                        .iter()
                        .map(|unit| unit.text.chars().count())
                        .sum::<usize>()
                        >= 3
            });
            if let Some(count) = run
                && best.is_none_or(|(longest, _)| count > longest)
            {
                best = Some((count, garbled_start + count + garbled_end));
            }
        }
    }
    let Some((_, repeated)) = best else {
        return next.trim();
    };
    let cut = after[repeated.min(after.len()) - 1].end;
    next[cut..].trim_start_matches(|character: char| !character.is_alphanumeric())
}

struct Unit {
    text: String,
    end: usize,
}

/// Words, lowercased, with every letter of a script `compared_one_by_one` a
/// unit of its own; punctuation, marks, and spaces separate units and are not
/// compared.
fn units(text: &str) -> Vec<Unit> {
    let mut units = Vec::new();
    let mut word = String::new();
    let mut word_end = 0;
    for (index, character) in text.char_indices() {
        let end = index + character.len_utf8();
        if character.is_alphanumeric() && !compared_one_by_one(character) {
            word.extend(character.to_lowercase());
            word_end = end;
            continue;
        }
        if !word.is_empty() {
            units.push(Unit {
                text: std::mem::take(&mut word),
                end: word_end,
            });
        }
        if character.is_alphanumeric() {
            units.push(Unit {
                text: character.to_lowercase().collect(),
                end,
            });
        }
    }
    if !word.is_empty() {
        units.push(Unit {
            text: word,
            end: word_end,
        });
    }
    units
}

/// Scripts written without spaces between words (Thai, Lao, Tibetan, Burmese,
/// Khmer, Chinese, Japanese, full-width forms), and Hangul, whose words carry
/// their particles and so are often cut inside by a seam.
fn compared_one_by_one(character: char) -> bool {
    matches!(
        character,
        '\u{0E00}'..='\u{0FFF}'
            | '\u{1000}'..='\u{109F}'
            | '\u{1780}'..='\u{17FF}'
            | '\u{2E80}'..='\u{9FFF}'
            | '\u{AC00}'..='\u{D7AF}'
            | '\u{F900}'..='\u{FAFF}'
            | '\u{FF00}'..='\u{FFEF}'
            | '\u{20000}'..='\u{3FFFF}'
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::meeting::MeetingSource;

    fn entry(start_ms: u64, end_ms: u64, text: &str) -> TranscriptEntry {
        TranscriptEntry {
            source: MeetingSource::System,
            start_ms,
            end_ms,
            text: text.into(),
        }
    }

    #[test]
    fn chinese_speech_the_previous_chunk_ends_with_is_not_repeated() {
        assert_eq!(
            strip_repeated_speech(
                "qa-今天我們討論會議逐字稿的修正方式",
                "逐字稿的修正方式，需要保留後面的文字"
            ),
            "需要保留後面的文字"
        );
    }

    #[test]
    fn characters_garbled_at_either_cut_still_find_the_repeat() {
        // The previous chunk heard its last character wrong; the next chunk
        // lost its first one to the cut.
        assert_eq!(
            strip_repeated_speech(
                "qa-我們今天要把新版本的測試排程確定下萊",
                "程確定下來然後通知所有人"
            ),
            "然後通知所有人"
        );
    }

    #[test]
    fn words_repeated_across_the_seam_go_once() {
        assert_eq!(
            strip_repeated_speech(
                "qa we will review the quarterly numbers",
                "The quarterly numbers, and plan the launch."
            ),
            "and plan the launch."
        );
        assert_eq!(
            strip_repeated_speech("ｑａ ｓｈｉｐ ＩＴ ＮＯＷ", "Ｉｔ ｎｏｗ works"),
            "works"
        );
    }

    #[test]
    fn thai_written_without_spaces_is_not_repeated() {
        assert_eq!(
            strip_repeated_speech(
                "qa การประชุมวันนี้เราจะคุยเรื่องงบประมาณ",
                "เรื่องงบประมาณและแผนงานของปีหน้า"
            ),
            "และแผนงานของปีหน้า"
        );
    }

    #[test]
    fn without_a_clear_repeat_the_text_is_kept_whole() {
        assert_eq!(
            strip_repeated_speech("qa-會議開始", "  大家好，我們開始吧 "),
            "大家好，我們開始吧"
        );
        assert_eq!(
            strip_repeated_speech("Ship it.", "It works now."),
            "It works now.",
            "one repeated word is ambiguous"
        );
        assert_eq!(
            strip_repeated_speech("qa-我們今天", "我們明天再談"),
            "我們明天再談",
            "two repeated characters are ambiguous"
        );
    }

    #[test]
    fn only_the_segment_across_the_seam_moves() {
        let previous = entry(0, 10_000, "qa-今天我們討論會議逐字稿的修正方式");
        let mut incoming = [
            entry(8_000, 8_900, "修正方式"),
            entry(8_900, 12_000, "修正方式需要保留"),
            entry(12_000, 18_000, "後面的文字"),
        ];
        keep_across(&mut incoming, &[previous], 9_000);
        assert_eq!(
            incoming,
            [
                entry(8_000, 8_900, "修正方式"),
                entry(9_000, 12_000, "需要保留"),
                entry(12_000, 18_000, "後面的文字"),
            ]
        );
    }

    #[test]
    fn a_segment_with_nothing_new_stays_before_the_seam() {
        let previous = entry(0, 10_000, "qa-今天我們討論會議逐字稿的修正方式");
        let mut incoming = [entry(8_000, 9_500, "逐字稿的修正方式")];
        keep_across(&mut incoming, &[previous], 9_000);
        assert_eq!(incoming, [entry(8_000, 9_500, "逐字稿的修正方式")]);
    }

    #[test]
    fn speech_split_over_several_previous_entries_is_not_repeated() {
        let previous = [
            entry(0, 8_000, "qa-我們先看上週的數字"),
            entry(8_000, 8_500, "測試結果"),
            entry(8_500, 10_000, "很好"),
        ];
        let mut incoming = [entry(8_000, 18_000, "測試結果很好，我們繼續討論")];
        keep_across(&mut incoming, &previous, 9_000);
        assert_eq!(incoming, [entry(9_000, 18_000, "我們繼續討論")]);
    }
}
