pub(super) fn traditional(text: &str) -> String {
    use objc2_foundation::{NSLocale, NSString, ns_string};
    use regex::{Captures, Regex};
    use std::sync::LazyLock;

    static RUNS: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(
            r"(?x)
            \x60 [\p{XID_Start}_] \p{XID_Continue}* \x60
            | \p{sc=Han}* [\p{sc=Hiragana}\p{sc=Katakana}\p{sc=Hangul}]
              [\p{sc=Han}\p{sc=Hiragana}\p{sc=Katakana}\p{sc=Hangul}ー]*
            | (\p{sc=Han}+)
        ",
        )
        .unwrap()
    });
    static FORMS: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(
            r"(?x)
            [睇試试聽听諗谂望行問问想等食講讲搵玩坐傾倾幫帮用做咩咪] (吓)
            | ^吓+$ | 吓[呀喎啦嘛啫嘅㗎先]
            | 了解 | 明了 | 斗笠 | [烟煙]斗 | 启 | 钵 | 钩
        ",
        )
        .unwrap()
    });

    if text.is_ascii() {
        return text.to_owned();
    }
    objc2::rc::autoreleasepool(|_| {
        let taiwan =
            NSLocale::localeWithLocaleIdentifier(ns_string!("zh_Hant_TW")).exemplarCharacterSet();
        let convert = |part: &str| {
            if part.is_empty() {
                return String::new();
            }
            NSString::from_str(part)
                .stringByApplyingTransform_reverse(ns_string!("Hans-Hant"), false)
                .map_or_else(|| part.to_owned(), |s| s.to_string())
        };
        RUNS.replace_all(text, |m: &Captures| {
            let Some(han) = m.get(1) else {
                return m[0].to_owned();
            };
            let han = han.as_str();
            let mut start = 0;
            let mut output = String::new();
            for m in FORMS.captures_iter(han) {
                let form = m.get(1).unwrap_or_else(|| m.get(0).unwrap());
                output.push_str(&convert(&han[start..form.start()]));
                output.push_str(match form.as_str() {
                    "启" => "啟",
                    "钵" => "缽",
                    "钩" => "鉤",
                    "烟斗" => "煙斗",
                    other => other,
                });
                start = form.end();
            }
            output.push_str(&convert(&han[start..]));
            if output == han {
                return output;
            }
            let Some(simplified) = NSString::from_str(han)
                .stringByApplyingTransform_reverse(ns_string!("Hant-Hans"), false)
                .map(|s| s.to_string())
                .filter(|s| s != han)
            else {
                return output;
            };
            let original: Vec<_> = han.chars().collect();
            let simplified: Vec<_> = simplified.chars().collect();
            if simplified.len() != original.len() || output.chars().count() != original.len() {
                return output;
            }
            let already_traditional = original
                .iter()
                .copied()
                .zip(output.chars())
                .all(|(a, b)| a == b || taiwan.longCharacterIsMember(a as u32));
            output
                .chars()
                .enumerate()
                .map(|(i, b)| {
                    let a = original[i];
                    let next_to_traditional = (i > 0 && original[i - 1] != simplified[i - 1])
                        || (i + 1 < original.len() && original[i + 1] != simplified[i + 1]);
                    if a != b
                        && (already_traditional || next_to_traditional)
                        && taiwan.longCharacterIsMember(a as u32)
                        && convert(a.encode_utf8(&mut [0; 4])) == b.to_string()
                    {
                        a
                    } else {
                        b
                    }
                })
                .collect()
        })
        .into_owned()
    })
}
