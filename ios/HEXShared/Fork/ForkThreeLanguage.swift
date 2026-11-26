import AVFAudio
import Foundation
import OSLog
import Speech

/// Three-language dictation (fork): while Labs › Two-language dictation is on, the dictation
/// language is English, Cantonese, or Mandarin, and all three `SpeechTranscriber` models are
/// installed, one recording is read in `en-US`, `zh-HK`, and `zh-TW` at once. The reading
/// with the most confidence-weighted seconds is inserted exactly as Apple Speech wrote it,
/// never merged with the others: a speaker keeps one language for a whole dictation, and the
/// Chinese models already write the English words mixed into it. Shared by the app
/// (`AppleSpeechTranscriber`) and in-keyboard dictation (`KeyboardSpeech`).
@available(iOS 26.0, *)
nonisolated enum ForkThreeLanguage {
    /// The three languages, in the order a tie keeps.
    static let locales = ["en-US", "zh-HK", "zh-TW"]

    /// How far a Mandarin reading may lead a Cantonese one that writes Cantonese-only
    /// characters and still lose to it. Measured on synthetic speech, where Cantonese clips
    /// led by 0.22 s or more.
    static let cantoneseMargin: TimeInterval = 0.3

    /// Characters written in Cantonese and not in Mandarin. The Cantonese model wrote some in
    /// every Cantonese clip measured and none in any Mandarin clip.
    static let cantoneseCharacters: Set<Character> = Set("嘅咗喺唔佢哋冇嘢啲咁嚟睇畀噉乜咪喇囉")

    /// One language's reading of the whole recording.
    struct Lane: Equatable, Sendable {
        let locale: String
        let text: String
        let words: [TwoLanguageTimedWord]

        /// Each word's confidence times its duration, summed: seconds of confident audio.
        var score: TimeInterval {
            words.reduce(0) { $0 + $1.confidence * $1.duration }
        }
    }

    /// The languages to read in, primary first, or nil to dictate as before: the lab off, a
    /// dictation language outside the three, or any of the three models not installed.
    /// Cantonese in any region (`yue-CN`, Settings' "Cantonese") counts as `zh-HK`, the
    /// Cantonese reading, and leads with it; when every reading fails, dictation still falls
    /// back to the Cantonese the person picked.
    static func plan(enabled: Bool, primary: String?, installed: [String: Bool]) -> [String]? {
        guard enabled, let primary else { return nil }
        let isCantonese = Locale(identifier: primary).language.languageCode?.identifier == "yue"
        let lead = isCantonese ? "zh-HK" : primary
        guard locales.contains(lead) else { return nil }
        guard locales.allSatisfy({ installed[$0] == true }) else { return nil }
        return [lead] + locales.filter { $0 != lead }
    }

    /// The reading to insert: the highest score among readings with text, ties to the first.
    /// A Mandarin winner gives way to a close Cantonese reading that writes Cantonese-only
    /// characters. Nil when no reading has text.
    static func pick(_ lanes: [Lane]) -> Lane? {
        let heard = lanes.filter { !$0.text.isEmpty }
        guard let best = heard.max(by: { $0.score < $1.score }) else { return nil }
        if best.locale == "zh-TW",
           let cantonese = heard.first(where: { $0.locale == "zh-HK" }),
           best.score - cantonese.score < cantoneseMargin,
           writesCantonese(cantonese.text) {
            return cantonese
        }
        return best
    }

    static func writesCantonese(_ text: String) -> Bool {
        text.contains { cantoneseCharacters.contains($0) }
    }

    /// Which reservations to release and make so all of `wanted` stay reserved, releasing
    /// the oldest other languages first. Nil when Apple's limit can't hold all of them.
    static func reservationChanges(
        reserved: [String],
        wanted: [String],
        limit: Int
    ) -> (release: [String], reserve: [String])? {
        let missing = wanted.filter { !reserved.contains($0) }
        guard !missing.isEmpty else { return ([], []) }
        guard limit >= wanted.count else { return nil }
        let others = reserved.filter { !wanted.contains($0) }
        let overflow = max(0, reserved.count + missing.count - limit)
        return (Array(others.prefix(overflow)), missing)
    }

    /// Reads `audioURL` in the three languages and returns the chosen reading's text. Nil
    /// means three-language dictation doesn't apply or every reading failed, so the caller
    /// takes its own path. Empty text means every reading finished without hearing anything,
    /// so the caller throws its own no-speech error.
    static func transcribe(
        _ audioURL: URL,
        language: SpeechLanguage,
        vocabulary: [String],
        lingeringModels: Bool
    ) async -> String? {
        guard let lanes = await usableLocales(for: language) else { return nil }
        let started = ContinuousClock.now
        let readings = await withTaskGroup(of: (Int, Lane?).self) { group in
            for (index, lane) in lanes.enumerated() {
                group.addTask {
                    (index, await read(audioURL, lane: lane, vocabulary: vocabulary, lingeringModels: lingeringModels))
                }
            }
            var readings = [Lane?](repeating: nil, count: lanes.count)
            for await (index, reading) in group {
                readings[index] = reading
            }
            return readings
        }
        let seconds = (ContinuousClock.now - started) / .seconds(1)
        Task { await keepReserved(lanes.map(\.locale)) }

        guard readings.contains(where: { $0 != nil }) else {
            log.error("three-language: every reading failed")
            return nil
        }
        let heard = zip(lanes, readings).map { lane, reading in
            reading ?? Lane(locale: lane.id, text: "", words: [])
        }
        let chosen = pick(heard)
        let scores = heard.map { "\($0.locale)=\(String(format: "%.2f", $0.score))" }.joined(separator: " ")
        let failed = zip(lanes, readings).filter { $0.1 == nil }.map { $0.0.id }.joined(separator: ",")
        let cantonese = heard.first { $0.locale == "zh-HK" }.map { writesCantonese($0.text) } ?? false
        log.notice(
            "three-language picked=\(chosen?.locale ?? "none", privacy: .public) \(scores, privacy: .public) cantonese=\(cantonese, privacy: .public) failed=\(failed, privacy: .public) seconds=\(String(format: "%.2f", seconds), privacy: .public)"
        )
        return chosen?.text ?? ""
    }

    private static let log = Logger(subsystem: "anomaly.hex.mobile", category: "fork-three-language")

    private struct UsableLocale: Sendable {
        let id: String
        let locale: Locale
    }

    private static func usableLocales(for language: SpeechLanguage) async -> [UsableLocale]? {
        let enabled = TwoLanguageDictationSettings().isEnabled
        guard enabled, language.module == .speech else { return nil }
        let primary = await SpeechTranscriber.supportedLocale(equivalentTo: language.locale)
        let settings = LanguageSettings()
        var resolved: [String: Locale] = [:]
        var installed: [String: Bool] = [:]
        var primaryID: String?
        for id in locales {
            guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: id)) else {
                continue
            }
            resolved[id] = locale
            if locale.identifier(.bcp47) == primary?.identifier(.bcp47) {
                primaryID = id
            }
            let ready = await isInstalled(locale)
            installed[id] = ready && !settings.speechModuleFailed(id)
        }
        guard let ids = plan(enabled: enabled, primary: primaryID ?? primary?.identifier(.bcp47), installed: installed) else { return nil }
        return ids.compactMap { id in resolved[id].map { UsableLocale(id: id, locale: $0) } }
    }

    private static func read(
        _ audioURL: URL,
        lane: UsableLocale,
        vocabulary: [String],
        lingeringModels: Bool
    ) async -> Lane? {
        let transcriber = transcriber(for: lane.locale)
        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: SpeechAnalyzer.Options(
                priority: .userInitiated,
                modelRetention: lingeringModels ? .lingering : .whileInUse
            )
        )
        defer { withExtendedLifetime(analyzer) {} }
        do {
            let file = try AVAudioFile(forReading: audioURL)
            try await analyzer.prepareToAnalyze(in: nil)
            if !vocabulary.isEmpty {
                let context = AnalysisContext()
                context.contextualStrings[.general] = vocabulary
                try? await analyzer.setContext(context)
            }
            try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
            var text = ""
            var words: [TwoLanguageTimedWord] = []
            for try await result in transcriber.results where result.isFinal {
                text += String(result.text.characters)
                words += AppleSpeechTwoLanguage.words(in: result.text)
            }
            return Lane(
                locale: lane.id,
                text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                words: words
            )
        } catch {
            log.error("three-language: \(lane.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func transcriber(for locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )
    }

    private static func isInstalled(_ locale: Locale) async -> Bool {
        let module: any SpeechModule = transcriber(for: locale)
        return await AssetInventory.status(forModules: [module]) == .installed
    }

    /// Keeps all three models reserved, so iOS doesn't reclaim the two the dictation language
    /// doesn't name: Hex reserves only the dictation language, releases it when that language
    /// changes, and releases the oldest reservation when at Apple's limit.
    private static func keepReserved(_ locales: [Locale]) async {
        let reserved = await AssetInventory.reservedLocales
        let limit = AssetInventory.maximumReservedLocales
        let key = { (locale: Locale) in locale.identifier(.bcp47) }
        guard let changes = reservationChanges(
            reserved: reserved.map(key),
            wanted: locales.map(key),
            limit: limit
        ) else {
            log.error("three-language: Apple keeps \(limit, privacy: .public) reservations, fewer than three")
            return
        }
        for locale in reserved where changes.release.contains(key(locale)) {
            _ = await AssetInventory.release(reservedLocale: locale)
        }
        for locale in locales where changes.reserve.contains(key(locale)) {
            _ = try? await AssetInventory.reserve(locale: locale)
        }
    }
}
