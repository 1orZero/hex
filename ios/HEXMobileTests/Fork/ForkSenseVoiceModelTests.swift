import CoreML
import FluidAudio
import XCTest
@testable import HEX

/// SenseVoice with its real model, opt-in: `TEST_RUNNER_HEX_SENSEVOICE_MODEL` names a folder with
/// FluidAudio's fp16 files and `TEST_RUNNER_HEX_SENSEVOICE_AUDIO` a recording. Replays the recording
/// through the keyboard's live rounds every 2 s, then the final read, and reports each round's time
/// and the process's peak footprint between `SENSEVOICE-MODEL` and `SENSEVOICE-MODEL-END`.
final class ForkSenseVoiceModelTests: XCTestCase {
    func testARecordingReadsLiveAndWhole() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let model = environment["HEX_SENSEVOICE_MODEL"], let audio = environment["HEX_SENSEVOICE_AUDIO"] else {
            throw XCTSkip("Set TEST_RUNNER_HEX_SENSEVOICE_MODEL and TEST_RUNNER_HEX_SENSEVOICE_AUDIO")
        }
        let directory = URL(fileURLWithPath: model, isDirectory: true)
        let samples = try AudioConverter(sampleRate: 16_000).resampleAudioFile(URL(fileURLWithPath: audio))
        let peak = ForkSenseVoice.PeakFootprint()
        defer { peak.stop() }
        var lines = [
            "audio \(String(format: "%.1f", Double(samples.count) / 16_000)) s",
            "compute devices \(MLModel.availableComputeDevices.map { String(describing: $0) })",
        ]

        let loadStarted = ContinuousClock.now
        let engine = try ForkSenseVoiceEngine(directory: directory)
        _ = try await engine.read([Float](repeating: 0, count: 16_000))
        lines.append("load \(String(format: "%.2f", (ContinuousClock.now - loadStarted) / .seconds(1))) s, footprint \(Int(peak.megabytes)) MB")

        var live = ForkSenseVoiceLive(dictationLanguage: "zh-TW")
        var rounds: [TimeInterval] = []
        var end = 32_000
        while end <= samples.count {
            let round = live.round(samples[...], end: end)
            let started = ContinuousClock.now
            let result = try await ForkSenseVoiceLive.read(round, tail: Array(samples[round.start..<round.end]), engine: engine)
            rounds.append((ContinuousClock.now - started) / .seconds(1))
            _ = live.apply(result, of: round)
            end += 32_000
        }
        let wholeStarted = ContinuousClock.now
        let whole = try await engine.readWhole(samples, dictationLanguage: "zh-TW")
        lines.append(String(
            format: "%d rounds, longest %.3f s, mean %.3f s; whole %.3f s, language %@; peak footprint %.0f MB",
            rounds.count, rounds.max() ?? 0, rounds.reduce(0, +) / Double(max(rounds.count, 1)),
            (ContinuousClock.now - wholeStarted) / .seconds(1), whole.language, peak.megabytes
        ))

        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        let preprocessor = try MLModel(contentsOf: directory.appendingPathComponent(ModelNames.SenseVoice.preprocessorFile), configuration: configuration)
        let piece = Array(samples.prefix(100_000))
        let first = try features(preprocessor, piece)
        let again = try features(preprocessor, piece)
        let ours = ForkSenseVoiceFeatures.rows(piece).values
        lines.append(String(
            format: "6.25 s: the preprocessor model differs from itself by %.3f and from ForkSenseVoiceFeatures by %.3f",
            zip(first, again).map { abs($0 - $1) }.max() ?? 0, zip(first, ours).map { abs($0 - $1) }.max() ?? 0
        ))

        print((["SENSEVOICE-MODEL"] + lines + ["SENSEVOICE-MODEL-END"]).joined(separator: "\n"))
        XCTAssertFalse(whole.text.isEmpty)
    }

    private func features(_ model: MLModel, _ samples: [Float]) throws -> [Float] {
        let waveform = try MLMultiArray(shape: [1, samples.count as NSNumber], dataType: .float32)
        let pointer = waveform.dataPointer.assumingMemoryBound(to: Float32.self)
        for index in samples.indices { pointer[index] = samples[index] * SenseVoiceConfig.waveformScale }
        let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["waveform": MLFeatureValue(multiArray: waveform)]))
        let features = try XCTUnwrap(output.featureValue(for: "features")?.multiArrayValue)
        return Array(UnsafeBufferPointer(start: features.dataPointer.assumingMemoryBound(to: Float32.self), count: features.count))
    }
}
