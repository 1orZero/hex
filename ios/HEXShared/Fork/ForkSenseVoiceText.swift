import Foundation

/// SenseVoice writes Chinese in Simplified characters. Its text becomes Traditional Chinese
/// through the same Apple transform Dropline's does (`ForkDroplineClient.traditionalChinese`,
/// Taiwan forms), and a Cantonese reading then takes Hong Kong forms (`hongKong`). Another
/// reading (English with a Chinese word in it) follows the dictation language's region.
nonisolated enum ForkSenseVoiceText {
    static func written(_ text: String, language: String, dictationLanguage: String?) -> String {
        let taiwan = fixAmbiguous(ForkDroplineClient.traditionalChinese(tidySpaces(text)))
        return usesHongKong(language: language, dictationLanguage: dictationLanguage) ? hongKong(taiwan) : taiwan
    }

    static func usesHongKong(language: String, dictationLanguage: String?) -> Bool {
        switch language {
        case "yue": return true
        case "zh": return false
        default:
            guard let dictationLanguage else { return false }
            let locale = Locale(identifier: dictationLanguage)
            return locale.language.languageCode?.identifier == "yue" || ["HK", "MO"].contains(locale.region?.identifier)
        }
    }

    /// SenseVoice puts a space between an English word and the full-width punctuation after it.
    static func tidySpaces(_ text: String) -> String {
        text.replacing(/\s+([，。！？、；：」』）])/, with: { String($0.1) })
            .replacing(/([「『（])\s+/, with: { String($0.1) })
    }

    /// Apple's transform keeps 松 and 面 where the word needs 鬆 (loose) and 麵 (noodles).
    static func fixAmbiguous(_ text: String) -> String {
        text.replacing(/([太很好放輕寬蓬咁幾])松/, with: { $0.1 + "鬆" })
            .replacing(/松(?=[了開掉綁懈弛散脫軟啲咗])/, with: "鬆")
            .replacing(/([吃食煮炒湯碗拌撈泡]|方便|牛肉|雞蛋|烏冬|意大利|義大利)面/, with: { $0.1 + "麵" })
    }

    /// Hong Kong forms of a Cantonese reading already in Taiwan forms: 係 for SenseVoice's
    /// 系 (“is”, outside words such as 系統), 裏, 啓, 衞, and 着 outside words such as 著名.
    static func hongKong(_ text: String) -> String {
        text.replacing(/(^|[^體派星科直語陽河文學理工商醫法])系(?![統列數譜])/, with: { $0.1 + "係" })
            .replacing(/(^|[^顯名巨編土原論專譯遺新拙大合昭卓])著(?![名作者述稱])/, with: { $0.1 + "着" })
            .replacing("裡", with: "裏")
            .replacing("啟", with: "啓")
            .replacing("衛", with: "衞")
    }
}
