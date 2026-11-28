import Darwin
import Foundation

/// How much memory SenseVoice needs in the keyboard, in `KeyboardParakeetBudget`'s terms and from its
/// numbers where they carry over. SenseVoice's own number is its resident footprint, measured on a Mac
/// (`residentFootprint`); the Neural Engine's copy of the model (537 MB there) is outside the
/// footprint iOS limits, as Parakeet's is. So:
/// - The keyboard records at up to 109 MB with SenseVoice loaded: Parakeet's 91 MB with Parakeet's
///   42 MB load rise taken out and SenseVoice's 60 MB put in (`recordingFootprint`).
/// - A keyboard needs a limit of that, a read's rise (Parakeet's 16 MB transcription rise, above
///   SenseVoice's largest piece's 13 MB of logits and 1 MB of input) and Parakeet's 24 MB margin:
///   149 MB (`requiredLimit`). That leaves 40 MB above the recording, more than the 32 MB the
///   keyboard's next dictation needs to start (`startHeadroom`).
/// - It loads with as much left as SenseVoice keeps once it has read, and the start headroom after
///   that (`loadHeadroom`, 92 MB). Each read needs what a Parakeet transcription needs
///   (`KeyboardParakeetBudget.transcribeHeadroom`: 24 MB and 0.5 MB a second, since FluidAudio's
///   converter holds the recording for both), which a 149 MB keyboard has at the recording footprint
///   for up to 32 s of audio; the logits a read keeps are in the 60 MB already. Short of either, the
///   dictation goes to three-language dictation and Apple's speech recognition.
nonisolated enum ForkSenseVoiceBudget {
    static let megabyte = KeyboardParakeetBudget.megabyte
    /// SenseVoice's share of a footprint once it has loaded and read, measured on a Mac: 28 MB from
    /// the load, which Core ML keeps even after the engine goes, and 20 MB of logits for the 128- and
    /// 256-frame buckets a dictation reads into (`ForkSenseVoiceEngine`); 48–59 MB in all after 2 to
    /// 120 reads of 1–15 s, counted at 60.
    static let residentFootprint = 60 * megabyte
    /// Left free for the keyboard's next dictation to start (`KeyboardLocalDictation.startHeadroomNeeded`).
    static let startHeadroom = 32 * megabyte

    static var recordingFootprint: Int {
        KeyboardParakeetBudget.recordingFootprint - KeyboardParakeetBudget.loadRise + residentFootprint
    }
    static var requiredLimit: Int {
        recordingFootprint + KeyboardParakeetBudget.transcriptionRise + KeyboardParakeetBudget.margin
    }
    static var loadHeadroom: Int { residentFootprint + startHeadroom }

    /// Whether a process with `footprint` and `available` (bytes) may load SenseVoice.
    /// `available` 0 is a process iOS sets no limit for (the simulator): it may.
    static func allowsLoad(footprint: Int, available: Int) -> Bool {
        guard available > 0 else { return true }
        return footprint + available >= requiredLimit && available >= loadHeadroom
    }

    /// Whether SenseVoice may read `audioSeconds` of audio now.
    static func allowsRead(footprint: Int, available: Int, audioSeconds: Double) -> Bool {
        guard available > 0 else { return true }
        return footprint + available >= requiredLimit
            && available >= KeyboardParakeetBudget.transcribeHeadroom(audioSeconds: audioSeconds)
    }

    /// This process's physical footprint, the number iOS holds against its limit.
    static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }
}

/// What the keyboard last did with SenseVoice, in the App Group for the Labs card, as
/// `KeyboardParakeetSettings.keyboardState` is for Parakeet's row (`ForkKeyboardSenseVoice` writes it).
nonisolated struct ForkSenseVoiceKeyboardStatus {
    static let stateKey = "fork.senseVoice.keyboardState"
    static let stateAtKey = "fork.senseVoice.keyboardStateAt"
    static let reasonKey = "fork.senseVoice.keyboardStateReason"
    /// With `shortOfMemory` from the budget check: what was free then (bytes).
    static let freeKey = "fork.senseVoice.keyboardStateFree"

    typealias State = KeyboardParakeetSettings.KeyboardState
    typealias Reason = KeyboardParakeetSettings.UnavailableReason

    private let defaults: UserDefaults?

    init(defaults: UserDefaults? = UserDefaults(suiteName: KeyboardBridge.appGroup)) {
        self.defaults = defaults
    }

    var state: (state: State, at: Date)? {
        guard let raw = defaults?.string(forKey: Self.stateKey), let state = State(rawValue: raw) else { return nil }
        return (state, Date(timeIntervalSince1970: defaults?.double(forKey: Self.stateAtKey) ?? 0))
    }

    /// Why the keyboard last said `.unavailable`; nil for any other state.
    var reason: Reason? {
        guard state?.state == .unavailable, let raw = defaults?.string(forKey: Self.reasonKey) else { return nil }
        return Reason(rawValue: raw)
    }

    /// What was free when the keyboard last said it was short of memory (bytes), where it measured it.
    var free: Int? {
        guard reason == .shortOfMemory, let free = defaults?.object(forKey: Self.freeKey) as? Int, free > 0 else { return nil }
        return free
    }

    /// The reason and what was free go in before the state, so the app never reads `.unavailable`
    /// without them.
    func set(_ state: State?, reason: Reason? = nil, free: Int? = nil, now: Date = Date()) {
        if state == .unavailable, let reason {
            defaults?.set(reason.rawValue, forKey: Self.reasonKey)
        } else {
            defaults?.removeObject(forKey: Self.reasonKey)
        }
        if state == .unavailable, reason == .shortOfMemory, let free, free > 0 {
            defaults?.set(free, forKey: Self.freeKey)
        } else {
            defaults?.removeObject(forKey: Self.freeKey)
        }
        defaults?.set(state?.rawValue, forKey: Self.stateKey)
        defaults?.set(now.timeIntervalSince1970, forKey: Self.stateAtKey)
    }
}

/// What the keyboard does with SenseVoice each time it opens (`ForkKeyboardSenseVoice.warmUp`), in
/// `KeyboardParakeet.warmUp`'s order. Parakeet's claim on the keyboard is checked before anything
/// of SenseVoice's, so the keyboard never holds both models.
nonisolated enum ForkSenseVoiceKeyboard {
    enum Decision: Equatable {
        /// Nothing to do: Dropline is selected (a model already loaded stays, for its fallback), a load
        /// is under way, or this process set SenseVoice aside.
        case leave
        /// Let a loaded or loading model go: SenseVoice no longer reads the keyboard's dictation, or
        /// Parakeet takes it.
        case release(String)
        case keep
        /// The keyboard's limit is under `ForkSenseVoiceBudget.requiredLimit`: nothing loads, and the
        /// Labs card says so from the limit the keyboard recorded.
        case tooSmall(limit: Int)
        case unavailable(KeyboardParakeetSettings.UnavailableReason, free: Int?)
        case load
    }

    /// - Parameters:
    ///   - applies: SenseVoice reads this keyboard's dictation (`ForkSenseVoice.skipReason` is nil).
    ///   - parakeet: Parakeet's plan picks a model for the keyboard, or this process holds one.
    ///   - loading: this process is loading SenseVoice.
    ///   - setAside: SenseVoice didn't run on the Neural Engine, or there's none, in this process.
    ///   - memoryWarned: iOS warned this keyboard about memory, within `KeyboardParakeet.reloadAfterWarning`.
    static func decide(
        applies: Bool,
        droplineSelected: Bool,
        parakeet: Bool,
        model: ForkSenseVoiceLoader.State,
        loading: Bool,
        setAside: Bool,
        memoryWarned: Bool,
        footprint: Int,
        available: Int,
        hasNeuralEngine: Bool
    ) -> Decision {
        if droplineSelected { return .leave }
        let holds = model == .loaded || loading
        guard applies else { return holds ? .release("off") : .leave }
        if parakeet { return holds ? .release("parakeet") : .leave }
        if model == .loaded { return .keep }
        if loading || setAside || model == .failed { return .leave }
        if memoryWarned { return .unavailable(.shortOfMemory, free: nil) }
        if available > 0, footprint + available < ForkSenseVoiceBudget.requiredLimit {
            return .tooSmall(limit: footprint + available)
        }
        guard ForkSenseVoiceBudget.allowsLoad(footprint: footprint, available: available) else {
            return .unavailable(.shortOfMemory, free: available)
        }
        guard hasNeuralEngine else { return .unavailable(.noNeuralEngine, free: nil) }
        return .load
    }
}
