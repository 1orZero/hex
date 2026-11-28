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
/// (too long, short of memory, a load or read error, no text), Apple's own path transcribes the
/// same recording. The keyboard's live words come from SenseVoice too
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

    /// Whether reading `audio` seconds fits in `available` bytes (0: no limit, as in the
    /// simulator): the samples, the largest piece's padded encoder input, and its fp16 logits,
    /// 2 bytes for each of the 25,055 tokens in every frame, plus a margin.
    static func fits(audio: TimeInterval, available: Int) -> Bool {
        guard available > 0 else { return true }
        let piece = min(audio, ForkSenseVoiceSegments.longestPiece)
        let bucket = SenseVoiceConfig.pickBucket(forFrames: Int((piece / 0.06).rounded(.up)))
        let logits = (bucket + SenseVoiceConfig.numQueryTokens) * ForkSenseVoiceEngine.vocabularySize * 2
        let input = bucket * SenseVoiceConfig.featureDim * 4 * 2 + Int(audio * Double(ForkSenseVoiceEngine.sampleRate)) * 4 * 2
        return available >= logits + input + 24 * 1_048_576
    }

    static var dictationLanguage: String? {
        LanguageSettings().effectiveDictationLanguage ?? Locale.preferredLanguages.first
    }

    /// The dictation's text from SenseVoice, or nil for the caller's own engine: SenseVoice
    /// doesn't apply, or it failed or heard nothing, logged with why.
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
            guard length <= longestAudio else {
                note(Record(event: "fallback", detail: "too-long", audio: length))
                return nil
            }
            guard fits(audio: length, available: Int(os_proc_available_memory())) else {
                note(Record(event: "fallback", detail: "memory", audio: length, memory: peak.megabytes))
                return nil
            }
            let samples = try AudioConverter(sampleRate: Double(ForkSenseVoiceEngine.sampleRate)).resampleAudioFile(url)
            let (engine, load) = try await ForkSenseVoiceLoader.shared.engine()
            let reading = try await engine.readWhole(samples, dictationLanguage: dictationLanguage)
            let seconds = (ContinuousClock.now - started) / .seconds(1)
            guard !reading.text.isEmpty else {
                note(Record(event: "fallback", detail: "empty", language: reading.language, audio: audio, seconds: seconds, load: load, memory: peak.megabytes))
                return nil
            }
            note(Record(event: "transcribed", detail: engineName, language: reading.language, audio: audio, seconds: seconds, load: load, memory: peak.megabytes))
            return reading.text
        } catch {
            let ns = error as NSError
            note(Record(event: "fallback", detail: "error \(ns.domain) \(ns.code)", audio: audio, memory: peak.megabytes))
            return nil
        }
    }

    /// Starts loading the model as a dictation starts, when SenseVoice would read it and the
    /// process has room for its longest piece.
    static func prewarm() {
        guard isEnabled, skipReason(enabled: true, installed: isInstalled, language: dictationLanguage) == nil,
              fits(audio: ForkSenseVoiceSegments.longestPiece, available: Int(os_proc_available_memory())) else { return }
        Task.detached(priority: .userInitiated) { _ = try? await ForkSenseVoiceLoader.shared.engine() }
    }

    private static let log = Logger(subsystem: "anomaly.hex.mobile", category: "fork-sensevoice")

    static func note(_ record: Record) {
        log.notice("sensevoice \(record.event, privacy: .public) \(record.detail, privacy: .public) language=\(record.language ?? "", privacy: .public) audio=\(record.audio ?? 0, privacy: .public) seconds=\(record.seconds ?? 0, privacy: .public) load=\(record.load ?? 0, privacy: .public) memory=\(record.memory ?? 0, privacy: .public)")
        Record.append(record)
    }

    /// One SenseVoice decision, the newest `limit` kept in the App Group's
    /// `Library/fork-sensevoice.json` to read off the iPhone later. Never the transcript.
    struct Record: Codable, Equatable, Sendable {
        /// `transcribed`, `fallback`, `skipped`, `live` (one keyboard dictation's live words),
        /// `downloaded`, or `download-failed`.
        var event: String
        /// The engine, why the dictation fell back or skipped SenseVoice, or what the download did.
        var detail: String
        /// The language SenseVoice detected.
        var language: String?
        /// Seconds of audio.
        var audio: Double?
        /// Seconds from the recording to the text, a load included; for `live`, the longest round.
        var seconds: Double?
        /// Seconds this dictation waited for the model to load, when it did.
        var load: Double?
        /// The process's highest footprint while SenseVoice ran, in MB.
        var memory: Double?
        var at = Date()
        var process = Bundle.main.bundleURL.pathExtension == "appex" ? "keyboard" : "app"

        static let limit = 50

        init(event: String, detail: String, language: String? = nil, audio: Double? = nil, seconds: Double? = nil, load: Double? = nil, memory: Double? = nil) {
            self.event = event
            self.detail = detail
            self.language = language
            self.audio = audio.map { ($0 * 100).rounded() / 100 }
            self.seconds = seconds.map { ($0 * 100).rounded() / 100 }
            self.load = load.map { ($0 * 100).rounded() / 100 }
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

/// Loads SenseVoice once per process (the app, or the keyboard), on first use or when a
/// dictation starts. A load that fails isn't tried again in that process.
actor ForkSenseVoiceLoader {
    static let shared = ForkSenseVoiceLoader()

    private var loaded: ForkSenseVoiceEngine?
    private var loading: Task<ForkSenseVoiceEngine, any Error>?
    private var failed: (any Error)?

    /// Whether a load failed in this process, read without waiting for the loader.
    nonisolated static var hasFailed: Bool { failedOnce.withLock { $0 } }
    private static let failedOnce = OSAllocatedUnfairLock(initialState: false)

    /// The engine, and the seconds this call waited for it to load (nil when it was loaded).
    func engine() async throws -> (ForkSenseVoiceEngine, TimeInterval?) {
        if let loaded { return (loaded, nil) }
        if let failed { throw failed }
        let started = ContinuousClock.now
        let task = loading ?? Task.detached(priority: .userInitiated) {
            try ForkSenseVoiceEngine(directory: ForkSenseVoice.directory)
        }
        loading = task
        do {
            let engine = try await task.value
            loaded = engine
            loading = nil
            return (engine, (ContinuousClock.now - started) / .seconds(1))
        } catch {
            failed = error
            loading = nil
            Self.failedOnce.withLock { $0 = true }
            throw error
        }
    }
}
