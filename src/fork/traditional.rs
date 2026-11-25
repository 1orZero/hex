//! Traditional Chinese for the local transcripts Annotate and meetings
//! keep. Every path converts with the Dropline client's [`text`], so
//! identifiers, the Cantonese particle `吓`, and Taiwan forms come out the
//! same everywhere.

use std::sync::LazyLock;

use regex::Regex;

use crate::transcription::transcript::Transcript;

pub(crate) use super::dropline::traditional as text;

/// Converts timed words as one run without separators, so a phrase a model
/// split across words (`头` + `发`) converts as the phrase (`頭髮`, not
/// `頭發`). A word's own leading and trailing spaces stay in place. Between
/// two Chinese words they are left out of the run; beside an identifier,
/// code, kana, or Hangul, which the conversion leaves alone as whole runs,
/// they still separate the words, as they do in the transcript's text. Each
/// word gets back as many characters as it had. When the conversion changes
/// the run's length, each word converts on its own.
pub(crate) fn words<'a>(words: impl IntoIterator<Item = &'a mut String>) {
    split_converted(words, text);
}

fn split_converted<'a>(
    words: impl IntoIterator<Item = &'a mut String>,
    convert: impl Fn(&str) -> String,
) {
    let mut words = words.into_iter().collect::<Vec<_>>();
    let spans = words
        .iter()
        .map(|word| {
            let start = word.len() - word.trim_start().len();
            (start, word.trim_end().len().max(start))
        })
        .collect::<Vec<_>>();
    let core = |index: usize| &words[index][spans[index].0..spans[index].1];
    let mut joined = String::new();
    let mut separators = Vec::with_capacity(words.len());
    for index in 0..words.len() {
        let separator = match index.checked_sub(1) {
            Some(previous) if !joins_phrase(core(previous), core(index)) => format!(
                "{}{}",
                &words[previous][spans[previous].1..],
                &words[index][..spans[index].0]
            ),
            _ => String::new(),
        };
        joined.push_str(&separator);
        joined.push_str(core(index));
        separators.push(separator.chars().count());
    }
    let converted = convert(&joined);
    if converted == joined {
        return;
    }
    if converted.chars().count() != joined.chars().count() {
        tracing::warn!(
            words = words.len(),
            "converted words one by one because the run's conversion changed its length"
        );
        for word in &mut words {
            **word = convert(word);
        }
        return;
    }
    let mut characters = converted.chars();
    for ((word, (start, end)), separator) in words.iter_mut().zip(spans).zip(separators) {
        for _ in 0..separator {
            characters.next();
        }
        let count = word[start..end].chars().count();
        let core = characters.by_ref().take(count).collect::<String>();
        word.replace_range(start..end, &core);
    }
}

/// Whether the space between two words is only the model's word boundary
/// inside Chinese: Han on both sides, and neither word holds an identifier's
/// `_`, a backtick, kana, or Hangul, whose runs could swallow the other word.
fn joins_phrase(previous: &str, next: &str) -> bool {
    static HAN: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^\p{sc=Han}$").unwrap());
    static KEPT: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r"[_\x60ー\p{sc=Hiragana}\p{sc=Katakana}\p{sc=Hangul}]").unwrap()
    });
    let han = |c: Option<char>| c.is_some_and(|c| HAN.is_match(c.encode_utf8(&mut [0; 4])));
    han(previous.chars().next_back())
        && han(next.chars().next())
        && !KEPT.is_match(previous)
        && !KEPT.is_match(next)
}

/// A meeting chunk's transcript: its text and each segment whole, its words
/// as one run. Times are unchanged.
pub(crate) fn transcript(mut transcript: Transcript) -> Transcript {
    transcript.text = text(&transcript.text);
    for segment in &mut transcript.segments {
        segment.text = text(&segment.text);
    }
    words(transcript.words.iter_mut().map(|word| &mut word.text));
    transcript
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::transcription::transcript::TranscriptSegment;

    fn converted(input: &[&str]) -> Vec<String> {
        let mut words = input
            .iter()
            .map(|word| (*word).to_owned())
            .collect::<Vec<_>>();
        super::words(words.iter_mut());
        words
    }

    #[test]
    fn a_phrase_split_across_words_converts_as_the_phrase() {
        assert_eq!(converted(&["qa-", "皇", "后"]), ["qa-", "皇", "后"]);
        assert_eq!(converted(&["qa-", "头", "发"]), ["qa-", "頭", "髮"]);
        assert_eq!(converted(&["qa-关", "系"]), ["qa-關", "係"]);
        assert_eq!(
            converted(&["qa-", "会", "后", "再", "说"]),
            ["qa-", "會", "後", "再", "說"]
        );
    }

    #[test]
    fn identifiers_mixed_scripts_and_wide_characters_keep_their_places() {
        assert_eq!(
            converted(&["qa-读取_v2", "请", "开", "门"]),
            ["qa-读取_v2", "請", "開", "門"]
        );
        assert_eq!(
            converted(&["qa-", "别", "干擾", "發", "展"]),
            ["qa-", "別", "干擾", "發", "展"]
        );
        assert_eq!(
            converted(&["qa-𠀀", "👩\u{200d}💻", "头", "发", "API"]),
            ["qa-𠀀", "👩\u{200d}💻", "頭", "髮", "API"]
        );
        assert_eq!(converted(&["qa-睇", "吓", "先"]), ["qa-睇", "吓", "先"]);
        assert!(converted(&[]).is_empty());
    }

    #[test]
    fn a_conversion_that_changes_the_length_converts_each_word_alone() {
        let mut words = vec!["qa-头".to_owned(), "发".to_owned()];
        split_converted(words.iter_mut(), |text| match text {
            "qa-头发" => "qa-頭髮!".to_owned(),
            word => word.replace('头', "頭").replace('发', "發"),
        });
        assert_eq!(words, ["qa-頭", "發"]);
    }

    #[test]
    fn spaces_still_separate_identifiers_code_kana_and_hangul() {
        assert_eq!(
            converted(&["qa-打开", " 文件_name"]),
            ["qa-打開", " 文件_name"]
        );
        assert_eq!(
            converted(&["qa-name_文件", " 打开"]),
            ["qa-name_文件", " 打開"]
        );
        assert_eq!(converted(&["qa-打开", " テスト"]), ["qa-打開", " テスト"]);
        assert_eq!(converted(&["qa-打开", " 한국"]), ["qa-打開", " 한국"]);
        assert_eq!(converted(&["qa-打开", " `头发`"]), ["qa-打開", " `头发`"]);
    }

    #[test]
    fn spaces_inside_words_stay_in_place_and_out_of_the_run() {
        assert_eq!(converted(&[" qa-头", " 发 ", " "]), [" qa-頭", " 髮 ", " "]);
        assert_eq!(
            converted(&[" qa", " 会", "后", "  "]),
            [" qa", " 會", "後", "  "]
        );
    }

    fn segment(start_ms: i64, end_ms: i64, text: &str) -> TranscriptSegment {
        TranscriptSegment {
            start_ms,
            end_ms,
            text: text.into(),
        }
    }

    #[test]
    fn a_meeting_transcript_converts_text_segments_and_words_and_keeps_times() {
        let converted = transcript(Transcript {
            text: "qa-头发，很好。软件 API_v2".into(),
            segments: vec![
                segment(0, 900, "qa-头发，很好。"),
                segment(900, 1500, "软件 API_v2"),
            ],
            words: vec![
                segment(0, 300, "qa-头"),
                segment(300, 500, "发，"),
                segment(500, 700, "很"),
                segment(700, 900, "好。"),
                segment(900, 1200, "软"),
                segment(1200, 1300, "件"),
                segment(1300, 1500, "API_v2"),
            ],
        });
        assert_eq!(converted.text, "qa-頭髮，很好。軟件 API_v2");
        assert_eq!(
            converted
                .segments
                .iter()
                .map(|segment| (segment.start_ms, segment.end_ms, segment.text.as_str()))
                .collect::<Vec<_>>(),
            [(0, 900, "qa-頭髮，很好。"), (900, 1500, "軟件 API_v2")]
        );
        assert_eq!(
            converted
                .words
                .iter()
                .map(|word| (word.start_ms, word.end_ms, word.text.as_str()))
                .collect::<Vec<_>>(),
            [
                (0, 300, "qa-頭"),
                (300, 500, "髮，"),
                (500, 700, "很"),
                (700, 900, "好。"),
                (900, 1200, "軟"),
                (1200, 1300, "件"),
                (1300, 1500, "API_v2"),
            ]
        );
    }

    #[test]
    fn words_joined_with_spaces_would_convert_character_by_character() {
        // The meeting joins words with spaces, and a space splits a phrase:
        // this is why words convert as one run before they are joined.
        assert_eq!(text("qa-头 发"), "qa-頭 發");
        assert_eq!(converted(&["qa-头", "发"]).join(" "), "qa-頭 髮");
    }
}
