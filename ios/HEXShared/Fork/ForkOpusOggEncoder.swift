import AVFAudio
import AudioToolbox
import Foundation

/// A single, continuous 24 kbit/s Ogg Opus stream from 16 kHz mono PCM, ported from Derek
/// Voice's `OpusOggEncoder` (VoiceStreamAudio). Call serially; one encoder per recording.
nonisolated final class ForkOpusOggEncoder {
    enum EncodingError: Error {
        case unavailable, closed, invalidPacket, incompleteStream
    }

    static let packetFrames = 320
    private static let packetGranules: UInt64 = 960
    private static let packetsPerPage = 10
    private let converter: AVAudioConverter
    private let input: AVAudioPCMBuffer
    private let compressed: AVAudioCompressedBuffer
    private let preSkip: UInt16
    private let serial = UInt32.random(in: 1...UInt32.max)
    private var closed = false
    private var bufferedFrames = 0
    private var capturedFrames: UInt64 = 0
    private var encodedGranules: UInt64 = 0
    private var sequence: UInt32 = 0
    private var pagePackets = 0
    private var lacing: [UInt8] = []
    private var payload = Data()
    private(set) var output = Data()

    init() throws {
        guard let pcm = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
        ) else {
            throw EncodingError.unavailable
        }
        var description = AudioStreamBasicDescription(
            mSampleRate: 16_000, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: 320, mBytesPerFrame: 0,
            mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0
        )
        guard let opus = AVAudioFormat(streamDescription: &description),
              let converter = AVAudioConverter(from: pcm, to: opus),
              let input = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: 320) else {
            throw EncodingError.unavailable
        }
        converter.bitRate = 24_000
        let delay = UInt64(converter.primeInfo.leadingFrames) * 3
        guard converter.bitRate == 24_000, delay <= UInt16.max,
              converter.maximumOutputPacketSize > 0 else { throw EncodingError.unavailable }
        self.converter = converter
        self.input = input
        self.preSkip = UInt16(delay)
        self.compressed = AVAudioCompressedBuffer(
            format: opus, packetCapacity: 1, maximumPacketSize: converter.maximumOutputPacketSize
        )
        lacing.reserveCapacity(30)
        payload.reserveCapacity(converter.maximumOutputPacketSize * Self.packetsPerPage)
    }

    /// Appends every sample; complete Ogg pages accumulate in `output`.
    func append(_ samples: UnsafeBufferPointer<Float>) throws {
        try requireOpen()
        guard let base = samples.baseAddress else { return }
        var offset = 0
        while offset < samples.count {
            let count = min(Self.packetFrames - bufferedFrames, samples.count - offset)
            input.floatChannelData![0].advanced(by: bufferedFrames)
                .update(from: base.advanced(by: offset), count: count)
            bufferedFrames += count
            capturedFrames += UInt64(count)
            offset += count
            if bufferedFrames == Self.packetFrames { try submitInput() }
        }
    }

    /// Drains codec delay and terminates the stream with an EOS page. Ogg end trimming removes
    /// only encoder padding, never captured audio. An empty recording produces nothing.
    func finish() throws -> Data {
        try requireOpen()
        closed = true
        guard capturedFrames > 0 else { return output }
        if bufferedFrames > 0 { try submitInput() }
        try convert(hasInput: false, ending: true)
        let end = capturedFrames * 3 + UInt64(preSkip)
        guard pagePackets > 0, encodedGranules >= end,
              encodedGranules - end < Self.packetGranules else {
            throw EncodingError.incompleteStream
        }
        output.append(makePage(flags: 4, granule: end))
        return output
    }

    private func requireOpen() throws {
        if closed { throw EncodingError.closed }
    }

    private func submitInput() throws {
        input.frameLength = AVAudioFrameCount(bufferedFrames)
        try convert(hasInput: true, ending: false)
        bufferedFrames = 0
    }

    private func convert(hasInput: Bool, ending: Bool) throws {
        let feed = ForkConverterInput(hasInput ? input : nil, ending: ending)
        while true {
            compressed.packetCount = 0
            compressed.byteLength = 0
            var error: NSError?
            let status = converter.convert(to: compressed, error: &error) { _, status in feed.next(status) }
            if status == .error {
                closed = true
                throw error ?? EncodingError.invalidPacket as NSError
            }
            if compressed.packetCount > 0 {
                do {
                    try acceptPacket()
                } catch {
                    closed = true
                    throw error
                }
            }
            switch status {
            case .haveData: continue
            case .inputRanDry, .endOfStream, .error: return
            @unknown default:
                closed = true
                throw EncodingError.invalidPacket
            }
        }
    }

    private func acceptPacket() throws {
        guard compressed.packetCount == 1, let description = compressed.packetDescriptions,
              description.pointee.mStartOffset >= 0 else { throw EncodingError.invalidPacket }
        let size = Int(description.pointee.mDataByteSize)
        let offset = Int(description.pointee.mStartOffset)
        guard size > 0, offset + size <= Int(compressed.byteLength) else {
            throw EncodingError.invalidPacket
        }
        let bytes = compressed.data.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
        // RFC 6716 section 3.1: verify the native codec really produced 20 ms.
        let config = bytes[0] >> 3
        let frameGranules: Int
        if config >= 16 {
            frameGranules = 120 << (config & 3)
        } else if config >= 12 {
            frameGranules = 480 << (config & 1)
        } else {
            frameGranules = (config & 3) == 3 ? 2880 : 480 << (config & 3)
        }
        let code = bytes[0] & 3
        let count = code == 0 ? 1 : code == 3 ? (size > 1 ? Int(bytes[1] & 63) : 0) : 2
        guard frameGranules * count == Int(Self.packetGranules) else { throw EncodingError.invalidPacket }
        if sequence == 0 { appendHeaders() }
        // The newest page waits for the next packet, so a recording that fills its last page
        // exactly still puts EOS on a page carrying audio.
        if pagePackets == Self.packetsPerPage {
            output.append(makePage(flags: 0, granule: encodedGranules))
        }
        var remaining = size
        while remaining >= 255 {
            lacing.append(255)
            remaining -= 255
        }
        lacing.append(UInt8(remaining))
        payload.append(bytes, count: size)
        pagePackets += 1
        encodedGranules += Self.packetGranules
    }

    private func appendHeaders() {
        payload.append(contentsOf: "OpusHead".utf8)
        payload.append(contentsOf: [1, 1])
        payload.appendLittleEndian(preSkip)
        payload.appendLittleEndian(UInt32(16_000))
        payload.appendLittleEndian(UInt16(0))
        payload.append(0)
        lacing.append(UInt8(payload.count))
        output.append(makePage(flags: 2, granule: 0))
        let vendor = "Hex".utf8
        payload.append(contentsOf: "OpusTags".utf8)
        payload.appendLittleEndian(UInt32(vendor.count))
        payload.append(contentsOf: vendor)
        payload.appendLittleEndian(UInt32(0))
        lacing.append(UInt8(payload.count))
        output.append(makePage(flags: 0, granule: 0))
    }

    private func makePage(flags: UInt8, granule: UInt64) -> Data {
        var page = Data(capacity: 27 + lacing.count + payload.count)
        page.append(contentsOf: [0x4f, 0x67, 0x67, 0x53, 0, flags])
        page.appendLittleEndian(granule)
        page.appendLittleEndian(serial)
        page.appendLittleEndian(sequence)
        page.appendLittleEndian(UInt32(0))
        page.append(UInt8(lacing.count))
        page.append(contentsOf: lacing)
        page.append(payload)
        var crc: UInt32 = 0
        for byte in page {
            crc = (crc << 8) ^ Self.crcTable[Int((crc >> 24) ^ UInt32(byte))]
        }
        for index in 0..<4 {
            page[22 + index] = UInt8(truncatingIfNeeded: crc >> (index * 8))
        }
        sequence &+= 1
        payload.removeAll(keepingCapacity: true)
        lacing.removeAll(keepingCapacity: true)
        pagePackets = 0
        return page
    }

    private static let crcTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value) << 24
        for _ in 0..<8 {
            crc = (crc << 1) ^ (crc & 0x8000_0000 == 0 ? 0 : 0x04c1_1db7)
        }
        return crc
    }
}

/// Hands `AVAudioConverter` one buffer, if any, then ends the stream or pauses it.
nonisolated final class ForkConverterInput: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    private let ending: Bool

    init(_ buffer: AVAudioPCMBuffer?, ending: Bool) {
        self.buffer = buffer
        self.ending = ending
    }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        if let buffer {
            self.buffer = nil
            status.pointee = .haveData
            return buffer
        }
        status.pointee = ending ? .endOfStream : .noDataNow
        return nil
    }
}

private extension Data {
    nonisolated mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
