import XCTest
@testable import HEX

/// Three-language dictation's English words: a Chinese reading's Latin words respelled from the
/// en-US reading, Chinese characters never touched, and the chosen text unchanged without en-US.
@available(iOS 26.0, *)
final class ForkThreeLanguageEnglishWordsTests: XCTestCase {
    private struct ProbeClip: Decodable {
        let clip: String
        let picked: String
        let expected: String
        let replaced: Int
        let pure: Bool
        let english: [String]
        let lanes: [ProbeLane]
    }

    private struct ProbeLane: Decodable {
        let locale: String
        let text: String
        let words: [ProbeWord]
    }

    private struct ProbeWord: Decodable {
        let text: String
        let start: Double
        let end: Double
        let confidence: Double
    }

    private let dictionary: Set<String> = [
        "client", "branch", "merge", "prom", "prompt", "feature", "featured", "the", "fund",
        "pair", "copy", "plant", "github", "release",
    ]

    private func word(_ text: String, _ start: Double, _ end: Double, _ confidence: Double) -> TwoLanguageTimedWord {
        TwoLanguageTimedWord(text: text, start: start, end: end, confidence: confidence)
    }

    private func lane(_ locale: String, _ words: [TwoLanguageTimedWord]) -> ForkThreeLanguage.Lane {
        ForkThreeLanguage.Lane(
            locale: locale,
            text: words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines),
            words: words
        )
    }

    private func repair(
        _ chosen: ForkThreeLanguage.Lane?,
        _ lanes: [ForkThreeLanguage.Lane],
        vocabulary: [String] = []
    ) -> ForkThreeLanguageEnglishWords.Repaired {
        ForkThreeLanguageEnglishWords.repair(chosen, among: lanes, vocabulary: vocabulary, isEnglishWord: dictionary.contains)
    }

    /// Apple Speech's three readings of 60 synthetic qa- clips (HEX-32: Mandarin and Cantonese
    /// with English words, some with the English words spoken by an English voice, and Chinese
    /// alone), each with the text the offline evaluation measured and the words Hex's English typing
    /// model knows.
    private func probeClips() throws -> [(clip: ProbeClip, lanes: [ForkThreeLanguage.Lane])] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "qa-three-language-english", withExtension: "json"))
        let clips = try JSONDecoder().decode([ProbeClip].self, from: Data(contentsOf: url))
        XCTAssertEqual(clips.count, 60)
        return clips.map { clip in
            (clip, clip.lanes.map { lane in
                ForkThreeLanguage.Lane(
                    locale: lane.locale,
                    text: lane.text,
                    words: lane.words.map { word($0.text, $0.start, $0.end, $0.confidence) }
                )
            })
        }
    }

    func testRespellsEveryProbeClipAsMeasured() throws {
        var replaced = 0
        for (clip, lanes) in try probeClips() {
            let chosen = try XCTUnwrap(ForkThreeLanguage.pick(lanes), clip.clip)
            XCTAssertEqual(chosen.locale, clip.picked, clip.clip)
            let english = Set(clip.english)
            let repaired = ForkThreeLanguageEnglishWords.repair(chosen, among: lanes, vocabulary: [], isEnglishWord: english.contains)
            XCTAssertEqual(repaired.text, clip.expected, clip.clip)
            XCTAssertEqual(repaired.replaced, clip.replaced, clip.clip)
            if clip.pure || clip.replaced == 0 {
                XCTAssertEqual(repaired.text, chosen.text, clip.clip)
            }
            replaced += repaired.replaced
        }
        XCTAssertEqual(replaced, 45)
    }

    /// The same clips against Hex's English typing model, as dictation reads it.
    func testTypingModelRespellsEveryProbeClipAsMeasured() async throws {
        for (clip, lanes) in try probeClips() {
            let chosen = ForkThreeLanguage.pick(lanes)
            let repaired = await ForkThreeLanguageEnglishWords.repair(chosen, among: lanes, vocabulary: [])
            XCTAssertEqual(repaired, .init(text: clip.expected, replaced: clip.replaced), clip.clip)
        }
    }

    func testRespellsAMisspellingKeepingItsSpaceAndPunctuation() {
        let chinese = lane("zh-TW", [word("跟 ", 0.78, 1.08, 0.99), word("Clian，", 1.08, 1.80, 0.75), word("開", 1.80, 2.10, 0.85)])
        let english = lane("en-US", [word(", client,", 1.38, 1.92, 0.64)])
        XCTAssertEqual(repair(chinese, [english, chinese]), .init(text: "跟 client，開", replaced: 1))
    }

    func testSplitsAWordTwoEnglishWordsWereWrittenAs() {
        let chinese = lane("zh-TW", [word("這個 ", 0.9, 1.5, 0.99), word("branchmerge", 1.5, 2.46, 0.79), word("到", 2.46, 2.64, 0.94)])
        let english = lane("en-US", [word("Branch", 1.56, 1.98, 0.84), word(" merge.", 1.98, 2.40, 0.70)])
        XCTAssertEqual(repair(chinese, [english, chinese]).text, "這個 branch merge到")
    }

    /// en-US's "Hui" is the 會 before the Latin word, so only "release" replaces it.
    func testTakesOnlyTheEnglishWordsSpelledLikeTheLatinWord() {
        let chinese = lane("zh-TW", [word("才", 1.5, 1.8, 0.95), word("會", 1.8, 1.98, 0.94), word("elease", 1.98, 2.67, 0.57)])
        let english = lane("en-US", [word(" Hui", 1.92, 2.22, 0.86), word(" release.", 2.22, 2.67, 0.88)])
        XCTAssertEqual(repair(chinese, [english, chinese]), .init(text: "才會release", replaced: 1))
    }

    func testKeepsDigitsAndClosingQuotes() {
        let english = lane("en-US", [word("client", 0.0, 0.5, 0.8), word("client", 1.0, 1.5, 0.8)])
        let chinese = lane("zh-TW", [word("Clian2 ", 0.0, 0.5, 0.6), word("'Clian'", 1.0, 1.5, 0.6)])
        XCTAssertEqual(repair(chinese, [english, chinese]), .init(text: "Clian2 'client'", replaced: 1))
    }

    /// A real word is replaced only when it is the start of en-US's and en-US is at least as sure.
    func testCompletesATruncatedWordOnlyWhenEnglishIsAsSure() {
        let prom = lane("zh-HK", [word("個 ", 0.6, 1.0, 0.98), word("prom", 1.0, 1.7, 0.52)])
        XCTAssertEqual(repair(prom, [lane("en-US", [word("prompt", 1.02, 1.74, 0.65)]), prom]).text, "個 prompt")

        let feature = lane("zh-TW", [word("這個 ", 0.0, 0.3, 0.99), word("feature", 0.3, 1.0, 0.80)])
        XCTAssertEqual(repair(feature, [lane("en-US", [word("featured", 0.4, 0.9, 0.51)]), feature]).replaced, 0)
    }

    /// en-US hears Chinese as English ("的" as "the" at 0.82, "份" as "fund"): characters stay.
    func testNeverReplacesChineseCharacters() {
        let chinese = lane("zh-HK", [word("呢個", 0.0, 0.5, 1.0), word("的", 1.08, 1.32, 0.81), word("份", 4.26, 4.44, 0.998)])
        let english = lane("en-US", [word("the", 1.08, 1.32, 0.82), word("fund", 4.26, 4.50, 0.511)])
        XCTAssertEqual(repair(chinese, [english, chinese]), .init(text: chinese.text, replaced: 0))
    }

    func testKeepsAcronymsVocabularySureWordsAndWordsBothChineseReadingsWrote() {
        let english = lane("en-US", [word("pair", 0.0, 0.5, 0.9), word("copy", 1.0, 1.5, 0.9), word("client", 2.0, 2.5, 0.9), word("client", 3.0, 3.5, 0.9)])
        let chinese = lane("zh-TW", [word("PR ", 0.0, 0.5, 0.8), word("Capy ", 1.0, 1.5, 0.6), word("Clian ", 2.0, 2.5, 0.95), word("Clian", 3.0, 3.5, 0.6)])
        let other = lane("zh-HK", [word("clian", 3.0, 3.5, 0.7)])
        XCTAssertEqual(repair(chinese, [english, chinese]).text, "PR copy Clian client")
        XCTAssertEqual(repair(chinese, [english, other, chinese], vocabulary: ["Capy"]), .init(text: chinese.text, replaced: 0))
    }

    func testSpellsAVocabularyWordAsTheVocabularyDoes() {
        let chinese = lane("zh-TW", [word("上 ", 0.0, 0.4, 0.99), word("Gethub", 0.4, 1.2, 0.6)])
        let english = lane("en-US", [word("github", 0.5, 1.2, 0.7)])
        XCTAssertEqual(repair(chinese, [english, chinese], vocabulary: ["GitHub"]).text, "上 GitHub")
    }

    func testLeavesTheTextAloneWithoutAnEnglishReadingOrWhenEnglishWins() async {
        let chinese = lane("zh-TW", [word("跟 ", 0.78, 1.08, 0.99), word("Clian", 1.08, 1.80, 0.75)])
        let english = lane("en-US", [word("client", 1.38, 1.92, 0.64)])
        XCTAssertEqual(repair(chinese, [chinese]), .init(text: chinese.text, replaced: 0))
        XCTAssertEqual(repair(chinese, [lane("en-US", []), chinese]), .init(text: chinese.text, replaced: 0))
        XCTAssertEqual(repair(english, [english, chinese]), .init(text: english.text, replaced: 0))
        XCTAssertEqual(repair(nil, [english, chinese]), .init(text: "", replaced: 0))
        let unmatched = ForkThreeLanguage.Lane(locale: "zh-TW", text: "跟 Clian 開", words: chinese.words)
        XCTAssertEqual(repair(unmatched, [english, unmatched]), .init(text: "跟 Clian 開", replaced: 0))

        let alone = await ForkThreeLanguageEnglishWords.repair(chinese, among: [chinese], vocabulary: [])
        XCTAssertEqual(alone, .init(text: chinese.text, replaced: 0))
        let withEnglish = await ForkThreeLanguageEnglishWords.repair(chinese, among: [english, chinese], vocabulary: [])
        XCTAssertEqual(withEnglish, .init(text: "跟 client", replaced: 1))
    }

    func testRecordsHowManyWordsWereRespelled() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let picked = ForkThreeLanguage.Record(event: "picked", detail: "zh-HK", english: 2, at: Date(timeIntervalSince1970: 1_795_736_287))
        XCTAssertEqual(try decoder.decode(ForkThreeLanguage.Record.self, from: encoder.encode(picked)).english, 2)

        let older = Data("""
        [{"at":"2026-11-27T02:34:15Z","cantonese":false,"detail":"zh-TW","event":"picked","failed":[],"process":"keyboard","scores":{}}]
        """.utf8)
        XCTAssertNil(try decoder.decode([ForkThreeLanguage.Record].self, from: older).first?.english)
    }
}
