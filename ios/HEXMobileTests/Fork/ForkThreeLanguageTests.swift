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

    /// The keyboard's live words start with the first reading that has text and move to the
    /// reading `pick` chooses only once it has kept choosing it for `LiveLeader.delay`.
    func testLiveWordsFollowTheReadingPickKeepsChoosing() {
        var leader = ForkThreeLanguage.LiveLeader()
        XCTAssertNil(leader.update([lane("zh-HK", "", score: 0), lane("zh-TW", "", score: 0)], at: 0))
        XCTAssertEqual(leader.update([lane("zh-HK", "我今", score: 0.4), lane("zh-TW", "", score: 0)], at: 0.3), "zh-HK")

        let mandarinAhead = [lane("zh-HK", "我今天下", score: 1.1), lane("zh-TW", "我今天下午", score: 1.5)]
        XCTAssertEqual(leader.update(mandarinAhead, at: 0.8), "zh-HK")
        XCTAssertEqual(leader.update(mandarinAhead, at: 1.2), "zh-HK")
        XCTAssertEqual(leader.update(mandarinAhead, at: 1.5), "zh-TW")
        XCTAssertEqual(leader.shown, "zh-TW")
    }

    func testLiveWordsDontFlipOnABriefLead() {
        var leader = ForkThreeLanguage.LiveLeader()
        XCTAssertEqual(leader.update([lane("zh-TW", "我們", score: 0.8), lane("zh-HK", "我", score: 0.5)], at: 0), "zh-TW")
        XCTAssertEqual(leader.update([lane("zh-TW", "我們今天", score: 1.0), lane("zh-HK", "我今日", score: 1.3)], at: 0.2), "zh-TW")
        XCTAssertEqual(leader.update([lane("zh-TW", "我們今天要", score: 1.6), lane("zh-HK", "我今日要", score: 1.4)], at: 0.5), "zh-TW")
        XCTAssertEqual(leader.update([lane("zh-TW", "我們今天要去", score: 1.7), lane("zh-HK", "我今日要去", score: 2.0)], at: 0.9), "zh-TW")
        XCTAssertEqual(leader.update([lane("zh-TW", "我們今天要去", score: 1.7), lane("zh-HK", "我今日要去", score: 2.0)], at: 1.5), "zh-HK")
    }

    func testLiveWordsMoveAtOnceWhenTheShownReadingIsGone() {
        var leader = ForkThreeLanguage.LiveLeader()
        XCTAssertEqual(leader.update([lane("zh-HK", "我", score: 0.5), lane("zh-TW", "", score: 0)], at: 0), "zh-HK")
        XCTAssertEqual(leader.update([lane("zh-TW", "我們", score: 0.6)], at: 0.1), "zh-TW")
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

    func testAChineseReadingWrittenInEnglishGivesWayToACloseEnglishReading() {
        let english = "Can you send it now?"
        let picked = ForkThreeLanguage.pick([
            lane("en-US", english, score: 2.0),
            lane("zh-HK", "Can you send it now", score: 2.45),
            lane("zh-TW", "Can you sent it now", score: 2.3),
        ])
        XCTAssertEqual(picked?.locale, "en-US")
        XCTAssertEqual(picked?.text, english)
    }

    func testAChineseReadingWithEnglishWordsKeepsItsLead() {
        let picked = ForkThreeLanguage.pick([
            lane("en-US", "Jacob feature Lily demo", score: 2.8),
            lane("zh-HK", "這個 feature 下禮拜 demo", score: 2.9),
            lane("zh-TW", "這個 feature 下禮拜要 demo", score: 3.0),
        ])
        XCTAssertEqual(picked?.locale, "zh-TW")
    }

    func testEnglishWinsOnlyWithinTheMarginAndOverHalfLatin() {
        let beyondMargin = ForkThreeLanguage.pick([
            lane("en-US", "Send it now", score: 2.0),
            lane("zh-TW", "Send it now", score: 2.5),
        ])
        XCTAssertEqual(beyondMargin?.locale, "zh-TW")

        let halfLatin = ForkThreeLanguage.pick([
            lane("en-US", "OK go", score: 2.0),
            lane("zh-TW", "OK 好", score: 2.2),
        ])
        XCTAssertEqual(halfLatin?.locale, "zh-TW")
    }

    func testCantoneseHandoffThenKeepsCantoneseOverEnglish() {
        let picked = ForkThreeLanguage.pick([
            lane("en-US", "Send me the file", score: 2.6),
            lane("zh-HK", "send 咗個 file 畀我", score: 2.8),
            lane("zh-TW", "send 了個 file 給我", score: 3.0),
        ])
        XCTAssertEqual(picked?.locale, "zh-HK")
    }

    func testLatinShareCountsEachEnglishWordOnce() {
        XCTAssertEqual(ForkThreeLanguage.latinShare("這個 Feature下禮拜"), 1.0 / 6, accuracy: 0.0001)
        XCTAssertEqual(ForkThreeLanguage.latinShare("I need to send the report."), 1)
        XCTAssertEqual(ForkThreeLanguage.latinShare("我 need 嘅 report"), 0.5)
        XCTAssertEqual(ForkThreeLanguage.latinShare("3 點 meeting"), 1.0 / 3, accuracy: 0.0001)
        XCTAssertEqual(ForkThreeLanguage.latinShare("Café，好"), 0.5)
        XCTAssertEqual(ForkThreeLanguage.latinShare("，。 "), 0)
        XCTAssertEqual(ForkThreeLanguage.latinShare(""), 0)
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

    /// The reason a skipped dictation logs and records, so a quiet fallback to the dictation
    /// language alone can be told apart on the iPhone.
    func testSkipReasonNamesWhyThreeLanguagesDontRun() {
        let all = ["en-US": true, "zh-HK": true, "zh-TW": true]
        XCTAssertNil(ForkThreeLanguage.skipReason(enabled: true, speechModule: true, primary: "zh-HK", installed: all))
        XCTAssertNil(ForkThreeLanguage.skipReason(enabled: true, speechModule: true, primary: "yue-CN", installed: all))
        XCTAssertEqual(
            ForkThreeLanguage.skipReason(enabled: false, speechModule: true, primary: "zh-HK", installed: all),
            "lab-off"
        )
        XCTAssertEqual(
            ForkThreeLanguage.skipReason(enabled: true, speechModule: false, primary: "zh-HK", installed: all),
            "dictation-module"
        )
        XCTAssertEqual(
            ForkThreeLanguage.skipReason(enabled: true, speechModule: true, primary: "ja-JP", installed: all),
            "language=ja-JP"
        )
        XCTAssertEqual(
            ForkThreeLanguage.skipReason(
                enabled: true,
                speechModule: true,
                primary: "zh-HK",
                installed: ["en-US": false, "zh-HK": true]
            ),
            "not-installed=zh-TW"
        )
        XCTAssertEqual(
            ForkThreeLanguage.skipReason(
                enabled: true,
                speechModule: true,
                primary: "en-US",
                installed: ["en-US": false, "zh-HK": true, "zh-TW": true]
            ),
            "not-installed=en-US"
        )
    }

    /// Derek's iPhone had both Chinese models and not English's: Cantonese and Mandarin are
    /// still told apart, and English is read only once its model is installed.
    func testAChineseDictationRunsWithoutTheEnglishModel() {
        let noEnglish = ["en-US": false, "zh-HK": true, "zh-TW": true]
        XCTAssertEqual(ForkThreeLanguage.plan(enabled: true, primary: "zh-HK", installed: noEnglish), ["zh-HK", "zh-TW"])
        XCTAssertEqual(ForkThreeLanguage.plan(enabled: true, primary: "yue-CN", installed: noEnglish), ["zh-HK", "zh-TW"])
        XCTAssertEqual(ForkThreeLanguage.plan(enabled: true, primary: "zh-TW", installed: noEnglish), ["zh-TW", "zh-HK"])
        XCTAssertNil(ForkThreeLanguage.skipReason(enabled: true, speechModule: true, primary: "zh-HK", installed: noEnglish))
        XCTAssertNil(ForkThreeLanguage.plan(enabled: true, primary: "en-US", installed: noEnglish))
    }

    func testRecordsKeepTheNewestFifty() throws {
        var records: [ForkThreeLanguage.Record] = []
        for index in 0..<60 {
            records = ForkThreeLanguage.Record.appending(
                ForkThreeLanguage.Record(event: "skipped", detail: "\(index)"),
                to: records
            )
        }
        XCTAssertEqual(records.count, 50)
        XCTAssertEqual(records.first?.detail, "10")
        XCTAssertEqual(records.last?.detail, "59")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let picked = ForkThreeLanguage.Record(
            event: "picked",
            detail: "zh-TW",
            scores: ["en-US": 0.4, "zh-HK": 3.1, "zh-TW": 3.6],
            seconds: 1.2,
            at: Date(timeIntervalSince1970: 1_795_736_287)
        )
        XCTAssertEqual(try decoder.decode(ForkThreeLanguage.Record.self, from: encoder.encode(picked)), picked)

        let older = Data("""
        [{"at":"2026-11-27T02:34:15Z","cantonese":false,"detail":"not-installed=en-US","event":"skipped","failed":[],"process":"keyboard","scores":{}}]
        """.utf8)
        let kept = try decoder.decode([ForkThreeLanguage.Record].self, from: older)
        XCTAssertEqual(kept.map(\.detail), ["not-installed=en-US"])
        XCTAssertNil(kept.first?.missing)
    }
}
