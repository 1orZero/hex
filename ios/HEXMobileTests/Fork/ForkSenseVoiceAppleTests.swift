import XCTest
@testable import HEX

/// Labs › SenseVoice（中文） (fork): Apple's speech recognition stays out of the dictations SenseVoice
/// writes and runs as before for the rest.
@available(iOS 26.0, *)
@MainActor
final class ForkSenseVoiceAppleTests: XCTestCase {
    /// The app loads Apple's model as it prepares only where SenseVoice won't read its dictations.
    func testTheAppLoadsApplesModelAheadOnlyWhereSenseVoiceWontRead() {
        func reads(enabled: Bool = true, installed: Bool = true, language: String? = "yue-CN", dropline: Bool = false, _ model: ForkSenseVoiceLoader.State = .notLoaded) -> Bool {
            ForkSenseVoice.readsAppDictations(enabled: enabled, installed: installed, language: language, droplineSelected: dropline, model: model)
        }
        XCTAssertTrue(reads(), "SenseVoice loads instead, before the first dictation")
        XCTAssertTrue(reads(.loaded))
        XCTAssertTrue(reads(language: "en-US"))
        XCTAssertFalse(reads(enabled: false), "lab off")
        XCTAssertFalse(reads(installed: false), "no model")
        XCTAssertFalse(reads(language: "fr-FR"))
        XCTAssertFalse(reads(dropline: true), "a dictation Dropline fails reaches SenseVoice unloaded")
        XCTAssertFalse(reads(.failed), "a failed load leaves every dictation to Apple")
    }

    /// While SenseVoice's model is loaded in the keyboard with room to read, it writes the dictation,
    /// so its live words are SenseVoice's or none; otherwise Apple writes the dictation and the live
    /// words are the keyboard's own.
    func testTheKeyboardsLiveWordsLeaveAppleOutOnlyWhileSenseVoiceCanRead() {
        func leaves(applies: Bool = true, _ model: ForkSenseVoiceLoader.State = .loaded, room: Bool = true) -> Bool {
            ForkSenseVoiceLiveWords.leavesAppleOut(applies: applies, model: model, roomToRead: room)
        }
        XCTAssertTrue(leaves())
        XCTAssertFalse(leaves(.notLoaded))
        XCTAssertFalse(leaves(.failed))
        XCTAssertFalse(leaves(applies: false), "lab off or another language")
        XCTAssertFalse(leaves(room: false), "the dictation falls back as memory")
    }
}
