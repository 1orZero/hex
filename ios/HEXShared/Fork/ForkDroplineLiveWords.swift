import AVFAudio
import Foundation
import os

/// Where the keyboard's live words come from while Dropline is selected (the fork's hook in
/// `KeyboardLiveDictation.resolve`): Dropline itself, so neither Apple's speech recognition nor
/// the speech model runs while recording. Nil while Dropline isn't selected, and the keyboard's
/// own live words run as before.
@MainActor
enum ForkDroplineLiveWords {
    static func source(
        sampleRate: Double,
        recognition: ForkDroplineRecognition = ForkDroplineRecognition(),
        hints: [String] = CustomVocabularySettings().activeTerms
    ) -> ForkDroplineLiveTranscriber? {
        guard recognition.settings.isSelected else { return nil }
        return ForkDroplineLiveTranscriber(sampleRate: sampleRate) { chunks in
            try await recognition.draft(chunks, hints: hints)
        }
    }
}

/// Live words from Dropline: every `interval` of audio the recording so far goes to Dropline
/// (`send`), and its text is what shows. Nothing shows before the first text, so the preview
/// says Listening… until then. A round whose time comes while the previous request is still out
/// is skipped. Past `longest` of audio no request goes out and the last text stays; so do
/// Dropline refusing more requests (429) and failures a later round can't get past.
@MainActor
final class ForkDroplineLiveTranscriber: LiveTranscriptSource {
    typealias Send = @Sendable ([[Int16]]) async throws -> ForkDroplineAnswer

    static let interval: TimeInterval = 4
    static let longest: TimeInterval = 180

    var onUpdate: ((LiveTranscript) -> Void)?
    var onFailure: ((String) -> Void)?
    /// Requests sent and rounds skipped while one was out, for the log and tests.
    private(set) var sent = 0
    private(set) var skipped = 0

    private let send: Send
    private let resampler: ForkDroplineResampler?
    private var chunks: [[Int16]] = []
    private var samples = 0
    private var nextRound = 1
    private var request: Task<Void, Never>?
    private var sending: Bool
    private var stopped = false

    private static let log = Logger(subsystem: "anomaly.hex.mobile", category: "fork-dropline")

    /// `sampleRate`: the capture's 16-bit mono chunks, kept at 16 kHz as Dropline gets them.
    init(sampleRate: Double, send: @escaping Send) {
        self.send = send
        resampler = sampleRate == ForkDroplineAudio.sampleRate ? nil : ForkDroplineResampler(from: sampleRate)
        sending = sampleRate == ForkDroplineAudio.sampleRate || resampler != nil
    }

    func append(_ pcm: Data) {
        guard !stopped, sending, pcm.count >= 2 else { return }
        let converted = resampler.map { $0.convert(pcm) } ?? Self.samples(of: pcm)
        guard !converted.isEmpty else { return }
        chunks.append(converted)
        samples += converted.count
        let rate = ForkDroplineAudio.sampleRate
        while Double(samples) >= Double(nextRound) * Self.interval * rate {
            let at = Double(nextRound) * Self.interval
            nextRound += 1
            guard at <= Self.longest else { break }
            guard request == nil else {
                skipped += 1
                Self.log.info("Dropline live: round at \(Int(at)) s skipped, the last request is still out")
                continue
            }
            start(at: at)
        }
        if Double(samples) > Self.longest * rate {
            stopSending("over \(Int(Self.longest)) s of audio")
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        onUpdate = nil
        request?.cancel()
        request = nil
        chunks = []
        let (sent, skipped) = (sent, skipped)
        Self.log.info("Dropline live: stopped after \(sent) requests, \(skipped) rounds skipped")
    }

    private func start(at seconds: TimeInterval) {
        sent += 1
        let audio = chunks
        let send = send
        let number = sent
        Self.log.info("Dropline live: request \(number) with \(Int(seconds)) s of audio")
        request = Task { [weak self] in
            let result: Result<ForkDroplineAnswer, Error>
            do {
                result = .success(try await send(audio))
            } catch {
                result = .failure(error)
            }
            self?.finished(result)
        }
    }

    private func finished(_ result: Result<ForkDroplineAnswer, Error>) {
        guard !stopped else { return }
        request = nil
        switch result {
        case .success(let answer):
            guard !answer.text.isEmpty else { return }
            onUpdate?(LiveTranscript(settled: answer.text))
        case .failure(let error):
            guard !(error is CancellationError) else { return }
            let failure = error as? ForkDroplineFailure ?? .network
            Self.log.error("Dropline live: request failed (\(failure.reason, privacy: .public))")
            switch failure {
            case .http(status: 429), .notConfigured, .unauthorized, .tokenEndpoint, .tooLong, .encoding:
                stopSending(failure.reason)
            case .http, .timeout, .network, .invalidResponse:
                break
            }
        }
    }

    /// No more requests for this dictation; one already out still shows its text.
    private func stopSending(_ reason: String) {
        guard sending else { return }
        sending = false
        chunks = []
        Self.log.info("Dropline live: no more requests (\(reason, privacy: .public))")
    }

    private static func samples(of pcm: Data) -> [Int16] {
        var out = [Int16](repeating: 0, count: pcm.count / 2)
        _ = out.withUnsafeMutableBufferPointer { pcm.copyBytes(to: $0) }
        return out
    }
}

/// The capture's 16-bit mono chunks at another rate, as 16 kHz 16-bit samples, one chunk at a time.
@MainActor
final class ForkDroplineResampler {
    private let input: AVAudioFormat
    private let output: AVAudioFormat
    private let converter: AVAudioConverter

    init?(from sampleRate: Double) {
        guard let input = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true),
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: ForkDroplineAudio.sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: input, to: output) else { return nil }
        self.input = input
        self.output = output
        self.converter = converter
    }

    func convert(_ pcm: Data) -> [Int16] {
        let frames = pcm.count / 2
        guard frames > 0, let source = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(frames)),
              let target = source.int16ChannelData?[0] else { return [] }
        source.frameLength = AVAudioFrameCount(frames)
        _ = pcm.withUnsafeBytes { memcpy(target, $0.baseAddress!, frames * 2) }
        let capacity = AVAudioFrameCount((Double(frames) * output.sampleRate / input.sampleRate).rounded(.up) + 64)
        guard let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return [] }
        let feed = ForkDroplineOneBuffer(source)
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in feed.next(status) }
        guard error == nil, let channel = converted.floatChannelData?[0] else { return [] }
        return (0..<Int(converted.frameLength)).map { Int16((max(-1, min(1, channel[$0])) * 32_767).rounded()) }
    }
}

/// Hands `AVAudioConverter` one buffer, then says there's no more for now, so it keeps its state
/// for the next chunk.
private final class ForkDroplineOneBuffer: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard let buffer else {
            status.pointee = .noDataNow
            return nil
        }
        self.buffer = nil
        status.pointee = .haveData
        return buffer
    }
}
