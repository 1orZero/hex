import Foundation
import os
import Speech

/// What Apple's speech recognition leaves undone while SenseVoice writes dictations (Labs ›
/// SenseVoice（中文）): Apple's model loads, and its recognisers start, only for a dictation that falls
/// back to it. Where SenseVoice can't write them (the lab off, no model, another language, Dropline
/// selected, a failed load, a keyboard that never loads it), Apple prepares as without the lab. Asset
/// upkeep stays either way: the dictation language's reservation and download as Hex prepares
/// (`AppleSpeechTranscriber.prepare`) and three-language dictation's as Hex becomes active
/// (`ForkThreeLanguage.prepareModels`), since a fallback can't read without its models and the
/// keyboard never downloads them.
@available(iOS 26.0, *)
extension ForkSenseVoice {
    /// Whether SenseVoice reads the app's dictations in `language` as things stand. Not while Dropline
    /// is selected: Dropline writes first, and the dictation it fails reaches SenseVoice unloaded
    /// (`prewarm` skips it), so Apple's model reads it.
    static func readsAppDictations(enabled: Bool, installed: Bool, language: String?, droplineSelected: Bool, model: ForkSenseVoiceLoader.State) -> Bool {
        !droplineSelected && model != .failed && skipReason(enabled: enabled, installed: installed, language: language) == nil
    }

    /// The app's Apple Speech engine getting ready (`AppleSpeechTranscriber.prepare`, at launch and
    /// when the language or engine changes): where SenseVoice reads the app's dictations, SenseVoice
    /// loads instead of Apple's model (`apple` `not-prepared`), and a dictation that falls back loads
    /// Apple's as its analyzer starts. Elsewhere Apple's model loads now, as before.
    static func prepareToAnalyze(_ analyzer: SpeechAnalyzer, language: String) async throws {
        guard readsAppDictations(
            enabled: isEnabled,
            installed: isInstalled,
            language: language,
            droplineSelected: ForkDroplineSettings().isSelected,
            model: ForkSenseVoiceLoader.state
        ) else {
            try await analyzer.prepareToAnalyze(in: nil)
            return
        }
        note(Record(event: "apple", detail: "not-prepared"))
        prewarm()
    }
}

extension ForkSenseVoiceLiveWords {
    /// The keyboard's live words when SenseVoice writes the dictation (the fork's hook in
    /// `KeyboardLiveDictation.resolve`, before Apple's model is looked up): SenseVoice's own
    /// (`source`), or none where only the read to come has room (`live` `memory`), so no Apple
    /// recogniser runs for the words alone. False where SenseVoice won't write it: off, another
    /// language, not loaded in this keyboard, or no room for any read, so the dictation falls back
    /// to Apple and the keyboard's other live words run as before.
    static func take(language: String?, sampleRate: Double, attach: @MainActor (any LiveTranscriptSource) -> Void, giveUp: @MainActor (String) -> Void) -> Bool {
        if let source = source(language: language, sampleRate: sampleRate) {
            attach(source)
            return true
        }
        let applies = ForkSenseVoice.skipReason(enabled: ForkSenseVoice.isEnabled, installed: ForkSenseVoice.isInstalled, language: language) == nil
        let roomToRead = ForkSenseVoiceBudget.allowsRead(footprint: ForkSenseVoiceBudget.footprint(), available: Int(os_proc_available_memory()), audioSeconds: 0)
        guard leavesAppleOut(applies: applies, model: ForkSenseVoiceLoader.state, roomToRead: roomToRead) else { return false }
        Task.detached(priority: .utility) { ForkSenseVoice.note(ForkSenseVoice.Record(event: "live", detail: "memory")) }
        giveUp("SenseVoice writes this dictation, without room for its live words")
        return true
    }

    /// Whether the keyboard's live words leave Apple's recognisers out once SenseVoice's own couldn't
    /// start: while SenseVoice's model is loaded here and the keyboard has room for a read at all, so
    /// SenseVoice can still read the dictation (`ForkSenseVoice.fallbackReason`). A keyboard without
    /// that room now has less once it has recorded, and its dictation falls back as `memory`.
    static func leavesAppleOut(applies: Bool, model: ForkSenseVoiceLoader.State, roomToRead: Bool) -> Bool {
        applies && model == .loaded && roomToRead
    }
}
