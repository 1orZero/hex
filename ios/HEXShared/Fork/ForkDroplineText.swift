import Foundation

extension ForkDroplineClient {
    static func traditionalChinese(_ text: String) -> String {
        let runs = #/
            \x60 [\p{XID_Start}_] \p{XID_Continue}* \x60
            | \p{sc=Han}* [\p{sc=Hiragana}\p{sc=Katakana}\p{sc=Hangul}]
              [\p{sc=Han}\p{sc=Hiragana}\p{sc=Katakana}\p{sc=Hangul}ー]*
            | (\p{sc=Han}+)
            /#.matchingSemantics(.unicodeScalar)
        let forms = #/
            [睇試试聽听諗谂望行問问想等食講讲搵玩坐傾倾幫帮用做咩咪] (吓)
            | ^吓+$ | 吓[呀喎啦嘛啫嘅㗎先]
            | 了解 | 明了 | 斗笠 | [烟煙]斗 | 启 | 钵 | 钩
            /#.matchingSemantics(.unicodeScalar)
        let taiwan = Locale(identifier: "zh_Hant_TW").exemplarCharacterSet
        func convert(_ part: Substring) -> String {
            guard !part.isEmpty else { return "" }
            let string = String(part)
            return string.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? string
        }
        return text.replacing(runs) { match in
            guard let han = match.1 else { return String(match.0) }
            var output = ""
            var start = han.startIndex
            for match in han.matches(of: forms) {
                let form = match.1 ?? match.0
                output += convert(han[start..<form.startIndex])
                switch form {
                case "启": output += "啟"
                case "钵": output += "缽"
                case "钩": output += "鉤"
                case "烟斗": output += "煙斗"
                default: output += form
                }
                start = form.endIndex
            }
            output += convert(han[start...])
            guard output != han, let taiwan,
                  let simplified = String(han).applyingTransform(StringTransform("Hant-Hans"), reverse: false),
                  simplified != han else { return output }
            let original = Array(han.unicodeScalars)
            let simple = Array(simplified.unicodeScalars)
            guard original.count == simple.count, original.count == output.unicodeScalars.count else { return output }
            let alreadyTraditional = zip(original, output.unicodeScalars).allSatisfy { $0 == $1 || taiwan.contains($0) }
            var result = ""
            for (i, b) in output.unicodeScalars.enumerated() {
                let a = original[i]
                let nextToTraditional = (i > 0 && original[i - 1] != simple[i - 1])
                    || (i + 1 < original.count && original[i + 1] != simple[i + 1])
                let keep = a != b && (alreadyTraditional || nextToTraditional) && taiwan.contains(a)
                    && convert(Substring(String(a))) == String(b)
                result.unicodeScalars.append(keep ? a : b)
            }
            return result
        }
    }
}
