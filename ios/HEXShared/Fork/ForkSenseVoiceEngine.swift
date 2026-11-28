@preconcurrency import CoreML
import CoreVideo
import FluidAudio
import Foundation

/// SenseVoice-Small from FluidAudio's `FluidInference/sensevoice-small-coreml` files: features
/// computed here (`ForkSenseVoiceFeatures`), the fp16 encoder and its CTC head on the Neural
/// Engine, then greedy CTC decoding. FluidAudio's `SenseVoiceManager` drops the language
/// SenseVoice detected and asks for text without punctuation (`woitn`), so the fork runs the
/// encoder itself.
actor ForkSenseVoiceEngine {
    struct Reading: Equatable, Sendable {
        /// SenseVoice's text: Simplified Chinese, with punctuation and digits.
        let text: String
        /// The language SenseVoice detected (`zh`, `yue`, `en`, `ja`, `ko`), or "" for none.
        let language: String
    }

    static let sampleRate = SenseVoiceConfig.sampleRate
    /// SenseVoice's text-norm query `withitn`: punctuation and digits (`woitn`, 15, has neither).
    static let withPunctuation: Int32 = 14
    /// The language query: `auto` (0), where SenseVoice detects the language itself, or one it reads in.
    static let autoLanguage: Int32 = 0
    static let languageQueries: [String: Int32] = ["zh": 3, "en": 4, "yue": 7, "ja": 11, "ko": 12]
    /// SentencePiece tokens, the logits' last dimension.
    static let vocabularySize = 25_055
    private let encoder: MLModel
    private let vocabulary: [Int: String]
    /// One logits array per encoder bucket, reused, in an IOSurface the Neural Engine writes
    /// into: Core ML frees the arrays it allocates seconds late, so reads back to back (a long
    /// recording's pieces) each added 13 MB on a Mac, and an `MLMultiArray` of our own didn't help.
    private var logitsBuffers: [Int: MLMultiArray] = [:]

    /// The fp16 encoder and the vocabulary in FluidAudio's folder. The folder's preprocessor
    /// model isn't loaded (`ForkSenseVoiceFeatures` says why).
    init(directory: URL) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        encoder = try MLModel(contentsOf: directory.appendingPathComponent(ModelNames.SenseVoice.encoderFile), configuration: configuration)
        let tokens = try JSONDecoder().decode([String].self, from: Data(contentsOf: directory.appendingPathComponent(ModelNames.SenseVoice.vocabularyFile)))
        vocabulary = Dictionary(uniqueKeysWithValues: tokens.enumerated().map { ($0.offset, $0.element) })
    }

    /// Audio shorter than this (0.2 s) is padded with silence to it.
    static let shortestRead = 3_200

    /// Reads 16 kHz mono samples in [-1, 1], at most `ForkSenseVoiceSegments.longestPiece`, in
    /// `language` (`languageQueries`), or in the language SenseVoice detects when nil.
    func read(_ samples: [Float], language: String? = nil) throws -> Reading {
        // Core ML's arrays are autoreleased: a keyboard reading every 2 s would hold each one.
        try autoreleasepool {
            let features = ForkSenseVoiceFeatures.rows(samples + [Float](repeating: 0, count: max(0, Self.shortestRead - samples.count)))
            let (logits, frames) = try encode(features.values, rows: features.count, language: language.flatMap { Self.languageQueries[$0] } ?? Self.autoLanguage)
            return Self.reading(from: decodeCtcTokenIds(Self.greedy(logits, frames: frames), vocabulary: vocabulary))
        }
    }

    /// A whole recording, read in `ForkSenseVoiceSegments.pieces` and written in the
    /// dictation's spelling (`ForkSenseVoiceText`). A dictation keeps one language: pieces
    /// SenseVoice heard in another than most of the audio are read again in that one, since a
    /// short piece full of English words often reads as English.
    func readWhole(_ samples: [Float], dictationLanguage: String?, longestPiece: TimeInterval = ForkSenseVoiceSegments.longestPiece) throws -> Reading {
        let ranges = ForkSenseVoiceSegments.pieces(count: samples.count, samples: samples, longest: longestPiece)
        var readings = try ranges.map { try read(Array(samples[$0])) }
        var heard: [String: Int] = [:]
        for (range, reading) in zip(ranges, readings) where !reading.language.isEmpty {
            heard[reading.language, default: 0] += range.count
        }
        let language = heard.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key ?? ""
        for index in readings.indices where !language.isEmpty && !readings[index].language.isEmpty && readings[index].language != language {
            readings[index] = try read(Array(samples[ranges[index]]), language: language)
        }
        let text = readings.reduce("") { text, reading in
            ForkSenseVoiceSegments.joined(text, ForkSenseVoiceText.written(reading.text, language: language, dictationLanguage: dictationLanguage))
        }
        return Reading(text: text, language: language)
    }

    /// The language tag SenseVoice writes first, and the text with every `<|…|>` tag removed,
    /// or "" when no letter or digit is left: a misread clip sometimes comes back as a lone ".".
    static func reading(from raw: String) -> Reading {
        let language = raw.firstMatch(of: /<\|([a-z]+)\|>/).map { String($0.1) } ?? ""
        let text = raw.replacing(/<\|[^|]*\|>/, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return Reading(text: text.contains { $0.isLetter || $0.isNumber } ? text : "", language: language == "nospeech" ? "" : language)
    }

    /// The CTC logits and how many of their frames hold audio, the 4 query frames first.
    private func encode(_ features: [Float], rows: Int, language: Int32) throws -> (MLMultiArray, Int) {
        let width = ForkSenseVoiceFeatures.width
        let frames = min(rows, SenseVoiceConfig.maxFrames)
        let bucket = SenseVoiceConfig.pickBucket(forFrames: frames)
        let speech = try MLMultiArray(shape: [1, bucket as NSNumber, width as NSNumber], dataType: .float32)
        let target = speech.dataPointer.assumingMemoryBound(to: Float32.self)
        target.initialize(repeating: 0, count: bucket * width)
        features.withUnsafeBufferPointer { target.update(from: $0.baseAddress!, count: frames * width) }
        func scalar(_ value: Int32) throws -> MLFeatureValue {
            let array = try MLMultiArray(shape: [1], dataType: .int32)
            array[0] = NSNumber(value: value)
            return MLFeatureValue(multiArray: array)
        }
        let options = MLPredictionOptions()
        if let buffer = logitsBuffers[bucket] ?? Self.logitsBuffer(rows: bucket + SenseVoiceConfig.numQueryTokens) {
            logitsBuffers[bucket] = buffer
            options.outputBackings = ["ctc_logits": buffer]
        }
        let output = try encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "speech": MLFeatureValue(multiArray: speech),
            "speech_lengths": try scalar(Int32(frames)),
            "language": try scalar(language),
            "textnorm": try scalar(Self.withPunctuation),
        ]), options: options)
        guard let logits = output.featureValue(for: "ctc_logits")?.multiArrayValue else {
            throw ASRError.processingFailed("SenseVoice encoder produced no ctc_logits")
        }
        return (logits, SenseVoiceConfig.numQueryTokens + frames)
    }

    private static func logitsBuffer(rows: Int) -> MLMultiArray? {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        guard CVPixelBufferCreate(nil, vocabularySize, rows, kCVPixelFormatType_OneComponent16Half, attributes, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        return MLMultiArray(pixelBuffer: buffer, shape: [1, rows as NSNumber, vocabularySize as NSNumber])
    }

    /// Each frame's most likely token, blanks dropped and repeats collapsed.
    private static func greedy(_ logits: MLMultiArray, frames: Int) -> [Int] {
        let vocabulary = logits.shape[2].intValue
        let count = min(frames, logits.shape[1].intValue)
        let frameStride = logits.strides[1].intValue
        let tokenStride = logits.strides[2].intValue
        var ids: [Int] = []
        var previous = -1
        func keep(_ best: Int) {
            if best != SenseVoiceConfig.blankId && best != previous { ids.append(best) }
            previous = best
        }
        func collect<Value: BinaryFloatingPoint>(_ pointer: UnsafePointer<Value>) {
            for frame in 0..<count {
                let base = frame * frameStride
                var best = 0
                var bestValue = pointer[base]
                for token in 1..<vocabulary where pointer[base + token * tokenStride] > bestValue {
                    bestValue = pointer[base + token * tokenStride]
                    best = token
                }
                keep(best)
            }
        }
        switch logits.dataType {
        case .float16:
            logits.withUnsafeBytes { collect($0.baseAddress!.assumingMemoryBound(to: Float16.self)) }
        case .float32:
            logits.withUnsafeBytes { collect($0.baseAddress!.assumingMemoryBound(to: Float32.self)) }
        default:
            for frame in 0..<count {
                var best = 0
                var bestValue = logits[[0, frame as NSNumber, 0]].floatValue
                for token in 1..<vocabulary {
                    let value = logits[[0, frame as NSNumber, token as NSNumber]].floatValue
                    if value > bestValue {
                        bestValue = value
                        best = token
                    }
                }
                keep(best)
            }
        }
        return ids
    }
}
