import XCTest
@testable import HEX

/// Labs › SenseVoice（中文） (fork): the keyboard can't hold SenseVoice on most iPhones, so Keep mic warm
/// shows while the lab is on, where the keyboard dictates by itself and upstream hides it at Off.
/// A warm session then records the keyboard's dictations in the app, where SenseVoice reads them.
@MainActor
final class ForkKeepMicWarmTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var labWasOn = false

    override func setUp() async throws {
        suiteName = "qa-fork-keep-mic-warm.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        labWasOn = ForkSenseVoice.isEnabled
    }

    override func tearDown() async throws {
        ForkSenseVoice.isEnabled = labWasOn
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testKeepMicWarmShowsWhileTheLabIsOnAndAPickStays() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= KeyboardSelfDictation.firstVersion)
        let audio = KeepaliveAudio()
        let controller = makeController(audio)
        controller.prepareModel()
        try await settle()
        XCTAssertTrue(KeyboardBridge(defaults: defaults).keyboardDictatesItself())

        ForkSenseVoice.isEnabled = false
        XCTAssertEqual(controller.warmDuration, .off)
        XCTAssertFalse(controller.showsKeepMicWarm, "lab off: upstream hides it")

        ForkSenseVoice.isEnabled = true
        XCTAssertTrue(controller.showsKeepMicWarm)

        for duration in [WarmSessionDuration.fiveMinutes, .oneHour, .fifteenMinutes] {
            controller.selectWarmDuration(duration)
            try await settle()
            XCTAssertTrue(controller.keyboardSessionEnabled, "picking \(duration) warms at once")
            XCTAssertTrue(audio.isKeepaliveRunning)

            controller.refreshWarmDuration()
            XCTAssertEqual(controller.warmDuration, duration, "the keyboard dictating by itself doesn't turn it off")
            XCTAssertTrue(controller.keyboardSessionEnabled)
        }

        let relaunched = makeController(KeepaliveAudio())
        XCTAssertEqual(relaunched.warmDuration, .fifteenMinutes, "the first launch used up the one-time review, so a relaunch keeps a picked 15m")

        controller.selectWarmDuration(.off)
        try await settle()
        XCTAssertFalse(controller.keyboardSessionEnabled)
        XCTAssertTrue(controller.showsKeepMicWarm, "Off stays pickable while the lab is on")
        ForkSenseVoice.isEnabled = false
        XCTAssertFalse(controller.showsKeepMicWarm)
    }

    private func makeController(_ audio: KeepaliveAudio) -> DictationController {
        let transcriber = ReadyTranscriber()
        return DictationController(
            audio: audio,
            keyboardBridge: KeyboardBridge(defaults: defaults),
            transcriber: transcriber,
            transcriberFactory: { transcriber },
            now: { 9_000 },
            autoPrepareOnInit: false
        )
    }

    private func settle() async throws {
        for _ in 0..<50 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(20))
    }
}

/// Holds the microphone between dictations; this test never records.
private final class KeepaliveAudio: AudioManaging {
    var isKeepaliveRunning = false
    var onSystemEvent: ((AudioSystemEvent) -> Void)?
    var onUnexpectedCaptureEnd: ((URL, Bool) -> Void)?

    func requestPermission() async -> Bool { true }
    func startKeepalive() throws { isKeepaliveRunning = true }
    func stopKeepalive() { isKeepaliveRunning = false }
    func deactivateSession() { isKeepaliveRunning = false }
    func beginCapture(at url: URL, maxDuration: TimeInterval, microphone: MicrophoneChoice) throws -> any ActiveAudioCapture {
        throw CocoaError(.fileWriteUnknown)
    }
}

private actor ReadyTranscriber: LocalTranscribing {
    nonisolated let engine: DictationEngine = .appleSpeech
    let languageName = "English"

    func prepare(progressHandler: @escaping @Sendable (ModelPreparationProgress) -> Void) async throws {
        progressHandler(ModelPreparationProgress(fractionCompleted: 1, detail: "Ready"))
    }

    func transcribe(_ audioURL: URL) async throws -> String { "" }
}
