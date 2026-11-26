import XCTest
@testable import HEX

/// Three-language dictation's choice: the reading with the most confidence-weighted seconds,
/// a close Cantonese reading that writes Cantonese-only characters over Mandarin, and the
/// existing dictation whenever the lab is off or a model is missing.
@available(iOS 26.0, *)
final class ForkThreeLanguageTests: XCTestCase {
    private struct ProbeClip: Decodable {
        let clip: String
        let expected: String
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

    /// One reading whose words add up to `score` seconds of confident audio.
    private func lane(_ locale: String, _ text: String, score: TimeInterval) -> ForkThreeLanguage.Lane {
        ForkThreeLanguage.Lane(
            locale: locale,
            text: text,
            words: text.isEmpty ? [] : [TwoLanguageTimedWord(text: text, start: 0, end: score, confidence: 1)]
        )
    }

    /// Apple Speech's readings of 16 synthetic clips (Cantonese, Mandarin, and English, most
    /// Chinese ones with English words), recorded on macOS 27.2 by the DER-165 lane probe.
    func testPicksTheSpokenLanguageForEveryProbeClip() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "qa-three-language-lanes", withExtension: "json"))
        let clips = try JSONDecoder().decode([ProbeClip].self, from: Data(contentsOf: url))
        XCTAssertEqual(clips.count, 16)
        for clip in clips {
            let lanes = clip.lanes.map { lane in
                ForkThreeLanguage.Lane(
                    locale: lane.locale,
                    text: lane.text,
                    words: lane.words.map {
                        TwoLanguageTimedWord(text: $0.text, start: $0.start, end: $0.end, confidence: $0.confidence)
                    }
                )
            }
            let picked = try XCTUnwrap(ForkThreeLanguage.pick(lanes), clip.clip)
            XCTAssertEqual(picked.locale, clip.expected, clip.clip)
            XCTAssertEqual(picked.text, clip.lanes.first { $0.locale == clip.expected }?.text, clip.clip)
        }
    }

    func testScoreIsConfidenceTimesDuration() {
        let reading = ForkThreeLanguage.Lane(
            locale: "en-US",
            text: "hello world",
            words: [
                TwoLanguageTimedWord(text: "hello", start: 0, end: 0.5, confidence: 0.8),
                TwoLanguageTimedWord(text: " world", start: 0.5, end: 1.5, confidence: 0.5),
            ]
        )
        XCTAssertEqual(reading.score, 0.9, accuracy: 0.0001)
    }

    func testCantoneseCharactersWinACloseMandarinLead() {
        let cantonese = "呢個 project 嘅 deadline 係下個禮拜五"
        let picked = ForkThreeLanguage.pick([
            lane("en-US", "nego project", score: 0.5),
            lane("zh-HK", cantonese, score: 2.75),
            lane("zh-TW", "你個 project 個 deadline 是下個禮拜五", score: 3.0),
        ])
        XCTAssertEqual(picked?.locale, "zh-HK")
        XCTAssertEqual(picked?.text, cantonese)
    }

    func testMandarinKeepsItsLeadWithoutCantoneseCharactersOrBeyondTheMargin() {
        let withoutCharacters = ForkThreeLanguage.pick([
            lane("en-US", "", score: 0),
            lane("zh-HK", "今天天氣很好", score: 2.9),
            lane("zh-TW", "今天天氣很好", score: 3.0),
        ])
        XCTAssertEqual(withoutCharacters?.locale, "zh-TW")

        let beyondMargin = ForkThreeLanguage.pick([
            lane("en-US", "", score: 0),
            lane("zh-HK", "佢話今日好熱", score: 2.6),
            lane("zh-TW", "他說今天很熱", score: 3.0),
        ])
        XCTAssertEqual(beyondMargin?.locale, "zh-TW")
    }

    func testAnEnglishWinnerIsNeverHandedToCantonese() {
        let picked = ForkThreeLanguage.pick([
            lane("en-US", "I need to send the report", score: 3.0),
            lane("zh-HK", "我 need 嘅 report", score: 2.9),
            lane("zh-TW", "我 need 的 report", score: 2.95),
        ])
        XCTAssertEqual(picked?.locale, "en-US")
    }

    func testTiesKeepTheFirstReading() {
        let picked = ForkThreeLanguage.pick([
            lane("zh-HK", "早晨", score: 1.0),
            lane("en-US", "morning", score: 1.0),
            lane("zh-TW", "早安", score: 1.0),
        ])
        XCTAssertEqual(picked?.locale, "zh-HK")
    }

    func testReadingsWithoutTextAreNeverPicked() {
        XCTAssertNil(ForkThreeLanguage.pick([
            lane("en-US", "", score: 0),
            lane("zh-HK", "", score: 0),
            lane("zh-TW", "", score: 0),
        ]))
        let untimed = ForkThreeLanguage.Lane(locale: "zh-TW", text: "好", words: [])
        XCTAssertEqual(ForkThreeLanguage.pick([lane("en-US", "", score: 0), untimed])?.locale, "zh-TW")
    }

    func testCantoneseCharacters() {
        XCTAssertTrue(ForkThreeLanguage.writesCantonese("我而家喺 office，等陣 call 返你啦"))
        XCTAssertTrue(ForkThreeLanguage.writesCantonese("你食咗飯未呀？"))
        XCTAssertFalse(ForkThreeLanguage.writesCantonese("我現在在 office，等一下再 call 你"))
        XCTAssertFalse(ForkThreeLanguage.writesCantonese("I need to send the report"))
        XCTAssertFalse(ForkThreeLanguage.writesCantonese(""))
    }

    func testThreeLanguagesOnlyWithTheLabOnAndEveryModelInstalled() {
        let all = ["en-US": true, "zh-HK": true, "zh-TW": true]
        XCTAssertEqual(
            ForkThreeLanguage.plan(enabled: true, primary: "zh-HK", installed: all),
            ["zh-HK", "en-US", "zh-TW"]
        )
        XCTAssertEqual(
            ForkThreeLanguage.plan(enabled: true, primary: "en-US", installed: all),
            ["en-US", "zh-HK", "zh-TW"]
        )
        XCTAssertNil(ForkThreeLanguage.plan(enabled: false, primary: "zh-HK", installed: all))
    }

    /// Settings' "Cantonese" is `yue-CN`: the same three readings, Cantonese first.
    func testCantoneseInAnyRegionUsesTheThreeLanguages() {
        let all = ["en-US": true, "zh-HK": true, "zh-TW": true]
        XCTAssertEqual(
            ForkThreeLanguage.plan(enabled: true, primary: "yue-CN", installed: all),
            ["zh-HK", "en-US", "zh-TW"]
        )
        XCTAssertNil(ForkThreeLanguage.plan(
            enabled: true,
            primary: "yue-CN",
            installed: ["en-US": true, "zh-HK": false, "zh-TW": true]
        ))
        XCTAssertNil(ForkThreeLanguage.plan(enabled: false, primary: "yue-CN", installed: all))
    }

    /// Nil sends the dictation down the existing Two-language path, then single-language.
    func testAMissingModelOrAnotherLanguageKeepsTheExistingDictation() {
        XCTAssertNil(ForkThreeLanguage.plan(
            enabled: true,
            primary: "zh-HK",
            installed: ["en-US": true, "zh-HK": true, "zh-TW": false]
        ))
        XCTAssertNil(ForkThreeLanguage.plan(
            enabled: true,
            primary: "zh-HK",
            installed: ["en-US": true, "zh-HK": true]
        ))
        XCTAssertNil(ForkThreeLanguage.plan(
            enabled: true,
            primary: "ja-JP",
            installed: ["en-US": true, "zh-HK": true, "zh-TW": true]
        ))
        XCTAssertNil(ForkThreeLanguage.plan(
            enabled: true,
            primary: nil,
            installed: ["en-US": true, "zh-HK": true, "zh-TW": true]
        ))
    }

    func testReservationsKeepAllThreeModels() {
        let wanted = ["en-US", "zh-HK", "zh-TW"]
        let held = ForkThreeLanguage.reservationChanges(reserved: ["zh-TW", "en-US", "zh-HK"], wanted: wanted, limit: 3)
        XCTAssertEqual(held?.release, [])
        XCTAssertEqual(held?.reserve, [])

        let room = ForkThreeLanguage.reservationChanges(reserved: ["zh-HK"], wanted: wanted, limit: 5)
        XCTAssertEqual(room?.release, [])
        XCTAssertEqual(room?.reserve, ["en-US", "zh-TW"])

        let full = ForkThreeLanguage.reservationChanges(
            reserved: ["ja-JP", "zh-HK", "fr-FR", "en-US"],
            wanted: wanted,
            limit: 4
        )
        XCTAssertEqual(full?.release, ["ja-JP"])
        XCTAssertEqual(full?.reserve, ["zh-TW"])

        XCTAssertNil(ForkThreeLanguage.reservationChanges(reserved: ["zh-HK"], wanted: wanted, limit: 2))
    }
}
