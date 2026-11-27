import AVFAudio
import Foundation
import OSLog
import Speech

/// Three-language dictation (fork): while Labs › Two-language dictation is on, the dictation
/// language is English, Cantonese, or Mandarin, and the `SpeechTranscriber` models `required`
/// names are installed, one recording is read in `en-US` (when its model is installed too),
/// `zh-HK`, and `zh-TW` at once. The reading
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
    /// dictation language outside the three, or a `required` model not installed.
    /// Cantonese in any region (`yue-CN`, Settings' "Cantonese") counts as `zh-HK`, the
    /// Cantonese reading, and leads with it; when every reading fails, dictation still falls
    /// back to the Cantonese the person picked.
    static func plan(enabled: Bool, primary: String?, installed: [String: Bool]) -> [String]? {
        guard enabled, let lead = lead(for: primary) else { return nil }
        guard required(lead: lead).allSatisfy({ installed[$0] == true }) else { return nil }
        return [lead] + locales.filter { $0 != lead && installed[$0] == true }
    }

    /// The models a dictation led by `lead` can't go without: both Chinese readings, which tell
    /// Cantonese from Mandarin, and the dictation language's own. English is read only when its
    /// model is installed: the Chinese models write the English words mixed into Chinese, and a
    /// Chinese dictation language without three languages would read English in Chinese anyway.
    static func required(lead: String) -> [String] {
        locales.filter { $0 == lead || $0 != "en-US" }
    }

    /// Which of the three readings a dictation language leads with, or nil for another language.
    static func lead(for primary: String?) -> String? {
        guard let primary else { return nil }
        let isCantonese = Locale(identifier: primary).language.languageCode?.identifier == "yue"
        let lead = isCantonese ? "zh-HK" : primary
        return locales.contains(lead) ? lead : nil
    }

    /// Why three-language dictation doesn't run, for the log and `Record`: nil when it runs.
    static func skipReason(
        enabled: Bool,
        speechModule: Bool,
        primary: String?,
        installed: [String: Bool]
    ) -> String? {
        guard enabled else { return "lab-off" }
        guard speechModule else { return "dictation-module" }
        guard lead(for: primary) != nil else { return "language=\(primary ?? "none")" }
        let missing = required(lead: lead(for: primary) ?? "").filter { installed[$0] != true }
        return missing.isEmpty ? nil : "not-installed=\(missing.joined(separator: ","))"
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

    /// Which reading the keyboard's live words show while it records
    /// (`ForkThreeLanguageLiveWords`, which scores the audio so far every so often): `pick`'s
    /// first choice, then another only once `pick` has kept choosing it for `delay` seconds of
    /// audio, so the words follow the language the dictation will be inserted in without
    /// flipping while two scores are close.
    struct LiveLeader: Sendable {
        static let delay: TimeInterval = 0.6

        private(set) var shown: String?
        private var challenger: String?
        private var challengerSince: TimeInterval = 0

        /// The reading to show after an update at `now` (seconds, any clock).
        mutating func update(_ lanes: [Lane], at now: TimeInterval) -> String? {
            guard let best = ForkThreeLanguage.pick(lanes)?.locale else { return shown }
            guard let current = shown, lanes.contains(where: { $0.locale == current && !$0.text.isEmpty }) else {
                shown = best
                challenger = nil
                return shown
            }
            guard best != current else {
                challenger = nil
                return shown
            }
            if challenger != best {
                challenger = best
                challengerSince = now
            }
            if now - challengerSince >= Self.delay {
                shown = best
                challenger = nil
            }
            return shown
        }
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
        let usable = await usableLocales(for: language)
        guard let lanes = usable.lanes else {
            log.notice("three-language skipped=\(usable.skipped, privacy: .public)")
            Record.append(Record(event: "skipped", detail: usable.skipped))
            return nil
        }
        let started = ContinuousClock.now
        let readings = await readAll(audioURL, lanes: lanes, vocabulary: vocabulary, lingeringModels: lingeringModels)
        let seconds = (ContinuousClock.now - started) / .seconds(1)

        guard readings.contains(where: { $0 != nil }) else {
            log.error("three-language: every reading failed")
            Record.append(Record(event: "failed", detail: "every reading", seconds: seconds))
            return nil
        }
        let heard = zip(lanes, readings).map { lane, reading in
            reading ?? Lane(locale: lane.id, text: "", words: [])
        }
        let chosen = pick(heard)
        let scores = heard.map { "\($0.locale)=\(String(format: "%.2f", $0.score))" }.joined(separator: " ")
        let failed = zip(lanes, readings).filter { $0.1 == nil }.map { $0.0.id }.joined(separator: ",")
        let cantonese = heard.first { $0.locale == "zh-HK" }.map { writesCantonese($0.text) } ?? false
        let missing = locales.filter { id in !lanes.contains { $0.id == id } }
        log.notice(
            "three-language picked=\(chosen?.locale ?? "none", privacy: .public) \(scores, privacy: .public) cantonese=\(cantonese, privacy: .public) failed=\(failed, privacy: .public) missing=\(missing.joined(separator: ","), privacy: .public) seconds=\(String(format: "%.2f", seconds), privacy: .public)"
        )
        Record.append(Record(
            event: "picked",
            detail: chosen?.locale ?? "none",
            scores: Dictionary(uniqueKeysWithValues: heard.map { ($0.locale, ($0.score * 100).rounded() / 100) }),
            cantonese: cantonese,
            failed: failed.isEmpty ? [] : failed.components(separatedBy: ","),
            missing: missing,
            seconds: (seconds * 100).rounded() / 100
        ))
        return chosen?.text ?? ""
    }

    /// Reads `audioURL` in every lane at once, in `lanes`' order; nil where a reading failed.
    static func readAll(
        _ audioURL: URL,
        lanes: [UsableLocale],
        vocabulary: [String],
        lingeringModels: Bool
    ) async -> [Lane?] {
        await withTaskGroup(of: (Int, Lane?).self) { group in
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
    }

    /// One three-language decision, kept in the App Group's `Library/fork-three-language.json`
    /// (the newest `Record.limit`) so it can be read off the iPhone after the fact; iOS keeps
    /// the system log only for a live stream. Never the transcript.
    struct Record: Codable, Equatable, Sendable {
        /// `picked`, `skipped`, `failed`, or `prepared`.
        var event: String
        /// The chosen language, why dictation skipped three languages, or what `prepareModels` did.
        var detail: String
        var scores: [String: Double] = [:]
        var cantonese = false
        var failed: [String] = []
        /// Readings skipped because their model isn't installed (English only, see `required`).
        /// Optional so records written before it existed still decode.
        var missing: [String]?
        var seconds: Double?
        var at = Date()
        var process = Bundle.main.bundleURL.pathExtension == "appex" ? "keyboard" : "app"

        static let limit = 50

        static func appending(_ record: Record, to records: [Record]) -> [Record] {
            Array((records + [record]).suffix(limit))
        }

        static var url: URL? {
            FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: KeyboardBridge.appGroup)?
                .appendingPathComponent("Library/fork-three-language.json")
        }

        static func append(_ record: Record) {
            guard let url else { return }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let existing = (try? Data(contentsOf: url)).flatMap { try? decoder.decode([Record].self, from: $0) } ?? []
            guard let data = try? encoder.encode(appending(record, to: existing)) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    /// While Hex is open with the lab on and an English, Cantonese, or Mandarin dictation
    /// language, keeps all three models reserved and downloads any that aren't installed, so
    /// three-language dictation doesn't quietly fall back to the dictation language alone. Hex
    /// downloads only the dictation language's model, and iOS may reclaim a model no
    /// reservation holds.
    static func prepareModels() async {
        guard TwoLanguageDictationSettings().isEnabled,
              lead(for: LanguageSettings().effectiveDictationLanguage) != nil else { return }
        var resolved: [(id: String, locale: Locale)] = []
        var outcomes: [String] = []
        for id in locales {
            guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: id)) else {
                outcomes.append("\(id)=unsupported")
                continue
            }
            resolved.append((id, locale))
        }
        await keepReserved(resolved.map(\.locale))
        var absent: [(id: String, locale: Locale)] = []
        for entry in resolved {
            if !(await isInstalled(entry.locale)) { absent.append(entry) }
        }
        if !absent.isEmpty {
            let detail = "downloading=\(absent.map(\.id).joined(separator: ","))"
            log.notice("three-language prepared \(detail, privacy: .public)")
            Record.append(Record(event: "prepared", detail: detail))
        }
        for (id, locale) in absent {
            do {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber(for: locale)]) {
                    try await request.downloadAndInstall()
                }
                let ready = await isInstalled(locale)
                outcomes.append("\(id)=\(ready ? "installed" : "not-installed")")
            } catch {
                outcomes.append("\(id)=error")
                log.error("three-language: \(id, privacy: .public) model failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        guard !outcomes.isEmpty else { return }
        let detail = outcomes.joined(separator: " ")
        log.notice("three-language prepared \(detail, privacy: .public)")
        Record.append(Record(event: "prepared", detail: detail))
    }

    private static let log = Logger(subsystem: "anomaly.hex.mobile", category: "fork-three-language")

    struct UsableLocale: Sendable {
        let id: String
        let locale: Locale
    }

    static func usableLocales(for language: SpeechLanguage) async -> (lanes: [UsableLocale]?, skipped: String) {
        let enabled = TwoLanguageDictationSettings().isEnabled
        guard enabled, language.module == .speech else {
            let reason = skipReason(enabled: enabled, speechModule: language.module == .speech, primary: language.identifier, installed: [:])
            return (nil, reason ?? "")
        }
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
        }
        // A model reads as installed only to a process that reserved it, and the app and the
        // keyboard reserve apart: reserving first finds a model already on the iPhone.
        await keepReserved(locales.compactMap { resolved[$0] })
        for (id, locale) in resolved {
            let ready = await isInstalled(locale)
            installed[id] = ready && !settings.speechModuleFailed(id)
        }
        let primaryKey = primaryID ?? primary?.identifier(.bcp47)
        guard let ids = plan(enabled: enabled, primary: primaryKey, installed: installed) else {
            let reason = skipReason(enabled: enabled, speechModule: true, primary: primaryKey, installed: installed)
            return (nil, reason ?? "")
        }
        return (ids.compactMap { id in resolved[id].map { UsableLocale(id: id, locale: $0) } }, "")
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
