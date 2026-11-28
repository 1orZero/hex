import AVFAudio
import CoreML
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
/// or hears English, Apple's own path transcribes the same recording. The app loads the model as a
/// dictation starts (`prewarm`); the keyboard loads it as it opens, as it loads Parakeet
/// (`ForkKeyboardSenseVoice`). The keyboard's live words come from SenseVoice too
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

    /// The keyboard's process, which loads the model only as it opens (`ForkKeyboardSenseVoice`).
    static var isKeyboard: Bool { Bundle.main.bundleURL.pathExtension == "appex" }

    static var hasNeuralEngine: Bool {
        MLModel.availableComputeDevices.contains { device in
            if case .neuralEngine = device { return true }
            return false
        }
    }

    /// Why a dictation SenseVoice would read goes to the caller's engine, or nil when SenseVoice
    /// reads it: too long, a model that failed to load in this process, no room
    /// (`ForkSenseVoiceBudget.allowsRead`), or a model that hasn't loaded yet: a dictation never
    /// waits for it. `loadsHere`: the process starts loading it then (`loading`, the app, where
    /// `ForkSenseVoiceBudget.allowsLoad`); the keyboard loads only as it opens (`not-loaded`).
    static func fallbackReason(audio: TimeInterval, footprint: Int, available: Int, model: ForkSenseVoiceLoader.State, loadsHere: Bool) -> String? {
        guard audio <= longestAudio else { return "too-long" }
        switch model {
        case .failed:
            return "load-failed"
        case .loaded:
            return ForkSenseVoiceBudget.allowsRead(footprint: footprint, available: available, audioSeconds: audio) ? nil : "memory"
        case .notLoaded:
            guard loadsHere else { return "not-loaded" }
            return ForkSenseVoiceBudget.allowsLoad(footprint: footprint, available: available) ? "loading" : "memory"
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
            let reason = fallbackReason(
                audio: length,
                footprint: ForkSenseVoiceBudget.footprint(),
                available: Int(os_proc_available_memory()),
                model: ForkSenseVoiceLoader.state,
                loadsHere: !isKeyboard
            )
            if let reason {
                if reason == "loading" { ForkSenseVoiceLoader.load() }
                note(Record(event: "fallback", detail: reason, audio: length, memory: peak.megabytes))
                return nil
            }
            // A memory warning may have let the keyboard's model go since; it isn't loaded again here.
            guard let engine = await ForkSenseVoiceLoader.shared.current() else {
                note(Record(event: "fallback", detail: "not-loaded", audio: length, memory: peak.megabytes))
                return nil
            }
            let samples = try AudioConverter(sampleRate: Double(ForkSenseVoiceEngine.sampleRate)).resampleAudioFile(url)
            let reading = try await engine.readWhole(samples, dictationLanguage: dictationLanguage)
            let seconds = (ContinuousClock.now - started) / .seconds(1)
            if let reason = textReason(reading.text, language: reading.language, audio: length) {
                note(Record(event: "fallback", detail: reason, language: reading.language, audio: length, seconds: seconds, memory: peak.megabytes))
                return nil
            }
            note(Record(event: "transcribed", detail: engineName, language: reading.language, audio: length, seconds: seconds, memory: peak.megabytes))
            return reading.text
        } catch {
            let ns = error as NSError
            note(Record(event: "fallback", detail: "error \(ns.domain) \(ns.code)", audio: audio, memory: peak.megabytes))
            return nil
        }
    }

    /// Starts loading the model in the app as a dictation starts or the download finishes, when
    /// SenseVoice would read the dictation and the app has room (`ForkSenseVoiceBudget.allowsLoad`).
    /// Not while Dropline is selected: it writes the dictation first (as in `KeyboardParakeet.warmUp`),
    /// and a local fallback starts the load itself (`transcribe`).
    static func prewarm() {
        guard isEnabled, !ForkDroplineSettings().isSelected,
              skipReason(enabled: true, installed: isInstalled, language: dictationLanguage) == nil,
              ForkSenseVoiceBudget.allowsLoad(footprint: ForkSenseVoiceBudget.footprint(), available: Int(os_proc_available_memory())) else { return }
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
        /// `loaded`, `load-failed`, or `released` (this process's model), `keyboard` (why the
        /// keyboard didn't load it as it opened), `downloaded`, or `download-failed`.
        var event: String
        /// The engine, why the dictation fell back or skipped SenseVoice, `not-loaded` for live words
        /// left to the keyboard's own while the model isn't loaded, why the keyboard didn't load or let
        /// it go, or what the load or download did.
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
        var process = ForkSenseVoice.isKeyboard ? "keyboard" : "app"

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
            let footprint = ForkSenseVoiceBudget.footprint()
            lock.withLock { peak = max(peak, footprint) }
        }
    }
}

/// Loads SenseVoice once per process: the app's when a dictation starts or the download finishes,
/// the keyboard's as it opens (`ForkKeyboardSenseVoice`). Dictations don't wait for it
/// (`ForkSenseVoice.fallbackReason`): the first load of a new build compiles the encoder for the
/// Neural Engine, 93–101 s on a Mac, against 0.1–0.2 s for later loads. A load that fails isn't
/// tried again in that process.
actor ForkSenseVoiceLoader {
    enum State: Sendable { case notLoaded, loaded, failed }
    /// A read found no engine: a memory warning let the keyboard's go.
    struct NotLoaded: Error {}

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

    /// The loaded engine, without loading it.
    func current() -> ForkSenseVoiceEngine? { loaded }

    /// Lets the loaded engine go, its logits with it (Core ML keeps about 28 MB of the first
    /// load), so the next use loads it again; one still loading isn't kept when it finishes, and
    /// a read under way keeps it until it ends. False when none was loaded or loading.
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
