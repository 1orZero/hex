import XCTest
@testable import HEX

/// Labs › SenseVoice（中文） (fork): the features its encoder reads, the text it writes, where its
/// audio is cut, the keyboard's live rounds, and which dictations it reads at all.
@MainActor
final class ForkSenseVoiceTests: XCTestCase {
    // MARK: - Features

    /// The values FluidAudio's `SenseVoicePreprocessor` model gives the same 1 s tone on the CPU,
    /// where it still answers the same each time (under about 4.5 s of audio).
    func testFeaturesMatchFluidAudiosPreprocessor() {
        let features = ForkSenseVoiceFeatures.rows(tone(seconds: 1))
        XCTAssertEqual(features.count, 17)
        XCTAssertEqual(features.values.count, 17 * ForkSenseVoiceFeatures.width)
        let expected: [(row: Int, column: Int, value: Float)] = [
            (0, 0, 0.5040665), (0, 79, 0.11086247), (3, 10, -0.17553195), (3, 40, 0.008307283),
            (3, 280, -0.05645465), (3, 559, -0.62052023), (16, 300, -0.94386303),
        ]
        for (row, column, value) in expected {
            XCTAssertEqual(features.values[row * ForkSenseVoiceFeatures.width + column], value, accuracy: 1e-3, "row \(row), column \(column)")
        }
    }

    func testFeatureRowsMatchTheModelsCountsForEachLength() {
        XCTAssertEqual(ForkSenseVoiceFeatures.rows([Float](repeating: 0, count: 3_200)).count, 4)
        XCTAssertEqual(ForkSenseVoiceFeatures.rows([Float](repeating: 0, count: 100_000)).count, 105)
        XCTAssertEqual(ForkSenseVoiceFeatures.rows([Float](repeating: 0, count: 480_000)).count, 501)
    }

    // MARK: - Text

    func testCantoneseTakesHongKongFormsAndMandarinTaiwanForms() {
        XCTAssertEqual(ForkSenseVoiceText.written("我系香港人，呢个系统好难用。", language: "yue", dictationLanguage: "zh-HK"), "我係香港人，呢個系統好難用。")
        XCTAssertEqual(ForkSenseVoiceText.written("这里的系统很好用。", language: "zh", dictationLanguage: "zh-HK"), "這裡的系統很好用。")
        XCTAssertEqual(ForkSenseVoiceText.written("我想食面。", language: "yue", dictationLanguage: "zh-TW"), "我想食麵。")
        XCTAssertEqual(ForkSenseVoiceText.written("我要 check 一下 email 。", language: "zh", dictationLanguage: "zh-TW"), "我要 check 一下 email。")
    }

    func testAnEnglishReadingFollowsTheDictationRegion() {
        XCTAssertTrue(ForkSenseVoiceText.usesHongKong(language: "en", dictationLanguage: "yue-CN"))
        XCTAssertTrue(ForkSenseVoiceText.usesHongKong(language: "en", dictationLanguage: "zh-HK"))
        XCTAssertFalse(ForkSenseVoiceText.usesHongKong(language: "en", dictationLanguage: "zh-TW"))
        XCTAssertFalse(ForkSenseVoiceText.usesHongKong(language: "en", dictationLanguage: nil))
    }

    func testTheReadingKeepsTheDetectedLanguageAndDropsEveryTag() {
        XCTAssertEqual(
            ForkSenseVoiceEngine.reading(from: "<|yue|><|NEUTRAL|><|Speech|><|withitn|>我系香港人。"),
            ForkSenseVoiceEngine.Reading(text: "我系香港人。", language: "yue")
        )
        XCTAssertEqual(ForkSenseVoiceEngine.reading(from: "<|nospeech|><|EMO_UNKNOWN|><|Event_UNK|><|withitn|>"), ForkSenseVoiceEngine.Reading(text: "", language: ""))
    }

    // MARK: - Where the audio is cut

    func testALongRecordingIsCutAtItsPause() throws {
        let audio = tone(seconds: 20, silentAround: [9])
        let pieces = ForkSenseVoiceSegments.pieces(count: audio.count, samples: audio)
        XCTAssertEqual(pieces.count, 2)
        let cut = try XCTUnwrap(pieces.first?.upperBound)
        XCTAssertEqual(Double(cut) / 16_000, 9, accuracy: 0.2)
        XCTAssertEqual(pieces.last?.upperBound, audio.count)
        XCTAssertEqual(ForkSenseVoiceSegments.pieces(count: 160_000, samples: tone(seconds: 10)), [0..<160_000])
    }

    func testTheLastPieceIsNeverAFragment() throws {
        let audio = tone(seconds: 16, silentAround: [15.5])
        let pieces = ForkSenseVoiceSegments.pieces(count: audio.count, samples: audio)
        XCTAssertEqual(pieces.count, 2)
        let last = try XCTUnwrap(pieces.last)
        XCTAssertGreaterThanOrEqual(Double(last.count) / 16_000, ForkSenseVoiceSegments.shortestPiece)
    }

    func testALiveTailSettlesAtAPauseOnceLongEnoughAndIsCutAnywayPastForceAfter() throws {
        XCTAssertNil(ForkSenseVoiceSegments.liveCut(tone(seconds: 7, silentAround: [4])[...]))
        let cut = try XCTUnwrap(ForkSenseVoiceSegments.liveCut(tone(seconds: 9, silentAround: [5])[...]))
        XCTAssertEqual(Double(cut) / 16_000, 5, accuracy: 0.2)
        XCTAssertNil(ForkSenseVoiceSegments.liveCut(tone(seconds: 12)[...]), "no pause yet: the tail is read whole")
        XCTAssertNotNil(ForkSenseVoiceSegments.liveCut(tone(seconds: 13.5)[...]))
    }

    func testChineseRunsOnAndEnglishTakesASpace() {
        XCTAssertEqual(ForkSenseVoiceSegments.joined("今天開會。", "記得帶 laptop。"), "今天開會。記得帶 laptop。")
        XCTAssertEqual(ForkSenseVoiceSegments.joined("Check the email.", "Then call me."), "Check the email. Then call me.")
        XCTAssertEqual(ForkSenseVoiceSegments.joined("", "qa"), "qa")
    }

    func testASettledStretchStaysAndKeepsItsLanguageForTheRest() throws {
        var live = ForkSenseVoiceLive(dictationLanguage: "zh-HK")
        let audio = tone(seconds: 9, silentAround: [5])
        let first = live.round(audio[...], end: audio.count)
        let cut = try XCTUnwrap(first.cut)
        let shown = live.apply(
            ForkSenseVoiceLive.Result(
                settled: ForkSenseVoiceEngine.Reading(text: "我系香港人。", language: "yue"),
                tail: ForkSenseVoiceEngine.Reading(text: "去食面", language: "en")
            ),
            of: first
        )
        XCTAssertEqual(shown, LiveTranscript(settled: "我係香港人。", tentative: "去食麵"))
        XCTAssertEqual(live.language, "yue")
        XCTAssertEqual(live.settledEnd, cut)
        let next = live.round(audio[...], end: audio.count)
        XCTAssertEqual(next.start, cut)
        XCTAssertEqual(next.language, "yue")
    }

    // MARK: - Live rounds

    func testARoundReadsEveryTwoSecondsOfAudio() async {
        let reader = RoundReader()
        let live = makeLive(reader)
        var shown: [LiveTranscript] = []
        live.onUpdate = { shown.append($0) }

        feed(live, seconds: 1.9)
        XCTAssertEqual(reader.calls, 0)
        reader.enqueue("qa-一")
        feed(live, seconds: 0.1)
        await eventually("the first words") { shown.count == 1 }
        reader.enqueue("qa-二")
        feed(live, seconds: 2)
        await eventually("the second words") { shown.count == 2 }

        XCTAssertEqual(reader.tailSeconds, [2, 4])
        XCTAssertEqual(shown.map(\.tentative), ["qa-一", "qa-二"])
        XCTAssertEqual(live.rounds, 2)
        XCTAssertEqual(live.skipped, 0)
        live.stop()
    }

    func testARoundIsSkippedWhileTheLastOneIsStillReading() async {
        let reader = RoundReader()
        let live = makeLive(reader)
        var shown: [String] = []
        live.onUpdate = { shown.append($0.tentative) }

        feed(live, seconds: 2)
        await eventually("the first round reading") { reader.waiting == 1 }
        feed(live, seconds: 2.5)
        XCTAssertEqual(reader.calls, 1)
        XCTAssertEqual(live.skipped, 1)

        reader.answer("qa-一")
        await eventually("the first words") { shown == ["qa-一"] }
        feed(live, seconds: 1.5)
        await eventually("the next round") { reader.waiting == 1 }
        XCTAssertEqual(reader.tailSeconds, [2, 6])
        live.stop()
        reader.answer("qa-end")
    }

    func testNothingShowsOnceStoppedAndAFailureEndsTheLiveWords() async {
        let reader = RoundReader()
        let live = makeLive(reader)
        var shown = 0
        live.onUpdate = { _ in shown += 1 }
        feed(live, seconds: 2)
        await eventually("the round reading") { reader.waiting == 1 }
        live.stop()
        reader.answer("qa-late")
        await settle()
        XCTAssertEqual(shown, 0)

        let failing = RoundReader()
        let next = makeLive(failing)
        var failure: String?
        next.onFailure = { failure = $0 }
        failing.enqueueFailure()
        feed(next, seconds: 2)
        await eventually("the failure") { failure != nil }
        feed(next, seconds: 4)
        await settle()
        XCTAssertEqual(failing.calls, 1, "no round reads after a failure")
        next.stop()
    }

    func testACaptureAtAnotherRateIsReadAtSixteenKilohertz() async {
        let reader = RoundReader()
        let live = makeLive(reader, sampleRate: 48_000)
        var shown = 0
        live.onUpdate = { _ in shown += 1 }
        reader.enqueue("qa-48k")
        feed(live, seconds: 2.1, rate: 48_000)
        await eventually("the first words") { shown == 1 }
        XCTAssertEqual(reader.tailSeconds.first ?? 0, 2, accuracy: 0.1)
        live.stop()
    }

    // MARK: - Which dictations

    func testSenseVoiceReadsOnlyWhenOnInstalledAndInItsLanguages() {
        XCTAssertEqual(ForkSenseVoice.skipReason(enabled: false, installed: true, language: "zh-TW"), "lab-off")
        XCTAssertEqual(ForkSenseVoice.skipReason(enabled: true, installed: false, language: "zh-TW"), "not-installed")
        XCTAssertEqual(ForkSenseVoice.skipReason(enabled: true, installed: true, language: "fr-FR"), "language=fr-FR")
        for language in ["zh-TW", "zh-HK", "yue-CN", "en-US"] {
            XCTAssertNil(ForkSenseVoice.skipReason(enabled: true, installed: true, language: language), language)
        }
    }

    func testAReadNeedsRoomForItsLargestPieceAndTheRecording() {
        XCTAssertTrue(ForkSenseVoice.fits(audio: 60, available: 0))
        XCTAssertFalse(ForkSenseVoice.fits(audio: 60, available: 40 * 1_048_576))
        XCTAssertTrue(ForkSenseVoice.fits(audio: 60, available: 64 * 1_048_576))
    }

    // MARK: - Helpers

    /// A 440 Hz and 1.2 kHz tone at 16 kHz, silent for 0.6 s around each of `silentAround` seconds.
    private func tone(seconds: Double, silentAround: [Double] = []) -> [Float] {
        (0..<Int(seconds * 16_000)).map { index in
            let t = Float(index) / 16_000
            guard !silentAround.contains(where: { abs(Double(t) - $0) < 0.3 }) else { return 0 }
            return 0.3 * sin(2 * .pi * 440 * t) + 0.1 * sin(2 * .pi * 1_200 * t)
        }
    }

    private func makeLive(_ reader: RoundReader, sampleRate: Double = 16_000) -> ForkSenseVoiceLiveTranscriber {
        ForkSenseVoiceLiveTranscriber(sampleRate: sampleRate, dictationLanguage: "zh-TW") { round, tail in
            try await reader.read(round, tail)
        }
    }

    /// Silent 16-bit mono audio at `rate`, 0.1 s at a time, as the capture sends it.
    private func feed(_ live: ForkSenseVoiceLiveTranscriber, seconds: Double, rate: Double = 16_000) {
        let data = Data(count: Int(rate / 10) * 2)
        for _ in 0..<Int((seconds * 10).rounded()) { live.append(data) }
    }

    private func settle() async {
        for _ in 0..<50 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
    }

    private func eventually(_ what: String, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async {
        for _ in 0..<2_000 {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("timed out waiting for \(what)", file: file, line: line)
    }
}

/// Stands in for SenseVoice: records each round's tail and answers with the next queued text,
/// or holds the round until the test answers it.
private final class RoundReader: @unchecked Sendable {
    private struct Failure: Error {}

    private let lock = NSLock()
    private var queued: [Result<String, Error>] = []
    private var held: [CheckedContinuation<ForkSenseVoiceLive.Result, Error>] = []
    private var tails: [Double] = []

    var calls: Int { lock.withLock { tails.count } }
    var waiting: Int { lock.withLock { held.count } }
    var tailSeconds: [Double] { lock.withLock { tails } }

    func enqueue(_ text: String) { lock.withLock { queued.append(.success(text)) } }
    func enqueueFailure() { lock.withLock { queued.append(.failure(Failure())) } }

    func read(_ round: ForkSenseVoiceLive.Round, _ tail: [Float]) async throws -> ForkSenseVoiceLive.Result {
        let next = lock.withLock { () -> Result<String, Error>? in
            tails.append(Double(tail.count) / 16_000)
            return queued.isEmpty ? nil : queued.removeFirst()
        }
        if let next { return try Self.result(next.get()) }
        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock { held.append(continuation) }
        }
    }

    func answer(_ text: String) {
        let continuation = lock.withLock { held.isEmpty ? nil : held.removeFirst() }
        continuation?.resume(returning: Self.result(text))
    }

    private static func result(_ text: String) -> ForkSenseVoiceLive.Result {
        ForkSenseVoiceLive.Result(settled: nil, tail: ForkSenseVoiceEngine.Reading(text: text, language: "zh"))
    }
}
