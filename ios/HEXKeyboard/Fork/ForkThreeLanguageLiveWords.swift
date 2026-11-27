import AVFAudio
import Foundation
import Speech

/// Three-language dictation's live words (fork): while three-language dictation applies
/// (`ForkThreeLanguage.usableLocales`), the keyboard shows the recording in the language the
/// dictation will most likely be inserted in. Live results carry no confidence, so every
/// `scoreInterval` of audio the recording so far is read again the way the dictation itself is
/// (`ForkThreeLanguage.readAll`), one language at a time, and `ForkThreeLanguage.LiveLeader`
/// turns those scores into the language to show. Only that language's `AppleLiveTranscriber`
/// runs, started on the audio so far when the shown language changes: an iPhone refuses
/// analyses past a small number at once (`insufficientResources`), so the preview holds at most
/// two, its recogniser and one scoring reading. Nothing shows until the first scores. Only for
/// the preview: the inserted text still comes from `ForkThreeLanguage.transcribe` once the
/// recording stops.
@available(iOS 26.0, *)
@MainActor
final class ForkThreeLanguageLiveWords: LiveTranscriptSource {
    var onUpdate: ((LiveTranscript) -> Void)?
    var onFailure: ((String) -> Void)?

    /// Audio before the first scores, and between later ones.
    static let firstScore: Double = 1
    static let scoreInterval: Double = 1.5
    /// Past this much audio the shown language stays as it is: each scoring reads the whole
    /// recording again.
    static let longestScored: Double = 12

    /// The live source for `language`, or nil when three-language dictation doesn't apply and
    /// the keyboard's own live words run as before.
    static func source(for language: SpeechLanguage?, sampleRate: Double) async -> ForkThreeLanguageLiveWords? {
        guard let language, let lanes = await ForkThreeLanguage.usableLocales(for: language).lanes else { return nil }
        return ForkThreeLanguageLiveWords(lanes: lanes, sampleRate: sampleRate)
    }

    private let planned: [ForkThreeLanguage.UsableLocale]
    private let sampleRate: Double
    /// Languages whose recogniser gave up: no longer scored or shown.
    private var dropped: Set<String> = []
    private var reader: AppleLiveTranscriber?
    private var readerID: String?
    /// Whether the running recogniser has had the recording so far.
    private var fed = false
    /// The recording from its start, replayed into a recogniser started later; kept until the
    /// shown language settles and its recogniser has had it.
    private var audio = Data()
    private var nextScore = firstScore
    private var scoring: Task<Void, Never>?
    private var scores = 0
    private var leader = ForkThreeLanguage.LiveLeader()
    private var switches = 0
    private var settled = false
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
        if fed { reader?.append(pcm) }
        guard !settled || !fed else { return }
        audio.append(pcm)
        if !settled, scoring == nil, audioSeconds >= nextScore, nextScore < Self.longestScored { score() }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        onUpdate = nil
        scoring?.cancel()
        reader?.stop()
        reader = nil
        audio = Data()
        try? FileManager.default.removeItem(at: scratch)
        KeyboardProbeLog.shared.write(
            "three-language live: stopped, lanes=\(planned.map(\.id).joined(separator: ",")) shown=\(leader.shown ?? "none") scores=\(scores) switches=\(switches)"
        )
    }

    /// Reads the audio so far in every language still in play, one after another, and moves
    /// the shown language.
    private func score() {
        let lanes = planned.filter { !dropped.contains($0.id) }
        let at = audioSeconds
        nextScore = at + Self.scoreInterval
        guard writeScratch() else {
            fail("scoring audio not written")
            return
        }
        let url = scratch
        scoring = Task { [weak self] in
            var readings: [ForkThreeLanguage.Lane] = []
            for lane in lanes {
                guard !Task.isCancelled else { return }
                if let reading = await ForkThreeLanguage.readAll(url, lanes: [lane], vocabulary: [], lingeringModels: false).first ?? nil {
                    readings.append(reading)
                }
            }
            guard let self, !self.stopped else { return }
            self.scoring = nil
            self.scored(readings, at: at)
        }
    }

    private func scored(_ lanes: [ForkThreeLanguage.Lane], at seconds: Double) {
        scores += 1
        let before = leader.shown
        let shown = leader.update(lanes.filter { !dropped.contains($0.locale) }, at: seconds)
        if before != nil, shown != before { switches += 1 }
        if let shown, shown != readerID, !dropped.contains(shown) { startReader(shown) }
        guard nextScore < Self.longestScored else {
            settle()
            return
        }
        if scoring == nil, audioSeconds >= nextScore { score() }
    }

    /// The last scoring is in: the shown language stays and the held audio goes.
    private func settle() {
        guard reader != nil, let shown = leader.shown else {
            fail("no reading scored in \(Int(Self.longestScored)) s")
            return
        }
        settled = true
        if fed { audio = Data() }
        KeyboardProbeLog.shared.write("three-language live: settled on \(shown) after \(scores) scores")
    }

    /// Replaces the running recogniser with `id`'s, fed the recording so far once it is ready
    /// (it holds only `AppleLiveTranscriber.maximumPendingSeconds` before). The words on screen
    /// stay until the new one's first update.
    private func startReader(_ id: String) {
        reader?.stop()
        reader = nil
        readerID = id
        fed = false
        guard let lane = planned.first(where: { $0.id == id }),
              let next = AppleLiveTranscriber(
                  locale: lane.locale,
                  module: .speech,
                  sampleRate: sampleRate,
                  log: { KeyboardProbeLog.shared.write($0) }
              ) else {
            laneFailed(id, reason: "no audio format")
            return
        }
        next.onUpdate = { [weak self] transcript in
            guard let self, !self.stopped, self.readerID == id else { return }
            self.onUpdate?(transcript)
        }
        next.onFailure = { [weak self] reason in self?.laneFailed(id, reason: reason) }
        reader = next
        Task { [weak self, weak next] in
            let deadline = ContinuousClock.now + .seconds(AppleLiveTranscriber.maximumPendingSeconds)
            while let next, next.readyAfter == nil, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard let self, let next, !self.stopped, self.reader === next else { return }
            guard next.readyAfter != nil else {
                self.laneFailed(id, reason: "not ready in \(Int(AppleLiveTranscriber.maximumPendingSeconds)) s")
                return
            }
            KeyboardProbeLog.shared.write("three-language live: showing \(id) from \(String(format: "%.1f", self.audioSeconds)) s")
            next.append(self.audio)
            self.fed = true
            if self.settled { self.audio = Data() }
        }
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

    /// A language's recogniser gave up: it is no longer scored or shown, and the next scoring
    /// picks another. Once settled, or with none left, the live words go.
    private func laneFailed(_ id: String, reason: String) {
        guard !stopped else { return }
        KeyboardProbeLog.shared.write("three-language live: \(id) gave up: \(reason)")
        dropped.insert(id)
        if readerID == id {
            reader?.stop()
            reader = nil
            readerID = nil
            fed = false
        }
        guard settled || planned.allSatisfy({ dropped.contains($0.id) }) else { return }
        fail(reason)
    }

    private func fail(_ reason: String) {
        let failure = onFailure
        stop()
        failure?(reason)
    }
}
