import AVFAudio
import Foundation
import Speech

/// Three-language dictation's live words (fork): while three-language dictation applies
/// (`ForkThreeLanguage.usableLocales`), the keyboard reads the recording live in each of its
/// languages (one `AppleLiveTranscriber` each) and shows the one the dictation will most likely
/// be inserted in. Live results carry no confidence, so every `scoreInterval` of audio the
/// recording so far is read again the way the dictation itself is
/// (`ForkThreeLanguage.readAll`), and `ForkThreeLanguage.LiveLeader` turns those scores into the
/// reading to show. Nothing shows until the first scores. Only for the preview: the inserted
/// text still comes from `ForkThreeLanguage.transcribe` once the recording stops. Readings
/// start with the first audio, so a source the keyboard never attaches never starts one.
@available(iOS 26.0, *)
@MainActor
final class ForkThreeLanguageLiveWords: LiveTranscriptSource {
    var onUpdate: ((LiveTranscript) -> Void)?
    var onFailure: ((String) -> Void)?

    /// Audio before the first scores, and between later ones.
    static let firstScore: Double = 1
    static let scoreInterval: Double = 1.5
    /// Past this much audio the shown reading stays as it is and only its recogniser keeps
    /// running: Apple caps the analyses running at once per device and each scoring reads the
    /// whole recording again, while the dictation's own readings need those analyses free when
    /// the recording stops.
    static let longestScored: Double = 12

    /// The live source for `language`, or nil when three-language dictation doesn't apply and
    /// the keyboard's own live words run as before.
    static func source(for language: SpeechLanguage?, sampleRate: Double) async -> ForkThreeLanguageLiveWords? {
        guard let language, let lanes = await ForkThreeLanguage.usableLocales(for: language).lanes else { return nil }
        return ForkThreeLanguageLiveWords(lanes: lanes, sampleRate: sampleRate)
    }

    private let planned: [ForkThreeLanguage.UsableLocale]
    private let sampleRate: Double
    private var running: [String: AppleLiveTranscriber] = [:]
    private var transcripts: [String: LiveTranscript] = [:]
    private var audio = Data()
    private var nextScore = firstScore
    private var scoring: Task<Void, Never>?
    private var scores = 0
    private var leader = ForkThreeLanguage.LiveLeader()
    private var switches = 0
    private var started = false
    private var stopped = false
    private let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("fork-three-language-live-\(UUID().uuidString).wav")

    private init(lanes: [ForkThreeLanguage.UsableLocale], sampleRate: Double) {
        planned = lanes
        self.sampleRate = sampleRate
    }

    private var audioSeconds: Double { Double(audio.count / 2) / sampleRate }

    func append(_ pcm: Data) {
        guard !stopped else { return }
        if !started { start() }
        running.values.forEach { $0.append(pcm) }
        guard audioSeconds < Self.longestScored else { return }
        audio.append(pcm)
        if scoring == nil, audioSeconds >= nextScore { score() }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        onUpdate = nil
        scoring?.cancel()
        running.values.forEach { $0.stop() }
        running = [:]
        try? FileManager.default.removeItem(at: scratch)
        KeyboardProbeLog.shared.write(
            "three-language live: stopped, lanes=\(planned.map(\.id).joined(separator: ",")) shown=\(leader.shown ?? "none") scores=\(scores) switches=\(switches)"
        )
    }

    private func start() {
        started = true
        for lane in planned {
            guard let reader = AppleLiveTranscriber(
                locale: lane.locale,
                module: .speech,
                sampleRate: sampleRate,
                log: { KeyboardProbeLog.shared.write($0) }
            ) else { continue }
            let id = lane.id
            reader.onUpdate = { [weak self] transcript in self?.received(id, transcript: transcript) }
            reader.onFailure = { [weak self] reason in self?.laneFailed(id, reason: reason) }
            running[id] = reader
        }
        KeyboardProbeLog.shared.write("three-language live: started \(running.keys.sorted().joined(separator: ","))")
        if running.isEmpty { fail("no audio format") }
    }

    /// Reads the audio so far in every running language and moves the shown reading.
    private func score() {
        let lanes = planned.filter { running[$0.id] != nil }
        let at = audioSeconds
        nextScore = at + Self.scoreInterval
        guard writeScratch() else { return }
        let url = scratch
        scoring = Task { [weak self] in
            let readings = await ForkThreeLanguage.readAll(url, lanes: lanes, vocabulary: [], lingeringModels: false)
            guard let self, !self.stopped else { return }
            self.scoring = nil
            self.scored(zip(lanes, readings).compactMap { $0.1 }, at: at)
        }
    }

    private func scored(_ lanes: [ForkThreeLanguage.Lane], at seconds: Double) {
        scores += 1
        let before = leader.shown
        let shown = leader.update(lanes.filter { running[$0.locale] != nil }, at: seconds)
        if before != nil, shown != before { switches += 1 }
        publish()
        guard nextScore < Self.longestScored else {
            settle()
            return
        }
        if scoring == nil, audioSeconds >= nextScore { score() }
    }

    /// The last scoring is in: the other languages' recognisers stop.
    private func settle() {
        guard let shown = leader.shown else {
            fail("no reading scored in \(Int(Self.longestScored)) s")
            return
        }
        for (id, reader) in running where id != shown {
            reader.stop()
            running[id] = nil
            transcripts[id] = nil
        }
        KeyboardProbeLog.shared.write("three-language live: settled on \(shown) after \(scores) scores")
    }

    private func writeScratch() -> Bool {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audio.count / 2)) else { return false }
        buffer.frameLength = AVAudioFrameCount(audio.count / 2)
        audio.withUnsafeBytes { raw in
            guard let base = raw.baseAddress, let target = buffer.int16ChannelData?[0] else { return }
            memcpy(target, base, audio.count)
        }
        do {
            let file = try AVAudioFile(
                forWriting: scratch,
                settings: format.settings,
                commonFormat: .pcmFormatInt16,
                interleaved: true
            )
            try file.write(from: buffer)
            return true
        } catch {
            KeyboardProbeLog.shared.write("three-language live: scoring audio not written: \((error as NSError).domain) \((error as NSError).code)")
            return false
        }
    }

    private func received(_ id: String, transcript: LiveTranscript) {
        guard !stopped else { return }
        transcripts[id] = transcript
        if id == leader.shown { publish() }
    }

    private func publish() {
        guard let shown = leader.shown, let transcript = transcripts[shown] else { return }
        onUpdate?(transcript)
    }

    private func laneFailed(_ id: String, reason: String) {
        guard !stopped else { return }
        KeyboardProbeLog.shared.write("three-language live: \(id) gave up: \(reason)")
        running[id] = nil
        transcripts[id] = nil
        guard running.isEmpty else { return }
        fail(reason)
    }

    private func fail(_ reason: String) {
        let failure = onFailure
        stop()
        failure?(reason)
    }
}
