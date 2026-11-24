import AVFAudio
import XCTest
@testable import HEX

final class ForkDroplineAudioTests: XCTestCase {
    private let pauses = ForkDroplineAudio.pauses

    func testLevelByteMatchesTheWorker() {
        XCTAssertEqual(ForkDroplineAudio.levelByte(rms: 1), 100)
        XCTAssertEqual(ForkDroplineAudio.levelByte(rms: 0.01), 60)
        XCTAssertEqual(ForkDroplineAudio.levelByte(rms: 0), 0)
        XCTAssertEqual(ForkDroplineAudio.levelByte(rms: 2), 100)
        XCTAssertEqual(ForkDroplineAudio.levelByte(rms: 0.1), 80)
        XCTAssertEqual(ForkDroplineAudio.levelByte(rms: 1e-6), 0)
    }

    func testALongPauseBetweenSpeechShrinks() {
        let levels = repeated(70, 20) + repeated(20, 50) + repeated(70, 20)

        let keep = ForkDroplineAudio.keptPackets(levels: levels, packets: levels.count, settings: pauses)

        XCTAssertEqual(keep.count, 90)
        XCTAssertEqual(keep.filter { $0 }.count, 52)
        XCTAssertTrue(keep[0..<26].allSatisfy { $0 })
        XCTAssertTrue(keep[26..<64].allSatisfy { !$0 })
        XCTAssertTrue(keep[64..<90].allSatisfy { $0 })
    }

    func testAShortPauseStays() {
        let levels = repeated(70, 20) + repeated(20, 20) + repeated(70, 20)

        let keep = ForkDroplineAudio.keptPackets(levels: levels, packets: levels.count, settings: pauses)

        XCTAssertTrue(keep.allSatisfy { $0 })
    }

    func testSilenceBeforeAndAfterSpeechIsTrimmedToTheEdge() {
        let levels = repeated(20, 30) + repeated(70, 20) + repeated(20, 30)

        let keep = ForkDroplineAudio.keptPackets(levels: levels, packets: levels.count, settings: pauses)

        XCTAssertEqual(keep.firstIndex(of: true), 30 - 13)
        XCTAssertEqual(keep.lastIndex(of: true), 50 + 13 - 1)
    }

    func testSilenceKeepsEverything() {
        let levels = repeated(20, 100)

        XCTAssertEqual(ForkDroplineAudio.keptPackets(levels: levels, packets: 100, settings: pauses), Array(repeating: true, count: 100))
    }

    func testTooLittleSpeechKeepsEverything() {
        let levels = repeated(70, 5) + repeated(20, 95)

        XCTAssertTrue(ForkDroplineAudio.keptPackets(levels: levels, packets: 100, settings: pauses).allSatisfy { $0 })
    }

    func testLevelsForAnotherRecordingKeepEverything() {
        let levels = repeated(70, 20) + repeated(20, 50) + repeated(70, 20)

        XCTAssertTrue(ForkDroplineAudio.keptPackets(levels: levels, packets: 93, settings: pauses).allSatisfy { $0 })
        XCTAssertEqual(ForkDroplineAudio.keptPackets(levels: [], packets: 0, settings: pauses), [])
    }

    func testEncoderWritesOpusHeadFirstAndEndsWithAnEOSPage() throws {
        let encoder: ForkOpusOggEncoder
        do {
            encoder = try ForkOpusOggEncoder()
        } catch {
            throw XCTSkip("The Opus encoder is unavailable here: \(error)")
        }
        let samples = (0..<16_000).map { Float(sin(Double($0) * 2 * .pi * 440 / 16_000) * 0.3) }
        try samples.withUnsafeBufferPointer { try encoder.append($0) }

        let pages = try oggPages(try encoder.finish())

        XCTAssertGreaterThanOrEqual(pages.count, 3)
        XCTAssertEqual(pages.first?.flags, 2)
        XCTAssertEqual(pages.first?.payload.prefix(8), Data("OpusHead".utf8))
        XCTAssertEqual(pages[1].payload.prefix(8), Data("OpusTags".utf8))
        XCTAssertEqual(pages.last?.flags, 4)
        XCTAssertEqual(pages.map(\.sequence), Array(0..<UInt32(pages.count)))
    }

    func testRecordingsAreEncodedAtEitherCaptureRate() throws {
        try requireOpus()
        for sampleRate in [16_000.0, 48_000.0] {
            let url = try writeRecording(sampleRate: sampleRate, seconds: 2, tone: { $0 < 0.6 || $0 > 1.6 })
            defer { try? FileManager.default.removeItem(at: url) }

            let encoded = try ForkDroplineAudio.encodedRecording(at: url)

            let pages = try oggPages(encoded)
            XCTAssertEqual(pages.first?.payload.prefix(8), Data("OpusHead".utf8), "\(sampleRate)")
            XCTAssertEqual(pages.last?.flags, 4, "\(sampleRate)")
        }
    }

    func testThePausesAreShrunkBeforeEncoding() throws {
        try requireOpus()
        let url = try writeRecording(sampleRate: 16_000, seconds: 4, tone: { $0 < 1 || $0 >= 3 })
        defer { try? FileManager.default.removeItem(at: url) }
        var levels: [UInt8] = []
        try ForkDroplineAudio.forEachBlock(of: url) { levels.append(ForkDroplineAudio.level(of: $0)) }

        let keep = ForkDroplineAudio.keptPackets(levels: levels, packets: levels.count, settings: pauses)

        XCTAssertEqual(levels.count, 200)
        XCTAssertEqual(keep.filter { $0 }.count, 50 + 6 + 6 + 50)
    }

    func testARecordingLongerThan178SecondsOfSpeechIsRefused() throws {
        let url = try writeRecording(sampleRate: 16_000, seconds: 179, tone: { _ in true })
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try ForkDroplineAudio.encodedRecording(at: url)) { error in
            XCTAssertEqual(error as? ForkDroplineFailure, .tooLong)
        }
    }

    // MARK: - Helpers

    private func repeated(_ level: UInt8, _ count: Int) -> [UInt8] {
        Array(repeating: level, count: count)
    }

    private func requireOpus() throws {
        do {
            _ = try ForkOpusOggEncoder()
        } catch {
            throw XCTSkip("The Opus encoder is unavailable here: \(error)")
        }
    }

    /// A 16-bit mono WAV like the app's and the keyboard's captures: a 440 Hz tone where
    /// `tone` says so, near silence elsewhere.
    private func writeRecording(sampleRate: Double, seconds: Double, tone: (Double) -> Bool) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("qa-dropline-\(UUID().uuidString).wav")
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true))
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        let total = Int(sampleRate * seconds)
        let chunk = 4096
        var written = 0
        while written < total {
            let count = min(chunk, total - written)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
            buffer.frameLength = AVAudioFrameCount(count)
            let samples = try XCTUnwrap(buffer.int16ChannelData?[0])
            for index in 0..<count {
                let time = Double(written + index) / sampleRate
                let amplitude = tone(time) ? 0.3 : 0.0005
                samples[index] = Int16(sin(time * 2 * .pi * 440) * amplitude * 32_767)
            }
            try file.write(from: buffer)
            written += count
        }
        return url
    }

    private struct Page {
        let flags: UInt8
        let sequence: UInt32
        let payload: Data
    }

    private func oggPages(_ data: Data) throws -> [Page] {
        let bytes = [UInt8](data)
        var pages: [Page] = []
        var offset = 0
        while offset < bytes.count {
            XCTAssertEqual(Array(bytes[offset..<offset + 4]), Array("OggS".utf8))
            let segments = Int(bytes[offset + 26])
            let lacing = bytes[(offset + 27)..<(offset + 27 + segments)]
            let size = lacing.reduce(0) { $0 + Int($1) }
            let start = offset + 27 + segments
            let sequence = bytes[(offset + 18)..<(offset + 22)].reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            pages.append(Page(flags: bytes[offset + 5], sequence: sequence, payload: Data(bytes[start..<(start + size)])))
            offset = start + size
        }
        XCTAssertEqual(offset, bytes.count)
        return pages
    }
}
