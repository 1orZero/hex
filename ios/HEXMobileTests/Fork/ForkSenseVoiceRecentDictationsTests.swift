import XCTest
@testable import HEX

/// Labs › SenseVoice（中文） (fork): the card's recent dictations, read from `fork-sensevoice.json`.
final class ForkSenseVoiceRecentDictationsTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return calendar
    }

    private let locale = Locale(identifier: "en_US")
    /// 2026-11-28 12:00 in Taipei.
    private let now = Date(timeIntervalSince1970: 1_795_838_400)

    func testListsTheNewestTenDictationsOnlyNewestFirst() throws {
        var records: [ForkSenseVoice.Record] = [
            record("downloaded", "SenseVoice-Small", minutesAgo: 200, process: "app"),
            record("loaded", "SenseVoice-Small", minutesAgo: 190, process: "keyboard"),
            record("keyboard", "too-small 120", minutesAgo: 185, process: "keyboard"),
            record("skipped", "language=ja-JP", minutesAgo: 184, process: "app"),
        ]
        for index in 0 ..< 12 {
            records.append(record("live", "rounds=3", minutesAgo: 180 - index * 10, process: "keyboard"))
            records.append(index.isMultiple(of: 2)
                ? record("transcribed", "SenseVoice-Small", minutesAgo: 179 - index * 10, process: "keyboard")
                : record("fallback", "memory", minutesAgo: 179 - index * 10, process: "app"))
        }
        records.append(record("released", "memory warning", minutesAgo: 1, process: "keyboard"))

        let rows = ForkSenseVoiceRecentDictations.rows(try encoded(records), now: now, calendar: calendar, locale: locale)

        XCTAssertEqual(rows.map(\.time), ["10:51", "10:41", "10:31", "10:21", "10:11", "10:01", "09:51", "09:41", "09:31", "09:21"])
        XCTAssertEqual(rows.first?.process, "App")
        XCTAssertEqual(rows.first?.engine, "Apple · Not enough memory")
        XCTAssertEqual(rows[1].process, "Keyboard")
        XCTAssertEqual(rows[1].engine, "SenseVoice")
    }

    func testDictationsBeforeTodayShowTheirDate() throws {
        let rows = ForkSenseVoiceRecentDictations.rows(
            try encoded([record("transcribed", "SenseVoice-Small", minutesAgo: 13 * 60, process: "app")]),
            now: now, calendar: calendar, locale: locale
        )
        XCTAssertEqual(rows.map(\.time), ["Nov 27 23:00"])
    }

    func testEachFallbackNamesItsReason() throws {
        let reasons = ["memory", "loading", "not-loaded", "load-failed", "too-long", "english", "sparse", "empty", "error NSOSStatusErrorDomain -1", "something-new"]
        let records = reasons.enumerated().map { index, reason in
            record("fallback", reason, minutesAgo: index + 1, process: "keyboard")
        }
        let rows = ForkSenseVoiceRecentDictations.rows(try encoded(records), now: now, calendar: calendar, locale: locale)
        XCTAssertEqual(rows.map(\.engine), [
            "Apple · Not enough memory", "Apple · Model loading", "Apple · Model not loaded", "Apple · Load failed",
            "Apple · Recording too long", "Apple · Heard as English", "Apple · Too few words", "Apple · No words heard",
            "Apple · Error", "Apple",
        ])
    }

    func testAMissingOversizedOrBrokenLogListsNothing() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("qa-recent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        XCTAssertNil(ForkSenseVoiceRecentDictations.read(folder.appendingPathComponent("missing.json")))

        let oversized = folder.appendingPathComponent("oversized.json")
        try Data(repeating: 0x20, count: ForkSenseVoiceRecentDictations.byteLimit + 1).write(to: oversized)
        XCTAssertNil(ForkSenseVoiceRecentDictations.read(oversized))

        let broken = folder.appendingPathComponent("broken.json")
        let whole = try encoded([record("transcribed", "SenseVoice-Small", minutesAgo: 1, process: "app")])
        try whole.prefix(whole.count / 2).write(to: broken)
        XCTAssertEqual(ForkSenseVoiceRecentDictations.rows(ForkSenseVoiceRecentDictations.read(broken), now: now), [])
    }

    private func record(_ event: String, _ detail: String, minutesAgo: Int, process: String) -> ForkSenseVoice.Record {
        var record = ForkSenseVoice.Record(event: event, detail: detail, language: "qa-zh", audio: 4.2)
        record.at = now.addingTimeInterval(-Double(minutesAgo) * 60)
        record.process = process
        return record
    }

    /// As `ForkSenseVoice.Record.append` writes the log.
    private func encoded(_ records: [ForkSenseVoice.Record]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(records)
    }
}
