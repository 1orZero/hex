import Foundation

/// Labs › SenseVoice（中文） in the keyboard (fork), run as `KeyboardParakeet` runs Parakeet: loaded
/// from the App Group after the keyboard's first frame and launch work (`warmUp`, beside Parakeet's
/// in `KeyboardViewController.scheduleLaunchWork`), off the main thread, where
/// `ForkSenseVoiceKeyboard.decide` allows it, and kept while the keyboard's process lives, until a
/// memory warning (`handleMemoryWarning`, beside Parakeet's in `KeyboardLocalDictation`), after
/// which nothing loads for `KeyboardParakeet.reloadAfterWarning`. Never beside Parakeet: where
/// Parakeet's plan picks a model or this process holds one, SenseVoice doesn't load, and one loaded
/// goes. A dictation never waits for it: until it has loaded, `ForkSenseVoice.transcribe` leaves
/// the dictation to three-language dictation and Apple's speech recognition. What it did goes to
/// the App Group for the Labs card (`ForkSenseVoiceKeyboardStatus`), and each decision not to load
/// to `fork-sensevoice.json` as `keyboard`.
@MainActor
final class ForkKeyboardSenseVoice {
    static let shared = ForkKeyboardSenseVoice()

    private var loadTask: Task<Void, Never>?
    /// No Neural Engine, or SenseVoice didn't run on it: not loaded again in this process.
    private var setAside = false
    private var memoryWarnedAt: Date?
    private var lastNote = ""

    /// `memoryWarned`: iOS warned the keyboard's view controller about memory since it opened.
    func warmUp(memoryWarned: Bool) {
        let memory = KeyboardParakeet.memory()
        let status = ForkSenseVoiceKeyboardStatus()
        let decision = ForkSenseVoiceKeyboard.decide(
            applies: ForkSenseVoice.skipReason(
                enabled: ForkSenseVoice.isEnabled,
                installed: ForkSenseVoice.isInstalled,
                language: ForkSenseVoice.dictationLanguage
            ) == nil,
            droplineSelected: ForkDroplineSettings().isSelected,
            parakeet: KeyboardParakeet.choice() != nil || KeyboardParakeet.shared.holdsModel,
            model: ForkSenseVoiceLoader.state,
            loading: loadTask != nil,
            setAside: setAside,
            memoryWarned: memoryWarned
                || memoryWarnedAt.map { Date().timeIntervalSince($0) < KeyboardParakeet.reloadAfterWarning } == true,
            footprint: memory.footprint,
            available: memory.available,
            hasNeuralEngine: ForkSenseVoice.hasNeuralEngine
        )
        switch decision {
        case .leave:
            return
        case .release(let reason):
            release(reason)
        case .keep:
            if status.state?.state != .ready { status.set(.ready) }
        case .tooSmall(let limit):
            note("too-small", "limit \(Self.mb(limit)) MB, needs \(Self.mb(ForkSenseVoiceBudget.requiredLimit)) MB")
        case .unavailable(let reason, let free):
            if reason == .noNeuralEngine { setAside = true }
            let needs = free.map { ": \(Self.mb($0)) MB free, needs \(Self.mb(ForkSenseVoiceBudget.loadHeadroom)) MB" } ?? ""
            note(reason.rawValue, reason.rawValue + needs)
            status.set(.unavailable, reason: reason, free: free)
        case .load:
            load(neuralBefore: memory.neural)
        }
    }

    /// iOS warned the keyboard about memory: the model goes (a read under way keeps it until it
    /// ends), and no new load starts in this process for `KeyboardParakeet.reloadAfterWarning`.
    func handleMemoryWarning() {
        memoryWarnedAt = Date()
        release("memory warning")
    }

    private func load(neuralBefore: Int) {
        let status = ForkSenseVoiceKeyboardStatus()
        status.set(.preparing)
        loadTask = Task { [weak self] in
            let loaded: Bool
            do {
                _ = try await ForkSenseVoiceLoader.shared.engine()
                loaded = true
            } catch {
                loaded = false
            }
            let after = KeyboardParakeet.memory()
            guard let self else { return }
            self.loadTask = nil
            guard loaded else {
                status.set(.unavailable, reason: .loadFailed)
                return
            }
            // A memory warning while it loaded: the loader didn't keep it.
            guard ForkSenseVoiceLoader.state == .loaded else { return }
            // From iOS 27 the Neural Engine's memory is the process's to read; before, Core ML's
            // `.cpuAndNeuralEngine` on a device that lists a Neural Engine stands.
            if after.neural > 0, after.neural - neuralBefore < KeyboardParakeet.neuralEngineEvidence {
                self.setAside = true
                status.set(.unavailable, reason: .notOnNeuralEngine)
                self.release("not on the Neural Engine", clearsStatus: false)
                return
            }
            status.set(.ready)
        }
    }

    private func release(_ reason: String, clearsStatus: Bool = true) {
        Task.detached(priority: .utility) {
            guard await ForkSenseVoiceLoader.shared.release() else { return }
            ForkSenseVoice.note(ForkSenseVoice.Record(event: "released", detail: reason))
            if clearsStatus { ForkSenseVoiceKeyboardStatus().set(nil) }
        }
    }

    /// Logged once per `key` in a row, so a keyboard short of memory at every open doesn't push
    /// the dictations out of the log's 50 records.
    private func note(_ key: String, _ detail: String) {
        guard key != lastNote else { return }
        lastNote = key
        Task.detached(priority: .utility) { ForkSenseVoice.note(ForkSenseVoice.Record(event: "keyboard", detail: detail)) }
    }

    private static func mb(_ bytes: Int) -> Int { bytes / ForkSenseVoiceBudget.megabyte }
}
