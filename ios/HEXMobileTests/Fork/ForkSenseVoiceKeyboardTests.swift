import XCTest
@testable import HEX

/// Labs › SenseVoice（中文） in the keyboard (fork): its memory budget in `KeyboardParakeetBudget`'s
/// terms, what the keyboard does with it as it opens, and what the Labs card says about it.
@MainActor
final class ForkSenseVoiceKeyboardTests: XCTestCase {
    private let megabyte = 1_048_576

    // MARK: - Budget

    /// 91 MB recording with Parakeet, less its 42 MB load, plus SenseVoice's 60 MB, then Parakeet's
    /// 16 MB transcription rise and 24 MB margin. The 40 MB above the recording covers the 32 MB a
    /// keyboard needs to start its next dictation (`KeyboardLocalDictation.startHeadroomNeeded`).
    func testTheKeyboardNeeds149MegabytesAndKeepsItsNextDictationsStart() {
        XCTAssertEqual(ForkSenseVoiceBudget.recordingFootprint, 109 * megabyte)
        XCTAssertEqual(ForkSenseVoiceBudget.requiredLimit, 149 * megabyte)
        XCTAssertEqual(ForkSenseVoiceBudget.loadHeadroom, 92 * megabyte)
        XCTAssertEqual(ForkSenseVoiceBudget.startHeadroom, 32 * megabyte)
        XCTAssertGreaterThanOrEqual(
            ForkSenseVoiceBudget.requiredLimit - ForkSenseVoiceBudget.recordingFootprint,
            ForkSenseVoiceBudget.startHeadroom
        )
    }

    func testALoadNeedsTheLimitAndRoomForWhatSenseVoiceKeepsAndTheNextStart() {
        XCTAssertTrue(ForkSenseVoiceBudget.allowsLoad(footprint: 50 * megabyte, available: 127 * megabyte), "177 MB, as an iPhone 17 Pro's")
        XCTAssertFalse(ForkSenseVoiceBudget.allowsLoad(footprint: 90 * megabyte, available: 87 * megabyte), "the same keyboard after a while")
        XCTAssertTrue(ForkSenseVoiceBudget.allowsLoad(footprint: 57 * megabyte, available: 92 * megabyte))
        XCTAssertFalse(ForkSenseVoiceBudget.allowsLoad(footprint: 20 * megabyte, available: 110 * megabyte), "a 130 MB keyboard, under 149 MB")
        XCTAssertTrue(ForkSenseVoiceBudget.allowsLoad(footprint: 20 * megabyte, available: 0), "no limit, as in the simulator")
    }

    /// Its rise, the recording at 0.5 MB a second, and 32 MB left after it.
    func testAReadNeedsItsRiseTheRecordingAndTheNextStart() {
        XCTAssertEqual(ForkSenseVoiceBudget.readHeadroom(audioSeconds: 10), 53 * megabyte)
        XCTAssertTrue(ForkSenseVoiceBudget.allowsRead(footprint: 110 * megabyte, available: 67 * megabyte, audioSeconds: 15))
        XCTAssertFalse(ForkSenseVoiceBudget.allowsRead(footprint: 110 * megabyte, available: 67 * megabyte, audioSeconds: 60))
        XCTAssertFalse(ForkSenseVoiceBudget.allowsRead(footprint: 60 * megabyte, available: 80 * megabyte, audioSeconds: 5), "a 140 MB keyboard")
        XCTAssertTrue(ForkSenseVoiceBudget.allowsRead(footprint: 60 * megabyte, available: 0, audioSeconds: 120))
    }

    // MARK: - As the keyboard opens

    private func decide(
        applies: Bool = true,
        dropline: Bool = false,
        parakeet: Bool = false,
        model: ForkSenseVoiceLoader.State = .notLoaded,
        loading: Bool = false,
        setAside: Bool = false,
        memoryWarned: Bool = false,
        footprint: Int = 50 * 1_048_576,
        available: Int = 127 * 1_048_576,
        neuralEngine: Bool = true
    ) -> ForkSenseVoiceKeyboard.Decision {
        ForkSenseVoiceKeyboard.decide(
            applies: applies,
            droplineSelected: dropline,
            parakeet: parakeet,
            model: model,
            loading: loading,
            setAside: setAside,
            memoryWarned: memoryWarned,
            footprint: footprint,
            available: available,
            hasNeuralEngine: neuralEngine
        )
    }

    func testTheKeyboardLoadsWhereItFitsAndKeepsWhatItLoaded() {
        XCTAssertEqual(decide(), .load)
        XCTAssertEqual(decide(model: .loaded), .keep)
        XCTAssertEqual(decide(model: .loaded, footprint: 120 * megabyte, available: 57 * megabyte), .keep, "loaded stays until a memory warning")
        XCTAssertEqual(decide(loading: true), .leave)
        XCTAssertEqual(decide(model: .failed), .leave)
        XCTAssertEqual(decide(setAside: true), .leave)
    }

    func testNeverBesideParakeet() {
        XCTAssertEqual(decide(parakeet: true), .leave)
        XCTAssertEqual(decide(parakeet: true, model: .loaded), .release("parakeet"))
        XCTAssertEqual(decide(parakeet: true, loading: true), .release("parakeet"))
    }

    func testAKeyboardSenseVoiceNoLongerReadsLetsItGo() {
        XCTAssertEqual(decide(applies: false), .leave)
        XCTAssertEqual(decide(applies: false, model: .loaded), .release("off"))
        XCTAssertEqual(decide(dropline: true), .leave, "Dropline writes the dictation; nothing loads")
        XCTAssertEqual(decide(dropline: true, model: .loaded), .leave, "one already loaded stays for Dropline's fallback")
    }

    func testAfterAMemoryWarningNothingLoads() {
        XCTAssertEqual(decide(memoryWarned: true), .unavailable(.shortOfMemory, free: nil))
    }

    func testTooSmallShortOfMemoryAndNoNeuralEngine() {
        XCTAssertEqual(decide(footprint: 40 * megabyte, available: 90 * megabyte), .tooSmall(limit: 130 * megabyte))
        XCTAssertEqual(decide(footprint: 90 * megabyte, available: 87 * megabyte), .unavailable(.shortOfMemory, free: 87 * megabyte))
        XCTAssertEqual(decide(neuralEngine: false), .unavailable(.noNeuralEngine, free: nil))
        XCTAssertEqual(decide(available: 0, neuralEngine: false), .unavailable(.noNeuralEngine, free: nil), "the simulator")
    }

    // MARK: - What the keyboard says

    func testTheKeyboardsWordRoundTripsThroughTheAppGroup() throws {
        let suite = "qa-fork-sensevoice-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let status = ForkSenseVoiceKeyboardStatus(defaults: defaults)
        status.set(.unavailable, reason: .shortOfMemory, free: 80 * megabyte, now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(status.state?.state, .unavailable)
        XCTAssertEqual(status.state?.at, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(status.reason, .shortOfMemory)
        XCTAssertEqual(status.free, 80 * megabyte)
        status.set(.ready)
        XCTAssertEqual(status.state?.state, .ready)
        XCTAssertNil(status.reason)
        XCTAssertNil(status.free)
        status.set(nil)
        XCTAssertNil(status.state)
    }

    // MARK: - Labs card

    private func lines(
        parakeet: Bool = false,
        limit: Int? = nil,
        state: KeyboardParakeetSettings.KeyboardState? = nil,
        at: Date = Date(timeIntervalSince1970: 0),
        reason: KeyboardParakeetSettings.UnavailableReason? = nil,
        free: Int? = nil,
        now: Date = Date(timeIntervalSince1970: 60)
    ) -> [String] {
        ForkSenseVoiceKeyboardLine.lines(
            parakeetTakes: parakeet,
            keyboardLimit: limit,
            keyboardState: state.map { ($0, at) },
            reason: reason,
            free: free,
            now: now
        )
    }

    func testTheCardSaysTheKeyboardsLimitAndWhatSenseVoiceNeeds() {
        XCTAssertEqual(lines(limit: 120 * megabyte, state: .ready), [
            "This iPhone's keyboard has 120 MB; the model needs 149 MB, so it uses Apple's speech recognition.",
        ])
        XCTAssertEqual(lines(limit: 149 * megabyte - 1, state: .ready), [
            "This iPhone's keyboard has 148 MB; the model needs 149 MB, so it uses Apple's speech recognition.",
        ])
        XCTAssertEqual(lines(limit: 177 * megabyte, state: .ready), [
            "This iPhone's keyboard has 177 MB; the model needs 149 MB.",
            "Ready in the keyboard",
        ])
        XCTAssertEqual(lines(limit: 177 * megabyte, state: .preparing), [
            "This iPhone's keyboard has 177 MB; the model needs 149 MB.",
            "Getting ready in the keyboard. After a download or an update, this takes a little longer.",
        ])
        XCTAssertEqual(lines(limit: 177 * megabyte, state: .unavailable, reason: .shortOfMemory, free: 80 * megabyte), [
            "This iPhone's keyboard has 177 MB; the model needs 149 MB.",
            "The keyboard had 80 MB free when it last opened; loading the model needs 92 MB, so it used Apple's speech recognition. It tries again the next time it opens.",
        ])
        XCTAssertEqual(lines(limit: 177 * megabyte, state: .unavailable, reason: .shortOfMemory), [
            "This iPhone's keyboard has 177 MB; the model needs 149 MB.",
            "Not enough free memory when the keyboard last opened, so it used Apple's speech recognition. It tries again the next time it opens.",
        ], "after a memory warning, no number")
    }

    func testTheCardSaysWhyWithoutALimit() {
        XCTAssertEqual(lines(), ["Downloaded. The keyboard gets it ready the next time it opens."])
        XCTAssertEqual(lines(state: .unavailable, reason: .noNeuralEngine), [
            "This iPhone can't run it in the keyboard, so the keyboard uses Apple's speech recognition.",
        ], "the simulator, which records no limit")
        XCTAssertEqual(lines(state: .preparing, now: Date(timeIntervalSince1970: 200)), [
            "Downloaded. The keyboard gets it ready the next time it opens.",
        ], "getting ready lasts 3 minutes")
        XCTAssertEqual(lines(parakeet: true, limit: 177 * megabyte, state: .ready), [
            "The keyboard uses Hex's speech model for this language instead of SenseVoice.",
        ])
    }
}
