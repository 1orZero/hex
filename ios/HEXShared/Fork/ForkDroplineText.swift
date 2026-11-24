import Foundation

extension ForkDroplineClient {
    static func traditionalChinese(_ text: String) -> String {
        let runs = #/
            \x60{3} [\s\S]*? \x60{3} | \x60 [^\x60\r\n]+ \x60
            | (?: [A-Za-z0-9]+ | \p{sc=Han}[\p{sc=Han}0-9]* )?
              (?: _+ (?: [A-Za-z0-9]+ | \p{sc=Han}[\p{sc=Han}0-9]* ) )+
            | [A-Za-z0-9_]+
            | \p{sc=Han}* [\p{sc=Hiragana}\p{sc=Katakana}\p{sc=Hangul}]
              [\p{sc=Han}\p{sc=Hiragana}\p{sc=Katakana}\p{sc=Hangul}ー]*
            | (\p{sc=Han}+)
            /#.matchingSemantics(.unicodeScalar)
        let forms = #/
            ^[吓嚇]+$ | 吓[呀喎啦嘛啫嘅㗎先] | 吓人哋
            | (?: ^ | [驚惊恐威恫別别被受給给好很真太] | [我你他她][們们]? | 不要 ) (吓)
            | (吓) (?: [得了到着著住破死醒坏壞哭跑傻出退走倒瘋疯唬暈晕]
                | 人(?:的|了|一大?跳) | 一(?:下|大?跳) | [我你他她][們们]?一大?跳 )
            | 吓 | 了解 | 明了 | 杰倫 | 斗笠 | [烟煙]斗 | 启 | 钵 | 钩
            /#.matchingSemantics(.unicodeScalar)
        func convert(_ part: Substring) -> String {
            guard !part.isEmpty else { return "" }
            let text = String(part)
            let forward = StringTransform("Hans-Hant")
            if let simple = text.applyingTransform(StringTransform("Hant-Hans"), reverse: false), simple != text,
               let contextual = simple.applyingTransform(forward, reverse: false),
               text.unicodeScalars.count == simple.unicodeScalars.count,
               simple.unicodeScalars.count == contextual.unicodeScalars.count {
                var result = ""
                for ((a, s), t) in zip(zip(text.unicodeScalars, simple.unicodeScalars), contextual.unicodeScalars) {
                    result.unicodeScalars.append(a != s ? a : t)
                }
                return result
            }
            return text.applyingTransform(forward, reverse: false) ?? text
        }
        return text.replacing(runs) { match in
            guard let han = match.1 else { return String(match.0) }
            var output = ""
            var start = han.startIndex
            for match in han.matches(of: forms) {
                let fear = match.1 ?? match.2
                let form = fear ?? match.0
                output += convert(han[start..<form.startIndex])
                switch form {
                case "吓" where fear != nil: output += "嚇"
                case "启": output += "啟"
                case "钵": output += "缽"
                case "钩": output += "鉤"
                case "烟斗": output += "煙斗"
                default: output += form
                }
                start = form.endIndex
            }
            output += convert(han[start...])
            return output
        }
    }
}
