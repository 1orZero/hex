import CoreML
import Foundation
import os

/// Where the keyboard's live words come from while SenseVoice writes the dictation (the fork's
/// hook in `KeyboardLiveDictation.resolve`): SenseVoice itself, so no Apple recogniser runs
/// while recording. Nil where SenseVoice won't write this dictation (`ForkSenseVoice.skipReason`),
/// it failed to load earlier in this keyboard, the keyboard lacks room for a round, there's no
/// Neural Engine (a round took up to 1 s on a Mac's CPU, as in the simulator, against 0.1 s on its
/// Neural Engine), or the capture's rate can't be converted, and the keyboard's own live words run
/// as before.
@MainActor
enum ForkSenseVoiceLiveWords {
    static func source(language: String?, sampleRate: Double) -> ForkSenseVoiceLiveTranscriber? {
        guard ForkSenseVoice.isEnabled,
              ForkSenseVoice.skipReason(enabled: true, installed: ForkSenseVoice.isInstalled, language: language) == nil,
              !ForkSenseVoiceLoader.hasFailed,
              ForkSenseVoice.fits(audio: ForkSenseVoiceSegments.longestPiece, available: Int(os_proc_available_memory())),
              MLModel.availableComputeDevices.contains(where: { device in
                  if case .neuralEngine = device { return true }
                  return false
              }) else { return nil }
        let source = ForkSenseVoiceLiveTranscriber(sampleRate: sampleRate, dictationLanguage: language) { round, tail in
            let (engine, _) = try await ForkSenseVoiceLoader.shared.engine()
            return try await ForkSenseVoiceLive.read(round, tail: tail, engine: engine)
        }
        return source.canRead ? source : nil
    }
}

/// Live words from SenseVoice: every `ForkSenseVoiceSegments.interval` of audio, the recording
/// after its last settled stretch is read (`ForkSenseVoiceLive`), in the dictation's spelling.
/// A round whose time comes while the last one is still reading is skipped, so SenseVoice reads
/// one thing at a time. Past `ForkSenseVoice.longestAudio` no round starts and the last words
/// stay; a load or read error ends the rounds and the live words (`onFailure`). The inserted text is SenseVoice's
/// reading of the whole recording once it stops (`ForkSenseVoice.transcribe`).
@MainActor
final class ForkSenseVoiceLiveTranscriber: LiveTranscriptSource {
    typealias Read = @Sendable (ForkSenseVoiceLive.Round, [Float]) async throws -> ForkSenseVoiceLive.Result

    var onUpdate: ((LiveTranscript) -> Void)?
    var onFailure: ((String) -> Void)?
    /// Rounds read, rounds skipped while one was reading, and the longest round, for the log and tests.
    private(set) var rounds = 0
    private(set) var skipped = 0
    private(set) var longestRound: TimeInterval = 0

    private let read: Read
    private let resampler: ForkDroplineResampler?
    /// Whether the capture's rate converts to 16 kHz.
    let canRead: Bool
    private var live: ForkSenseVoiceLive
    private var samples: [Float] = []
    private var nextRound = 1
    private var inFlight: Task<Void, Never>?
    private var stopped = false
    private var failed = false

    private static let log = Logger(subsystem: "anomaly.hex.mobile", category: "fork-sensevoice")
    private static var rate: Double { Double(ForkSenseVoiceSegments.sampleRate) }

    /// `sampleRate`: the capture's 16-bit mono chunks, read at 16 kHz.
    init(sampleRate: Double, dictationLanguage: String?, read: @escaping Read) {
        self.read = read
        live = ForkSenseVoiceLive(dictationLanguage: dictationLanguage)
        resampler = sampleRate == Self.rate ? nil : ForkDroplineResampler(from: sampleRate)
        canRead = sampleRate == Self.rate || resampler != nil
    }

    func append(_ pcm: Data) {
        guard !stopped, !failed, canRead, pcm.count >= 2, Double(samples.count) <= ForkSenseVoice.longestAudio * Self.rate else { return }
        let chunk = resampler.map { $0.convert(pcm) } ?? Self.int16(pcm)
        samples.append(contentsOf: chunk.map { Float($0) / 32_768 })
        let due = Int(Double(samples.count) / (ForkSenseVoiceSegments.interval * Self.rate))
        guard due >= nextRound else { return }
        nextRound = due + 1
        guard inFlight == nil else {
            skipped += 1
            return
        }
        start()
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        onUpdate = nil
        inFlight?.cancel()
        inFlight = nil
        let record = ForkSenseVoice.Record(
            event: "live",
            detail: "\(rounds) rounds, \(skipped) skipped",
            language: live.language,
            audio: Double(samples.count) / Self.rate,
            seconds: longestRound
        )
        samples = []
        Task.detached(priority: .utility) { ForkSenseVoice.note(record) }
    }

    private func start() {
        let round = live.round(samples[...], end: samples.count)
        let tail = Array(samples[round.start..<round.end])
        let read = read
        rounds += 1
        inFlight = Task { [weak self] in
            let started = ContinuousClock.now
            let result: Result<ForkSenseVoiceLive.Result, Error>
            do {
                result = .success(try await read(round, tail))
            } catch {
                result = .failure(error)
            }
            self?.finished(result, of: round, seconds: (ContinuousClock.now - started) / .seconds(1))
        }
    }

    private func finished(_ result: Result<ForkSenseVoiceLive.Result, Error>, of round: ForkSenseVoiceLive.Round, seconds: TimeInterval) {
        guard !stopped else { return }
        inFlight = nil
        longestRound = max(longestRound, seconds)
        switch result {
        case .success(let reading):
            onUpdate?(live.apply(reading, of: round))
        case .failure(let error):
            guard !(error is CancellationError) else { return }
            let ns = error as NSError
            Self.log.error("SenseVoice live: read failed (\(ns.domain, privacy: .public) \(ns.code))")
            failed = true
            onFailure?("SenseVoice failed (\(ns.domain) \(ns.code))")
        }
    }

    private static func int16(_ pcm: Data) -> [Int16] {
        var out = [Int16](repeating: 0, count: pcm.count / 2)
        _ = out.withUnsafeMutableBufferPointer { pcm.copyBytes(to: $0) }
        return out
    }
}
