import AVFAudio
import Foundation

/// The audio Dropline gets for a recording: 16 kHz mono, its long pauses shrunk the way Derek
/// Voice's Worker does (`keptPackets`, src/worker/pauses.ts), encoded as Ogg Opus.
nonisolated enum ForkDroplineAudio {
    struct PauseSettings: Equatable, Sendable {
        /// Speech is this many dB above the noise floor.
        let marginDb: Int
        /// A pause longer than this is shrunk…
        let longPauseMs: Int
        /// …to this, half after the speech before it and half before the speech after it.
        let keptPauseMs: Int
    }

    static let pauses = PauseSettings(marginDb: 6, longPauseMs: 500, keptPauseMs: 250)
    static let sampleRate = 16_000.0
    /// One Opus packet's worth of audio: 20 ms at 16 kHz.
    static let blockFrames = ForkOpusOggEncoder.packetFrames
    /// Dropline takes 180 s; Derek Voice stops at 178 s (`DROPLINE_MAX_AUDIO_MS`).
    static let maxKeptFrames = 178 * 16_000

    private static let levelOffsetDb = 100
    private static let floorQuantile = 0.1
    private static let minSpeechDb = -55
    private static let joinMs = 200
    private static let minSpeechMs = 100
    private static let edgeMs = 250
    private static let packetMs = 20
    private static let levelSlack = 2
    private static let minSpeechShare = 0.1

    /// Reads the recording twice, measuring each 20 ms block and then encoding the kept ones,
    /// so a long keyboard recording never sits in memory as samples.
    static func encodedRecording(at url: URL) throws -> Data {
        try encoded { body in try forEachBlock(of: url, body) }
    }

    /// A live draft's audio: the recording so far as 16 kHz mono 16-bit chunks, encoded as a
    /// recording file is.
    static func encoded(chunks: [[Int16]]) throws -> Data {
        try encoded { body in try forEachBlock(of: chunks, body) }
    }

    private static func encoded(
        _ blocks: (_ body: (UnsafeBufferPointer<Float>) throws -> Void) throws -> Void
    ) throws -> Data {
        var levels: [UInt8] = []
        var frames: [Int] = []
        do {
            try blocks { block in
                levels.append(level(of: block))
                frames.append(block.count)
            }
        } catch {
            throw ForkDroplineFailure.encoding
        }
        let keep = keptPackets(levels: levels, packets: levels.count, settings: pauses)
        let keptFrames = zip(keep, frames).reduce(0) { $0 + ($1.0 ? $1.1 : 0) }
        guard keptFrames <= maxKeptFrames else { throw ForkDroplineFailure.tooLong }
        do {
            let encoder = try ForkOpusOggEncoder()
            var index = 0
            try blocks { block in
                defer { index += 1 }
                if index < keep.count, keep[index] {
                    try encoder.append(block)
                }
            }
            let encoded = try encoder.finish()
            guard !encoded.isEmpty else { throw ForkOpusOggEncoder.EncodingError.incompleteStream }
            return encoded
        } catch {
            throw ForkDroplineFailure.encoding
        }
    }

    /// A block's RMS in dBFS plus 100, rounded and clamped to 0…100 (`levelByte`).
    static func levelByte(rms: Double) -> UInt8 {
        let decibels = 20 * log10(max(rms, pow(10, -Double(levelOffsetDb) / 20)))
        let rounded = (decibels + Double(levelOffsetDb) + 0.5).rounded(.down)
        return UInt8(min(Double(levelOffsetDb), max(0, rounded)))
    }

    static func level(of block: UnsafeBufferPointer<Float>) -> UInt8 {
        guard !block.isEmpty else { return 0 }
        let sum = block.reduce(0.0) { $0 + Double($1) * Double($1) }
        return levelByte(rms: (sum / Double(block.count)).squareRoot())
    }

    /// Which 20 ms packets Dropline gets: long pauses shrunk, the silence before the first and
    /// after the last speech trimmed. With no speech found, or too little of it (a misjudged
    /// noise floor), every packet is kept.
    static func keptPackets(levels: [UInt8], packets: Int, settings: PauseSettings) -> [Bool] {
        let all = [Bool](repeating: true, count: packets)
        if packets == 0 || levels.isEmpty || abs(levels.count - packets) > levelSlack { return all }
        let sorted = levels.sorted()
        let floor = Int(sorted[Int((floorQuantile * Double(sorted.count - 1)).rounded(.down))])
        let threshold = max(floor + settings.marginDb, minSpeechDb + levelOffsetDb)
        let measured = min(levels.count, packets)

        var runs: [(start: Int, end: Int)] = []
        for index in 0..<measured where Int(levels[index]) >= threshold {
            if let last = runs.last, index - last.end < joinMs / packetMs {
                runs[runs.count - 1].end = index + 1
            } else {
                runs.append((index, index + 1))
            }
        }
        let speech = runs.filter { $0.end - $0.start >= minSpeechMs / packetMs }
        let spoken = speech.reduce(0) { $0 + $1.end - $1.start }
        if spoken == 0 || Double(spoken) < minSpeechShare * Double(measured) { return all }

        var keep = [Bool](repeating: false, count: packets)
        func mark(_ from: Int, _ to: Int) {
            let lower = max(0, from)
            let upper = min(packets, to)
            guard lower < upper else { return }
            for index in lower..<upper { keep[index] = true }
        }
        let edge = Int((Double(edgeMs) / Double(packetMs)).rounded(.up))
        let half = Int((Double(settings.keptPauseMs) / Double(packetMs) / 2 + 0.5).rounded(.down))
        mark(speech[0].start - edge, speech[0].start)
        for (index, run) in speech.enumerated() {
            mark(run.start, run.end)
            if index + 1 == speech.count {
                mark(run.end, run.end + edge)
            } else {
                let next = speech[index + 1]
                if (next.start - run.end) * packetMs > settings.longPauseMs {
                    mark(run.end, run.end + half)
                    mark(next.start - half, next.start)
                } else {
                    mark(run.end, next.start)
                }
            }
        }
        // Packets past the levels are kept unjudged.
        mark(measured, packets)
        return keep
    }

    /// Calls `body` with consecutive 320-frame blocks of the recording at 16 kHz mono, the
    /// last one possibly shorter.
    static func forEachBlock(of url: URL, _ body: (UnsafeBufferPointer<Float>) throws -> Void) throws {
        let file = try AVAudioFile(forReading: url)
        let source = file.processingFormat
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
        ), let read = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 4096) else {
            throw ForkOpusOggEncoder.EncodingError.unavailable
        }
        var block: [Float] = []
        block.reserveCapacity(blockFrames)
        func emit(_ buffer: AVAudioPCMBuffer) throws {
            guard let channel = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength)
            var offset = 0
            while offset < count {
                let take = min(blockFrames - block.count, count - offset)
                block.append(contentsOf: UnsafeBufferPointer(start: channel.advanced(by: offset), count: take))
                offset += take
                if block.count == blockFrames {
                    try block.withUnsafeBufferPointer(body)
                    block.removeAll(keepingCapacity: true)
                }
            }
        }

        if source.sampleRate == sampleRate, source.channelCount == 1 {
            while file.framePosition < file.length {
                try file.read(into: read)
                guard read.frameLength > 0 else { break }
                try emit(read)
            }
        } else {
            let capacity = AVAudioFrameCount((4096 * sampleRate / source.sampleRate).rounded(.up)) + 64
            guard let converter = AVAudioConverter(from: source, to: target),
                  let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
                throw ForkOpusOggEncoder.EncodingError.unavailable
            }
            let feed = ForkFileInput(file: file, buffer: read)
            while true {
                converted.frameLength = 0
                var error: NSError?
                let status = converter.convert(to: converted, error: &error) { _, status in feed.next(status) }
                if let failure = feed.failure { throw failure }
                if status == .error { throw error ?? ForkOpusOggEncoder.EncodingError.unavailable as NSError }
                try emit(converted)
                if status == .endOfStream || (status == .inputRanDry && feed.finished) { break }
            }
        }
        if !block.isEmpty {
            try block.withUnsafeBufferPointer(body)
        }
    }

    /// The same blocks from 16 kHz mono 16-bit chunks held in memory.
    static func forEachBlock(of chunks: [[Int16]], _ body: (UnsafeBufferPointer<Float>) throws -> Void) throws {
        var block: [Float] = []
        block.reserveCapacity(blockFrames)
        for chunk in chunks {
            for sample in chunk {
                block.append(Float(sample) / 32_768)
                if block.count == blockFrames {
                    try block.withUnsafeBufferPointer(body)
                    block.removeAll(keepingCapacity: true)
                }
            }
        }
        if !block.isEmpty {
            try block.withUnsafeBufferPointer(body)
        }
    }
}

/// Feeds `AVAudioConverter` a file, one read at a time, until it ends.
private nonisolated final class ForkFileInput: @unchecked Sendable {
    private let file: AVAudioFile
    private let buffer: AVAudioPCMBuffer
    private(set) var finished = false
    private(set) var failure: Error?

    init(file: AVAudioFile, buffer: AVAudioPCMBuffer) {
        self.file = file
        self.buffer = buffer
    }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard !finished, file.framePosition < file.length else { return end(status) }
        do {
            try file.read(into: buffer)
        } catch {
            failure = error
            return end(status)
        }
        guard buffer.frameLength > 0 else { return end(status) }
        status.pointee = .haveData
        return buffer
    }

    private func end(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        finished = true
        status.pointee = .endOfStream
        return nil
    }
}
