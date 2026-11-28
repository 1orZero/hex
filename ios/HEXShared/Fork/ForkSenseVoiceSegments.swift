import Foundation

/// Where SenseVoice's audio is cut, always at the quietest stretch it can find. A recording
/// is read in pieces cut at pauses (`pieces`). Live words (`ForkSenseVoiceLiveTranscriber`) read
/// only the tail after their last cut, so a round's cost doesn't grow with the recording: a tail of `settleAfter` is cut
/// at a pause, and one of `forceAfter` at its quietest point anyway (`liveCut`).
nonisolated enum ForkSenseVoiceSegments {
    static let sampleRate = 16_000
    /// Seconds of audio between live rounds.
    static let interval: TimeInterval = 2
    static let settleAfter: TimeInterval = 8
    static let forceAfter: TimeInterval = 13
    /// The shortest stretch a live cut settles, and the newest audio it never reaches into.
    static let shortestSettled: TimeInterval = 3
    static let newest: TimeInterval = 1.5
    /// A long recording's pieces: at least `shortestPiece`, at most `longestPiece` seconds.
    static let shortestPiece: TimeInterval = 6
    static let longestPiece: TimeInterval = 15
    /// A pause: 300 ms at most a tenth of the audio's median energy.
    static let pause: TimeInterval = 0.3
    static let pauseShare: Float = 0.1

    /// Where to cut a live tail (samples from its start), or nil to read it whole.
    static func liveCut(_ tail: ArraySlice<Float>) -> Int? {
        let seconds = Double(tail.count) / Double(sampleRate)
        guard seconds >= settleAfter,
              let quietest = quietest(tail, from: shortestSettled, to: seconds - newest),
              quietest.isPause || seconds >= forceAfter else { return nil }
        return quietest.offset
    }

    /// The ranges to read a whole recording in: one when it is at most `longest` seconds, else
    /// pieces cut at the quietest stretch between `shortestPiece` and `longest` seconds, leaving
    /// the last piece at least `shortestPiece`. Pieces of at most 15 s read better than whole
    /// 30 s reads, which drop sentences, in qa- clips.
    static func pieces(count: Int, samples: [Float], longest: TimeInterval = longestPiece) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start = 0
        while count - start > Int(longest * Double(sampleRate)) {
            let window = samples[start..<min(count, start + Int(longest * Double(sampleRate)))]
            let to = min(longest, Double(count - start) / Double(sampleRate) - shortestPiece)
            let offset = quietest(window, from: min(shortestPiece, longest / 2), to: to)?.offset ?? Int(to * Double(sampleRate))
            ranges.append(start..<(start + offset))
            start += offset
        }
        ranges.append(start..<count)
        return ranges
    }

    /// The middle of the quietest `pause` between `from` and `to` seconds into `audio`
    /// (samples from its start), and whether it is quiet enough to be a pause.
    static func quietest(_ audio: ArraySlice<Float>, from: TimeInterval, to: TimeInterval) -> (offset: Int, isPause: Bool)? {
        let frame = sampleRate / 50
        let energies: [Float] = stride(from: audio.startIndex, to: audio.endIndex - frame + 1, by: frame).map { start in
            var sum: Float = 0
            for index in start..<(start + frame) { sum += audio[index] * audio[index] }
            return sum / Float(frame)
        }
        let window = Int(pause * 50)
        let first = Int(from * 50)
        let last = min(energies.count, Int(to * 50)) - window
        guard first >= 0, last > first else { return nil }
        var running = energies[first..<(first + window)].reduce(0, +)
        var best = (start: first, energy: running)
        for start in (first + 1)...last {
            running += energies[start + window - 1] - energies[start - 1]
            if running < best.energy { best = (start, running) }
        }
        let median = energies.sorted()[energies.count / 2]
        return ((best.start + window / 2) * frame, best.energy / Float(window) <= max(median * pauseShare, 1e-7))
    }

    /// Settled text and the next stretch's, with a space only between two that aren't Chinese.
    static func joined(_ settled: String, _ next: String) -> String {
        guard let last = settled.last, let first = next.first else { return settled + next }
        let wide: (Character) -> Bool = { ($0.unicodeScalars.first?.value ?? 0) >= 0x2E80 }
        return wide(last) || wide(first) || last.isWhitespace || first.isWhitespace ? settled + next : settled + " " + next
    }
}

/// Live words' bookkeeping (`ForkSenseVoiceLiveTranscriber`), apart from the audio and the
/// engine so the Mac harness replays it too. Each round reads the tail after the last cut; a
/// round that cuts first reads the stretch it settles. The language the first settled stretch
/// was heard in is kept for the rest of the recording, as the final text keeps one language.
nonisolated struct ForkSenseVoiceLive: Sendable {
    struct Round: Sendable {
        let start: Int
        let end: Int
        let cut: Int?
        let language: String?
    }

    struct Result: Sendable {
        let settled: ForkSenseVoiceEngine.Reading?
        let tail: ForkSenseVoiceEngine.Reading
    }

    private(set) var settledEnd = 0
    private(set) var settledText = ""
    private(set) var language: String?
    let dictationLanguage: String?

    init(dictationLanguage: String?) {
        self.dictationLanguage = dictationLanguage
    }

    /// The round for the audio up to `end` samples.
    func round(_ samples: ArraySlice<Float>, end: Int) -> Round {
        let tail = samples[(samples.startIndex + settledEnd)..<(samples.startIndex + end)]
        return Round(start: settledEnd, end: end, cut: ForkSenseVoiceSegments.liveCut(tail), language: language)
    }

    /// Reads a round's audio, `tail` being its samples from `round.start` to `round.end`: the
    /// stretch it settles, then the rest.
    static func read(_ round: Round, tail: [Float], engine: ForkSenseVoiceEngine) async throws -> Result {
        var settled: ForkSenseVoiceEngine.Reading?
        var language = round.language
        var rest = tail[...]
        if let cut = round.cut {
            settled = try await engine.read(Array(tail[..<cut]), language: language)
            if language == nil, let heard = settled?.language, !heard.isEmpty { language = heard }
            rest = tail[cut...]
        }
        return Result(settled: settled, tail: try await engine.read(Array(rest), language: language))
    }

    /// Takes a round's readings and returns what the preview shows.
    mutating func apply(_ result: Result, of round: Round) -> LiveTranscript {
        if let settled = result.settled, let cut = round.cut {
            if language == nil, !settled.language.isEmpty { language = settled.language }
            settledText = ForkSenseVoiceSegments.joined(settledText, written(settled))
            settledEnd = round.start + cut
        }
        return LiveTranscript(settled: settledText, tentative: written(result.tail))
    }

    private func written(_ reading: ForkSenseVoiceEngine.Reading) -> String {
        ForkSenseVoiceText.written(reading.text, language: language ?? reading.language, dictationLanguage: dictationLanguage)
    }
}
