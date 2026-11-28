import AVFAudio
import Darwin
import FluidAudio
import Foundation
import os
import OSLog

/// Labs › SenseVoice（中文） (fork): while it is on, its model is downloaded, and the dictation
/// language is English, Mandarin, or Cantonese, SenseVoice-Small (`ForkSenseVoiceEngine`) writes
/// the final text of dictations Apple's speech recognition would transcribe, in the app
/// (`AppleSpeechTranscriber`) and in the keyboard (`KeyboardSpeech`). It tells Mandarin,
/// Cantonese, and English apart itself, so Apple's three readings don't run. When it can't
/// (too long, short of memory, the model not loaded yet, a load or read error, too little text)
/// or hears English, Apple's own path transcribes the same recording. The keyboard's live words come from SenseVoice too
/// (`ForkSenseVoiceLiveWords`).
nonisolated enum ForkSenseVoice {
    static let enabledKey = "fork.senseVoice.enabled"
    static let engineName = "SenseVoice-Small"
    /// Longer recordings go to the caller's engine: SenseVoice reads them in 15 s pieces
    /// (`ForkSenseVoiceSegments.pieces`) and holds every sample at once.
    static let longestAudio: TimeInterval = 120

    static var isEnabled: Bool {
        get { UserDefaults(suiteName: KeyboardBridge.appGroup)?.bool(forKey: enabledKey) ?? false }
        set { UserDefaults(suiteName: KeyboardBridge.appGroup)?.set(newValue, forKey: enabledKey) }
    }

    /// FluidAudio's folder name under Hex's `SpeechModelStore.root`, in the App Group.
    static var directory: URL {
        SpeechModelStore.root.appendingPathComponent(Repo.senseVoiceSmall.folderName, isDirectory: true)
    }

    static var isInstalled: Bool {
        SpeechModelStore.isComplete(directory) && SenseVoiceModels.modelsExist(at: directory, precision: .fp16)
    }

    /// English, Mandarin, or Cantonese in any region.
    static func covers(_ language: String?) -> Bool {
        guard let language, let code = Locale(identifier: language).language.languageCode?.identifier else { return false }
        return ["en", "zh", "yue"].contains(code)
    }

    /// Why SenseVoice doesn't read a dictation, or nil when it does.
    static func skipReason(enabled: Bool, installed: Bool, language: String?) -> String? {
        guard enabled else { return "lab-off" }
        guard installed else { return "not-installed" }
        guard covers(language) else { return "language=\(language ?? "none")" }
        return nil
    }

    private static let megabyte = 1_048_576
    /// SenseVoice's share of a process's footprint while it's loaded, measured on a Mac: 28 MB
    /// from the first load, which Core ML keeps even after the engine goes, and 20 MB of logits
    /// for the 128- and 256-frame buckets a dictation reads into (`ForkSenseVoiceEngine`); 48–59 MB
    /// in all after 2 to 120 reads of 1–15 s. The Neural Engine's copy of the model (537 MB) is
    /// outside the footprint iOS limits, as Parakeet's is (`KeyboardParakeetBudget`).
    static let residentFootprint = 60 * megabyte
    /// Left free beside SenseVoice for the keyboard's next dictation to start
    /// (`KeyboardLocalDictation.startHeadroomNeeded`).
    static let keepFree = 32 * megabyte
    /// What a recording adds while it runs (its capture, recording screen, and live words), with
    /// margin, kept too when SenseVoice loads as one starts.
    static let recordingRise = 24 * megabyte

    /// Whether SenseVoice has room to read `audio` seconds in a process with `available` bytes
    /// left (0: no limit, as in the simulator) and still leave `keepFree`: the samples, the
    /// largest piece's padded encoder input, and either its fp16 logits (2 bytes for each of the
    /// 25,055 tokens in every frame) when the model is `loaded`, or its whole resident footprint
    /// and a recording's rise when it isn't.
    static func fits(audio: TimeInterval, available: Int, loaded: Bool) -> Bool {
        guard available > 0 else { return true }
        let piece = min(audio, ForkSenseVoiceSegments.longestPiece)
        let bucket = SenseVoiceConfig.pickBucket(forFrames: Int((piece / 0.06).rounded(.up)))
        let logits = (bucket + SenseVoiceConfig.numQueryTokens) * ForkSenseVoiceEngine.vocabularySize * 2
        let input = bucket * SenseVoiceConfig.featureDim * 4 * 2 + Int(audio * Double(ForkSenseVoiceEngine.sampleRate)) * 4 * 2
        return available >= input + (loaded ? logits : residentFootprint + recordingRise) + keepFree
    }

    /// Whether a process should let the engine go after a read: one with less than its next
    /// dictation's start and recording need left (`keepFree`, `recordingRise`), as a keyboard
    /// whose footprint grew. Not where iOS sets no limit (0).
    static func releases(available: Int) -> Bool {
        available > 0 && available < keepFree + recordingRise
    }

    /// Why a dictation SenseVoice would read goes to the caller's engine, or nil when SenseVoice
    /// reads it: too long, a model that failed to load in this process, no room (`fits`), or a
    /// model that hasn't loaded yet (a dictation never waits for it).
    static func fallbackReason(audio: TimeInterval, available: Int, model: ForkSenseVoiceLoader.State) -> String? {
        guard audio <= longestAudio else { return "too-long" }
        switch model {
        case .failed: return "load-failed"
        case .loaded: return fits(audio: audio, available: available, loaded: true) ? nil : "memory"
        case .notLoaded: return fits(audio: audio, available: available, loaded: false) ? "loading" : "memory"
        }
    }

    /// From this length on, SenseVoice's text needs a letter or digit for each second of audio.
    static let sparseAfter: TimeInterval = 3

    /// Why SenseVoice's text of `audio` seconds in `language` goes unused, or nil when it's used:
    /// none; English, since short Cantonese with English words often reads as English gibberish
    /// and Apple's three-language dictation writes English as well; or too little for the
    /// recording, as when 4 s of Cantonese with English words came back as "tix.".
    static func textReason(_ text: String, language: String, audio: TimeInterval) -> String? {
        let letters = text.filter { $0.isLetter || $0.isNumber }.count
        if letters == 0 { return "empty" }
        if language == "en" { return "english" }
        if audio >= sparseAfter, Double(letters) < audio { return "sparse" }
        return nil
    }

    static var dictationLanguage: String? {
        LanguageSettings().effectiveDictationLanguage ?? Locale.preferredLanguages.first
    }

    /// The dictation's text from SenseVoice, or nil for the caller's own engine: SenseVoice
    /// doesn't apply, isn't loaded yet, failed, heard too little, or heard English, logged with why.
    static func transcribe(_ url: URL, dictationLanguage: String?) async -> String? {
        let enabled = isEnabled
        if let reason = skipReason(enabled: enabled, installed: isInstalled, language: dictationLanguage) {
            if enabled { note(Record(event: "skipped", detail: reason)) }
            return nil
        }
        let started = ContinuousClock.now
        let peak = PeakFootprint()
        defer { peak.stop() }
        var audio: TimeInterval?
        do {
            let file = try AVAudioFile(forReading: url)
            let length = Double(file.length) / file.fileFormat.sampleRate
            audio = length
            if let reason = fallbackReason(audio: length, available: Int(os_proc_available_memory()), model: ForkSenseVoiceLoader.state) {
                if reason == "loading" { ForkSenseVoiceLoader.load() }
                note(Record(event: "fallback", detail: reason, audio: length, memory: peak.megabytes))
                if reason == "memory" { await releaseIfShort() }
                return nil
            }
            let samples = try AudioConverter(sampleRate: Double(ForkSenseVoiceEngine.sampleRate)).resampleAudioFile(url)
            let engine = try await ForkSenseVoiceLoader.shared.engine()
            let reading = try await engine.readWhole(samples, dictationLanguage: dictationLanguage)
            let seconds = (ContinuousClock.now - started) / .seconds(1)
            await releaseIfShort()
            if let reason = textReason(reading.text, language: reading.language, audio: length) {
                note(Record(event: "fallback", detail: reason, language: reading.language, audio: length, seconds: seconds, memory: peak.megabytes))
                return nil
            }
            note(Record(event: "transcribed", detail: engineName, language: reading.language, audio: length, seconds: seconds, memory: peak.megabytes))
            return reading.text
        } catch {
            let ns = error as NSError
            note(Record(event: "fallback", detail: "error \(ns.domain) \(ns.code)", audio: audio, memory: peak.megabytes))
            await releaseIfShort()
            return nil
        }
    }

    /// Lets the engine go where the process is short of room for its next dictation (`releases`),
    /// after a read or a dictation it had no room for, which gives back its logits; a later
    /// dictation loads it again if there's room by then.
    private static func releaseIfShort() async {
        let available = Int(os_proc_available_memory())
        guard releases(available: available), await ForkSenseVoiceLoader.shared.release() else { return }
        note(Record(event: "released", detail: "available \(available / megabyte) MB"))
    }

    /// Starts loading the model as a dictation starts or the download finishes, when SenseVoice
    /// would read the dictation and the process has room for its longest piece. Not while Dropline
    /// is selected: it writes the dictation first (as in `KeyboardParakeet.warmUp`), and a local
    /// fallback starts the load itself (`transcribe`).
    static func prewarm() {
        guard isEnabled, !ForkDroplineSettings().isSelected,
              skipReason(enabled: true, installed: isInstalled, language: dictationLanguage) == nil,
              fits(audio: ForkSenseVoiceSegments.longestPiece, available: Int(os_proc_available_memory()), loaded: ForkSenseVoiceLoader.state == .loaded) else { return }
        ForkSenseVoiceLoader.load()
    }

    private static let log = Logger(subsystem: "anomaly.hex.mobile", category: "fork-sensevoice")

    static func note(_ record: Record) {
        log.notice("sensevoice \(record.event, privacy: .public) \(record.detail, privacy: .public) language=\(record.language ?? "", privacy: .public) audio=\(record.audio ?? 0, privacy: .public) seconds=\(record.seconds ?? 0, privacy: .public) memory=\(record.memory ?? 0, privacy: .public)")
        Record.append(record)
    }

    /// One SenseVoice decision, the newest `limit` kept in the App Group's
    /// `Library/fork-sensevoice.json` to read off the iPhone later. Never the transcript.
    struct Record: Codable, Equatable, Sendable {
        /// `transcribed`, `fallback`, `skipped`, `live` (one keyboard dictation's live words),
        /// `loaded`, `load-failed`, or `released` (this process's model), `downloaded`, or `download-failed`.
        var event: String
        /// The engine, why the dictation fell back or skipped SenseVoice, `loading` for live words
        /// left to the keyboard's own while the model loads, or what the load or download did.
        var detail: String
        /// The language SenseVoice detected.
        var language: String?
        /// Seconds of audio.
        var audio: Double?
        /// Seconds from the recording to the text; for `live`, the longest round; for `loaded`,
        /// `load-failed`, and `downloaded`, how long that took.
        var seconds: Double?
        /// The process's highest footprint while SenseVoice ran, in MB.
        var memory: Double?
        var at = Date()
        var process = Bundle.main.bundleURL.pathExtension == "appex" ? "keyboard" : "app"

        static let limit = 50

        init(event: String, detail: String, language: String? = nil, audio: Double? = nil, seconds: Double? = nil, memory: Double? = nil) {
            self.event = event
            self.detail = detail
            self.language = language
            self.audio = audio.map { ($0 * 100).rounded() / 100 }
            self.seconds = seconds.map { ($0 * 100).rounded() / 100 }
            self.memory = memory.map { $0.rounded() }
        }

        static var url: URL? {
            FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: KeyboardBridge.appGroup)?
                .appendingPathComponent("Library/fork-sensevoice.json")
        }

        static func append(_ record: Record) {
            guard let url else { return }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let existing = (try? Data(contentsOf: url)).flatMap { try? decoder.decode([Record].self, from: $0) } ?? []
            guard let data = try? encoder.encode(Array((existing + [record]).suffix(limit))) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    /// The process's highest physical footprint while it runs, sampled every 20 ms.
    final class PeakFootprint: @unchecked Sendable {
        private let lock = NSLock()
        private var peak = 0
        private let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))

        init() {
            record()
            timer.schedule(deadline: .now(), repeating: .milliseconds(20))
            timer.setEventHandler { [weak self] in self?.record() }
            timer.resume()
        }

        var megabytes: Double {
            record()
            return lock.withLock { Double(peak) / 1_048_576 }
        }

        func stop() { timer.cancel() }

        private func record() {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            guard result == KERN_SUCCESS else { return }
            lock.withLock { peak = max(peak, Int(info.phys_footprint)) }
        }
    }
}

/// Loads SenseVoice once per process (the app, or the keyboard), when a dictation starts or the
/// download finishes. Dictations don't wait for it (`ForkSenseVoice.fallbackReason`): the first
/// load of a new build compiles the encoder for the Neural Engine, 93–101 s on a Mac, against
/// 0.1–0.2 s for later loads. A load that fails isn't tried again in that process.
actor ForkSenseVoiceLoader {
    enum State: Sendable { case notLoaded, loaded, failed }

    static let shared = ForkSenseVoiceLoader()

    private var loaded: ForkSenseVoiceEngine?
    private var loading: Task<ForkSenseVoiceEngine, any Error>?
    private var failed: (any Error)?
    /// A release asked for while a load was still running: the load's engine isn't kept.
    private var releasesOnLoad = false

    /// This process's load, read without waiting for the loader.
    nonisolated static var state: State { current.withLock { $0 } }
    private static let current = OSAllocatedUnfairLock(initialState: State.notLoaded)

    /// Starts loading in the background unless the model is loaded, loading, or failed to load.
    nonisolated static func load() {
        Task.detached(priority: .userInitiated) { _ = try? await shared.engine() }
    }

    /// Lets the loaded engine go, its logits with it (Core ML keeps about 28 MB of the first
    /// load), so the next use loads it again; one still loading isn't kept when it finishes.
    /// False when none was loaded or loading.
    func release() -> Bool {
        if loaded != nil {
            loaded = nil
            Self.current.withLock { $0 = .notLoaded }
            return true
        }
        guard loading != nil else { return false }
        releasesOnLoad = true
        return true
    }

    /// The engine, loading it first if needed. The load is logged once, `loaded` or
    /// `load-failed`, with its seconds.
    func engine() async throws -> ForkSenseVoiceEngine {
        if let loaded { return loaded }
        if let failed { throw failed }
        let task = loading ?? Task.detached(priority: .userInitiated) {
            let started = ContinuousClock.now
            do {
                let engine = try ForkSenseVoiceEngine(directory: ForkSenseVoice.directory)
                ForkSenseVoice.note(ForkSenseVoice.Record(event: "loaded", detail: ForkSenseVoice.engineName, seconds: (ContinuousClock.now - started) / .seconds(1)))
                return engine
            } catch {
                let ns = error as NSError
                ForkSenseVoice.note(ForkSenseVoice.Record(event: "load-failed", detail: "\(ns.domain) \(ns.code)", seconds: (ContinuousClock.now - started) / .seconds(1)))
                throw error
            }
        }
        loading = task
        do {
            let engine = try await task.value
            guard loading == task else { return engine }
            loading = nil
            if releasesOnLoad {
                releasesOnLoad = false
                return engine
            }
            loaded = engine
            Self.current.withLock { $0 = .loaded }
            return engine
        } catch {
            failed = error
            loading = nil
            Self.current.withLock { $0 = .failed }
            throw error
        }
    }
}
