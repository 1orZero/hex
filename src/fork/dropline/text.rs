pub(super) fn traditional(text: &str) -> String {
    use objc2_foundation::{NSString, ns_string};
    use regex::{Captures, Regex};
    use std::sync::LazyLock;

    static RUNS: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(
            r"(?x)
            \x60{3} [\s\S]*? \x60{3} | \x60 [^\x60\r\n]+ \x60
            | [A-Za-z_][A-Za-z0-9_]* _ \p{sc=Han}+
            | \p{sc=Han}+ _ [A-Za-z0-9_]+
            | [A-Za-z0-9_]+
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
            吓人哋 | [驚惊恐威恫別别被] (吓)
            | (吓) (?: [得了到着著住破死醒坏壞哭跑傻出退走倒瘋疯人唬]
                | 一(?:下|大?跳) | [我你他她](?:們|们)?一大?跳 )
            | 吓 | 了解 | 明了 | 杰倫 | 斗笠 | [烟煙]斗 | 启 | 钵 | 钩
        ",
        )
        .unwrap()
    });

    if text.is_ascii() {
        return text.to_owned();
    }
    objc2::rc::autoreleasepool(|_| {
        let convert = |part: &str| {
            if part.is_empty() {
                return String::new();
            }
            let forward = |s: &str| {
                NSString::from_str(s)
                    .stringByApplyingTransform_reverse(ns_string!("Hans-Hant"), false)
                    .map(|s| s.to_string())
            };
            if let Some(simple) = NSString::from_str(part)
                .stringByApplyingTransform_reverse(ns_string!("Hant-Hans"), false)
                .map(|s| s.to_string())
                .filter(|s| s != part)
                && let Some(contextual) = forward(&simple)
                && part.chars().count() == simple.chars().count()
                && simple.chars().count() == contextual.chars().count()
            {
                return part
                    .chars()
                    .zip(simple.chars())
                    .zip(contextual.chars())
                    .map(|((a, s), t)| if a != s { a } else { t })
                    .collect();
            }
            forward(part).unwrap_or_else(|| part.to_owned())
        };
        RUNS.replace_all(text, |m: &Captures| {
            let Some(han) = m.get(1) else {
                return m[0].to_owned();
            };
            let han = han.as_str();
            let mut start = 0;
            let mut output = String::new();
            for m in FORMS.captures_iter(han) {
                let fear = m.get(1).or_else(|| m.get(2));
                let form = fear.unwrap_or_else(|| m.get(0).unwrap());
                output.push_str(&convert(&han[start..form.start()]));
                output.push_str(match form.as_str() {
                    "吓" if fear.is_some() => "嚇",
                    "启" => "啟",
                    "钵" => "缽",
                    "钩" => "鉤",
                    "烟斗" => "煙斗",
                    other => other,
                });
                start = form.end();
            }
            output.push_str(&convert(&han[start..]));
            output
        })
        .into_owned()
    })
}
