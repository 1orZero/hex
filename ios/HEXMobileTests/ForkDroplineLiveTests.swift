import AVFAudio
import UIKit
import XCTest
@testable import HEX

/// The fork's live words while Dropline is selected (`ForkDroplineLiveWords`): drafts of the
/// recording so far every 4 s of audio, none while one is out or past 180 s, Listening… until
/// the first text, one session with the final text, and no other engine.
@MainActor
final class ForkDroplineLiveTests: XCTestCase {
    private let endpoint = URL(string: "https://qa-worker.example/v1/dropline-private/token")!
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "qa-fork-dropline-live-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Rounds

    func testDraftsGoOutEveryFourSecondsOfAudioWithTheRecordingSoFar() async {
        let sender = DraftSender()
        let live = makeLive(sender)
        var shown: [String] = []
        live.onUpdate = { shown.append($0.text) }

        feed(live, seconds: 3.9)
        XCTAssertEqual(sender.calls, 0)
        for round in 1...3 {
            sender.enqueue(.success(ForkDroplineAnswer(text: "qa-draft-\(round)", language: nil)))
            feed(live, seconds: round == 1 ? 0.1 : 4)
            await eventually("draft \(round) shown") { shown.count == round }
        }

        XCTAssertEqual(sender.audioSeconds, [4, 8, 12])
        XCTAssertEqual(shown, ["qa-draft-1", "qa-draft-2", "qa-draft-3"])
        XCTAssertEqual(live.sent, 3)
        XCTAssertEqual(live.skipped, 0)
    }

    func testARoundIsSkippedWhileTheLastRequestIsStillOut() async {
        let sender = DraftSender()
        let live = makeLive(sender)
        var shown: [String] = []
        live.onUpdate = { shown.append($0.text) }

        feed(live, seconds: 4)
        await eventually("the first request out") { sender.waiting == 1 }
        feed(live, seconds: 5)
        XCTAssertEqual(sender.calls, 1, "the round at 8 s waits for nothing: it is skipped")
        XCTAssertEqual(live.skipped, 1)

        sender.answer("qa-draft-1")
        await eventually("the first text") { shown == ["qa-draft-1"] }
        feed(live, seconds: 3)
        await eventually("the next request") { sender.waiting == 1 }

        XCTAssertEqual(sender.audioSeconds, [4, 12])
        XCTAssertEqual(live.sent, 2)
        live.stop()
    }

    func testListeningShowsUntilTheFirstTextArrives() async {
        let sender = DraftSender()
        let live = makeLive(sender)
        let text = LiveDictationText()
        // What `KeyboardLiveDictation.attach` does with a source.
        text.begin(showsPreview: true, typesIntoField: false)
        live.onUpdate = { text.update($0) }
        let preview = LiveDictationPreviewView(frame: CGRect(x: 0, y: 0, width: 390, height: 216))
        preview.textInsets = UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)

        preview.show(text.transcript ?? LiveTranscript())
        XCTAssertEqual(text.transcript, LiveTranscript())
        XCTAssertEqual(preview.accessibilityLabel, "Listening…")
        attachRender(of: preview, named: "fork-dropline-live-1-listening")

        sender.enqueue(.success(ForkDroplineAnswer(text: "", language: nil)))
        feed(live, seconds: 4)
        await eventually("the empty answer") { sender.calls == 1 && live.sent == 1 }
        await settle()
        XCTAssertEqual(text.transcript, LiveTranscript(), "no speech yet: still Listening…")

        sender.enqueue(.success(ForkDroplineAnswer(text: "qa-今天下午三點開會", language: "zh")))
        feed(live, seconds: 4)
        await eventually("the first text") { text.transcript?.text == "qa-今天下午三點開會" }
        preview.show(text.transcript ?? LiveTranscript())
        XCTAssertEqual(preview.accessibilityLabel, "qa-今天下午三點開會")
        attachRender(of: preview, named: "fork-dropline-live-2-first-text")
        live.stop()
    }

    func testNoRequestAfter180SecondsAndTheLastTextStays() async {
        let sender = DraftSender()
        let live = makeLive(sender)
        var shown: [String] = []
        live.onUpdate = { shown.append($0.text) }

        for round in 1...45 {
            sender.enqueue(.success(ForkDroplineAnswer(text: "qa-draft-\(round)", language: nil)))
            feed(live, seconds: 4, chunk: 1)
            await eventually("draft \(round)") { shown.count == round }
        }
        sender.enqueue(.success(ForkDroplineAnswer(text: "qa-too-late", language: nil)))
        feed(live, seconds: 20, chunk: 1)
        await settle()

        XCTAssertEqual(sender.calls, 45)
        XCTAssertEqual(sender.audioSeconds.last, 180)
        XCTAssertEqual(shown.last, "qa-draft-45")
        live.stop()
    }

    func testTooManyRequestsStopsTheDraftsAndKeepsTheText() async {
        let sender = DraftSender()
        let live = makeLive(sender)
        var shown: [String] = []
        live.onUpdate = { shown.append($0.text) }

        sender.enqueue(.success(ForkDroplineAnswer(text: "qa-draft-1", language: nil)))
        feed(live, seconds: 4)
        await eventually("the first text") { shown.count == 1 }
        sender.enqueue(.failure(ForkDroplineFailure.http(status: 429)))
        feed(live, seconds: 4)
        await eventually("the refused request back") { sender.calls == 2 && sender.waiting == 0 }
        await settle()
        feed(live, seconds: 12)
        await settle()

        XCTAssertEqual(sender.calls, 2, "Dropline's limit is left for the final text")
        XCTAssertEqual(shown, ["qa-draft-1"])
        live.stop()
    }

    func testATimeoutLeavesTheNextRoundsGoing() async {
        let sender = DraftSender()
        let live = makeLive(sender)
        var shown: [String] = []
        live.onUpdate = { shown.append($0.text) }

        sender.enqueue(.failure(ForkDroplineFailure.timeout))
        feed(live, seconds: 4)
        await eventually("the failed request back") { sender.calls == 1 && sender.waiting == 0 }
        await settle()
        sender.enqueue(.success(ForkDroplineAnswer(text: "qa-draft-2", language: nil)))
        feed(live, seconds: 4)
        await eventually("the next text") { shown == ["qa-draft-2"] }
        live.stop()
    }

    func testStopDropsTheRequestOutAndShowsNothingMore() async {
        let sender = DraftSender()
        let live = makeLive(sender)
        var shown: [String] = []
        live.onUpdate = { shown.append($0.text) }

        feed(live, seconds: 4)
        await eventually("the request out") { sender.waiting == 1 }
        live.stop()
        sender.answer("qa-late")
        feed(live, seconds: 8)
        await settle()

        XCTAssertEqual(shown, [])
        XCTAssertEqual(sender.calls, 1)
    }

    func testA48kHzCaptureGoesOutAt16kHz() async {
        let sender = DraftSender()
        let live = makeLive(sender, sampleRate: 48_000)

        feed(live, seconds: 4.3, rate: 48_000)
        await eventually("the first request") { sender.calls == 1 }

        let seconds = try? XCTUnwrap(sender.audioSeconds.first)
        XCTAssertGreaterThanOrEqual(seconds ?? 0, 4)
        XCTAssertLessThan(seconds ?? 0, 4.2)
        live.stop()
    }

    // MARK: - Dropline selected or not

    func testDroplineLiveWordsOnlyWhileDroplineIsSelected() {
        let settings = ForkDroplineSettings(defaults: defaults)
        let recognition = ForkDroplineRecognition(settings: settings, secrets: FakeDroplineSecrets())

        XCTAssertFalse(settings.isSelected)
        XCTAssertNil(ForkDroplineLiveWords.source(sampleRate: 16_000, recognition: recognition, hints: []))
        settings.isEnabled = true
        XCTAssertFalse(settings.isSelected, "no endpoint yet")
        XCTAssertNil(ForkDroplineLiveWords.source(sampleRate: 16_000, recognition: recognition, hints: []))
        settings.endpoint = endpoint
        XCTAssertTrue(settings.isSelected, "the keyboard's speech model doesn't load either")
        XCTAssertNotNil(ForkDroplineLiveWords.source(sampleRate: 16_000, recognition: recognition, hints: []))
        settings.isEnabled = false
        XCTAssertNil(ForkDroplineLiveWords.source(sampleRate: 48_000, recognition: recognition, hints: []))
    }

    func testDraftsAndTheFinalTextGoOutInOneSessionWithTheVocabularyAndNoOtherEngine() async throws {
        let http = FakeDroplineHTTP()
        let clock = FakeDroplineClock(now: Date(timeIntervalSince1970: 1_800_000_000))
        let tokens = ForkDroplineTokenCache()
        let recognition = makeRecognition(http: http, clock: clock, tokens: tokens)
        await tokens.store(
            ForkDroplineAccessToken(value: "qa-access", expiresAt: clock.now().addingTimeInterval(3600)),
            for: ForkDroplineCredential(endpoint: endpoint, bearer: "qa-bearer")
        )
        http.enqueue(FakeDroplineHTTP.json(200, [:]))
        await recognition.prepare(hints: ["qa-Dropline"])
        let session = try XCTUnwrap(
            ((JSONSerialization.jsonObject(with: http.requests[0].httpBody ?? Data()) as? [String: Any])?["client"] as? [String: Any])?["session_id"] as? String
        )

        let live = try XCTUnwrap(ForkDroplineLiveWords.source(sampleRate: 16_000, recognition: recognition, hints: ["qa-Dropline"]))
        var shown: [String] = []
        live.onUpdate = { shown.append($0.text) }
        http.enqueue(FakeDroplineHTTP.json(200, ["final_text": "qa-第一段"]))
        feed(live, seconds: 4)
        await eventually("draft 1") { shown.count == 1 }
        clock.advance(4)
        http.enqueue(FakeDroplineHTTP.json(200, ["final_text": "qa-第一段第二段"]))
        feed(live, seconds: 4)
        await eventually("draft 2") { shown.count == 2 }
        live.stop()

        clock.advance(150)
        let local = ForkDroplineCounter()
        http.enqueue(FakeDroplineHTTP.json(200, ["final_text": "qa-第一段第二段。"]))
        let result = try await recognition.recognize(URL(fileURLWithPath: "/tmp/qa.wav"), hints: ["qa-Dropline"]) {
            local.increment()
            return "qa-local"
        }

        guard case .dropline(let answer) = result else { return XCTFail("expected Dropline's text") }
        XCTAssertEqual(answer.text, "qa-第一段第二段。")
        XCTAssertEqual(shown, ["qa-第一段", "qa-第一段第二段"])
        XCTAssertEqual(local.value, 0, "no local engine while Dropline answers")
        let dictations = http.requests.filter { $0.url?.path == "/client/dictate" }
        XCTAssertEqual(dictations.count, 3)
        for request in dictations {
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            XCTAssertTrue(body.contains(#""session_id":"\#(session)""#), "every request in the prepared session")
            XCTAssertTrue(body.contains(#""text":"qa-Dropline""#), "with the vocabulary as context")
        }
        XCTAssertNil(ForkDroplineSettings(defaults: defaults).lastFallback)
    }

    func testTheLocalEngineRunsOnlyWhenDroplinesFinalTextFails() async throws {
        let http = FakeDroplineHTTP()
        let clock = FakeDroplineClock(now: Date(timeIntervalSince1970: 1_800_000_000))
        let tokens = ForkDroplineTokenCache()
        let recognition = makeRecognition(http: http, clock: clock, tokens: tokens)
        await tokens.store(
            ForkDroplineAccessToken(value: "qa-access", expiresAt: clock.now().addingTimeInterval(3600)),
            for: ForkDroplineCredential(endpoint: endpoint, bearer: "qa-bearer")
        )
        let local = ForkDroplineCounter()
        let url = URL(fileURLWithPath: "/tmp/qa.wav")

        http.enqueue(FakeDroplineHTTP.json(500, [:]))
        do {
            _ = try await recognition.draft([[Int16](repeating: 0, count: 16_000)], hints: [])
            XCTFail("expected the draft to fail")
        } catch {
            XCTAssertEqual(error as? ForkDroplineFailure, .http(status: 500))
        }
        XCTAssertNil(ForkDroplineSettings(defaults: defaults).lastFallback, "a draft never records a fallback")

        http.enqueue(FakeDroplineHTTP.json(200, ["final_text": "qa-ok"]))
        _ = try await recognition.recognize(url, hints: []) { local.increment(); return "qa-local" }
        XCTAssertEqual(local.value, 0)

        http.enqueue(FakeDroplineHTTP.json(500, [:]))
        let fallback = try await recognition.recognize(url, hints: []) { local.increment(); return "qa-local" }
        guard case .local(let text, let failure) = fallback else { return XCTFail("expected the local engine") }
        XCTAssertEqual(text, "qa-local")
        XCTAssertEqual(failure, .http(status: 500))
        XCTAssertEqual(local.value, 1)
        XCTAssertEqual(ForkDroplineSettings(defaults: defaults).lastFallback?.reason, "HTTP 500")
    }

    // MARK: - Draft audio

    func testDraftAudioIsMeasuredAndEncodedAsARecordingFileIs() throws {
        let chunks = toneChunks(seconds: 4, tone: { $0 < 1 || $0 >= 3 })
        let url = try writeRecording(chunks)
        defer { try? FileManager.default.removeItem(at: url) }
        var fromFile: [UInt8] = []
        var fromChunks: [UInt8] = []
        try ForkDroplineAudio.forEachBlock(of: url) { fromFile.append(ForkDroplineAudio.level(of: $0)) }
        try ForkDroplineAudio.forEachBlock(of: chunks) { fromChunks.append(ForkDroplineAudio.level(of: $0)) }
        XCTAssertEqual(fromChunks.count, 200)
        XCTAssertEqual(fromChunks, fromFile)

        do {
            _ = try ForkOpusOggEncoder()
        } catch {
            throw XCTSkip("The Opus encoder is unavailable here: \(error)")
        }
        let encoded = try ForkDroplineAudio.encoded(chunks: chunks)
        XCTAssertEqual(encoded.prefix(4), Data("OggS".utf8))
        XCTAssertNotNil(encoded.range(of: Data("OpusHead".utf8)))
    }

    func testDraftAudioOver178SecondsOfSpeechIsRefused() {
        XCTAssertThrowsError(try ForkDroplineAudio.encoded(chunks: toneChunks(seconds: 179, tone: { _ in true }))) { error in
            XCTAssertEqual(error as? ForkDroplineFailure, .tooLong)
        }
    }

    // MARK: - Helpers

    private func makeLive(_ sender: DraftSender, sampleRate: Double = 16_000) -> ForkDroplineLiveTranscriber {
        ForkDroplineLiveTranscriber(sampleRate: sampleRate) { try await sender.send($0) }
    }

    private func makeRecognition(http: FakeDroplineHTTP, clock: FakeDroplineClock, tokens: ForkDroplineTokenCache) -> ForkDroplineRecognition {
        let settings = ForkDroplineSettings(defaults: defaults)
        settings.endpoint = endpoint
        settings.isEnabled = true
        let secrets = FakeDroplineSecrets()
        secrets.stored = "qa-bearer"
        return ForkDroplineRecognition(
            settings: settings,
            secrets: secrets,
            client: ForkDroplineClient(http: http, clock: clock, tokens: tokens),
            sessions: ForkDroplineSessions(),
            encode: { _ in Data("qa-ogg".utf8) },
            encodeDraft: { _ in Data("qa-ogg".utf8) }
        )
    }

    /// Silent 16-bit mono audio at `rate`, `chunk` seconds at a time, as the capture sends it.
    private func feed(_ live: ForkDroplineLiveTranscriber, seconds: Double, rate: Double = 16_000, chunk: Double = 0.1) {
        let frames = Int((rate * chunk).rounded())
        let data = Data(count: frames * 2)
        for _ in 0..<Int((seconds / chunk).rounded()) {
            live.append(data)
        }
    }

    private func toneChunks(seconds: Double, tone: (Double) -> Bool) -> [[Int16]] {
        let rate = 16_000
        return stride(from: 0, to: Int(seconds * Double(rate)), by: 4_096).map { start in
            (start..<min(start + 4_096, Int(seconds * Double(rate)))).map { index in
                let t = Double(index) / Double(rate)
                let amplitude = tone(t) ? 0.3 : 0.0005
                return Int16(sin(t * 2 * .pi * 440) * amplitude * 32_767)
            }
        }
    }

    private func writeRecording(_ chunks: [[Int16]]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("qa-dropline-live-\(UUID().uuidString).wav")
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true))
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        for chunk in chunks {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk.count)))
            buffer.frameLength = AVAudioFrameCount(chunk.count)
            chunk.withUnsafeBufferPointer { source in
                buffer.int16ChannelData?[0].update(from: source.baseAddress!, count: chunk.count)
            }
            try file.write(from: buffer)
        }
        return url
    }

    /// The preview over the full keyboard's background, kept with the test results.
    private func attachRender(of preview: LiveDictationPreviewView, named name: String) {
        preview.layoutIfNeeded()
        let palette = FullKeyboardPalette(isDark: false)
        let image = UIGraphicsImageRenderer(bounds: preview.bounds).image { context in
            palette.backdrop.setFill()
            context.fill(preview.bounds)
            preview.layer.render(in: context.cgContext)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func settle() async {
        for _ in 0..<50 {
            await Task.yield()
        }
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

/// Stands in for Dropline: records each request's audio and answers with the next queued result,
/// or holds the request until the test answers it.
private final class DraftSender: @unchecked Sendable {
    private let lock = NSLock()
    private var lengths: [Int] = []
    private var queued: [Result<ForkDroplineAnswer, Error>] = []
    private var held: [CheckedContinuation<ForkDroplineAnswer, Error>] = []

    var calls: Int { lock.withLock { lengths.count } }
    var waiting: Int { lock.withLock { held.count } }
    var audioSeconds: [Double] { lock.withLock { lengths.map { Double($0) / 16_000 } } }

    func enqueue(_ result: Result<ForkDroplineAnswer, Error>) {
        lock.withLock { queued.append(result) }
    }

    func send(_ chunks: [[Int16]]) async throws -> ForkDroplineAnswer {
        let count = chunks.reduce(0) { $0 + $1.count }
        let next = lock.withLock { () -> Result<ForkDroplineAnswer, Error>? in
            lengths.append(count)
            return queued.isEmpty ? nil : queued.removeFirst()
        }
        if let next { return try next.get() }
        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock { held.append(continuation) }
        }
    }

    func answer(_ text: String) {
        let continuation = lock.withLock { held.isEmpty ? nil : held.removeFirst() }
        continuation?.resume(returning: ForkDroplineAnswer(text: text, language: nil))
    }
}
