import Foundation

/// Three-language dictation's English words (fork): once a Chinese reading wins, the words it
/// already wrote in Latin letters are respelled the way the en-US reading heard them over the same
/// audio (`Clian` → `client`, `branchmerge` → `branch merge`). Chinese characters, digits, and
/// punctuation are never touched: the en-US reading's confidence doesn't tell its English words from
/// Chinese it heard as English (`的` → "the" at 0.82), but a Chinese reading that writes Latin
/// letters heard English there too. Reads only the readings `ForkThreeLanguage.transcribe` already
/// has, so it runs no recogniser; without an en-US reading the chosen text is returned as it is.
/// Thresholds come from 262 synthetic qa- clips (HEX-32), the conservative set.
@available(iOS 26.0, *)
nonisolated enum ForkThreeLanguageEnglishWords {
    struct Repaired: Equatable, Sendable {
        /// What to insert.
        let text: String
        /// How many Latin words were respelled, for `ForkThreeLanguage.Record`.
        let replaced: Int
    }

    /// How much of the shorter of a Latin word and its en-US words the two share.
    static let minimumOverlap = 0.6
    /// How much of each en-US word must fall inside the Latin word to count as one of its words.
    static let englishInside = 0.5
    /// en-US words one Latin word may become (`branchmerge` is two).
    static let maximumEnglishWords = 3
    /// A Latin word the Chinese reading is this sure of is kept.
    static let keptConfidence = 0.9
    static let minimumEnglishConfidence = 0.5
    /// How much less sure than the Chinese reading en-US may be: its confidence is lower inside
    /// Chinese speech even where it is right (`client` 0.64 against `Clian` 0.75).
    static let confidenceMargin = 0.15
    /// Spelling similarity (1 − edit distance / longer length) a misspelling needs.
    static let minimumSimilarity = 0.55
    /// A real word is replaced only when it is the start of en-US's (`prom` → `prompt`) or the
    /// other way round, and only while the Chinese reading is at most this sure of it.
    static let truncatedConfidence = 0.85
    /// The other Chinese reading votes for en-US when it spells the word this much like en-US,
    /// and `voteLead` more like en-US than like the chosen reading.
    static let voteSimilarity = 0.7
    static let voteLead = 0.15
    static let voteEnglishConfidence = 0.3
    static let minimumLetters = 3
    static let stopWords: Set<String> = [
        "a", "an", "the", "to", "of", "in", "on", "at", "is", "it", "i", "me", "my", "you", "your",
        "he", "she", "we", "they", "them", "no", "yes", "so", "and", "or", "but", "for", "by", "be",
        "do", "go", "oh", "ah", "uh", "um", "well", "hi", "hey", "her", "his", "its", "our", "us",
        "up", "as", "if", "this", "that", "there", "here", "what", "who", "how", "why", "with",
        "from", "are", "was", "were", "has", "have", "can", "will", "not", "nor", "yet", "did",
        "la", "ho",
    ]

    /// `chosen` with its Latin words respelled from the en-US reading among `lanes`. Nothing
    /// changes when `chosen` is the en-US reading, there is no en-US reading with words, or the
    /// chosen words don't add up to its text. `isEnglishWord` says whether a spelling is an
    /// English word; the words of `vocabulary` count as English and are never respelled.
    static func repair(
        _ chosen: ForkThreeLanguage.Lane?,
        among lanes: [ForkThreeLanguage.Lane],
        vocabulary: [String],
        isEnglishWord: (String) -> Bool
    ) -> Repaired {
        guard let chosen else { return Repaired(text: "", replaced: 0) }
        let unchanged = Repaired(text: chosen.text, replaced: 0)
        guard chosen.locale != "en-US",
              let english = lanes.first(where: { $0.locale == "en-US" }), !english.words.isEmpty,
              chosen.words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines) == chosen.text
        else { return unchanged }
        let other = lanes.first { $0.locale != chosen.locale && $0.locale != "en-US" }
        var spellings: [String: String] = [:]
        for entry in vocabulary where !normalized(entry).isEmpty {
            spellings[normalized(entry)] = entry
        }
        func known(_ word: String) -> Bool {
            spellings[normalized(word)] != nil || isAcronym(word, letters: 2...5)
                || (word.count >= 2 && (isEnglishWord(word) || isEnglishWord(word.lowercased())))
        }
        let heard = english.words.filter { latinCore(of: $0.text) != nil }
        func spelling(_ run: ArraySlice<TwoLanguageTimedWord>) -> String {
            run.compactMap { latinCore(of: $0.text) }.joined(separator: " ")
        }

        var texts = chosen.words.map(\.text)
        var replaced = 0
        for (index, word) in chosen.words.enumerated() {
            guard let core = latinWord(word), !core.contains(where: \.isNumber) else { continue }
            let candidates = heard.filter { overlap($0, word) / duration($0) >= englishInside }
            guard !candidates.isEmpty, candidates.count <= maximumEnglishWords else { continue }
            // The consecutive en-US words spelled most like the Latin word, longest first on a tie,
            // so an en-US word that is really the next character ("Hui" for 會) isn't added.
            let runs = (1...candidates.count).reversed().flatMap { length in
                (0...(candidates.count - length)).map { candidates[$0..<($0 + length)] }
            }
            guard let run = runs.max(by: { similarity(core, spelling($0)) < similarity(core, spelling($1)) }),
                  run.reduce(0, { $0 + overlap($1, word) })
                      / min(duration(word), run.reduce(0, { $0 + duration($1) })) >= minimumOverlap
            else { continue }
            let cores = run.compactMap { latinCore(of: $0.text) }
            let proposal = spelling(run)
            let confidence = run.map(\.confidence).min() ?? 0
            guard proposal.lowercased() != core.lowercased(),
                  word.confidence < keptConfidence,
                  spellings[normalized(core)] == nil,
                  !isAcronym(core, letters: 1...5)
            else { continue }
            let voter = other?.words.first {
                latinWord($0) != nil && overlap($0, word) / min(duration($0), duration(word)) >= 0.5
            }.flatMap { latinWord($0) }
            if let voter, voter.lowercased() == core.lowercased() { continue }
            guard cores.allSatisfy({ candidate in
                let key = normalized(candidate)
                return spellings[key] != nil || (!stopWords.contains(key) && key.count >= minimumLetters)
            }), cores.allSatisfy(known) else { continue }

            let vote = voter.map {
                similarity($0, proposal) >= voteSimilarity
                    && similarity($0, proposal) - similarity($0, core) >= voteLead
                    && confidence >= voteEnglishConfidence
            } ?? false
            let fix: Bool
            if known(core) {
                // A real word is never split: "without" isn't "with out".
                guard run.count == 1 else { continue }
                let (written, spoken) = (normalized(core), normalized(proposal))
                fix = written.count >= minimumLetters && (spoken.hasPrefix(written) || written.hasPrefix(spoken))
                    && confidence >= minimumEnglishConfidence && confidence >= word.confidence
                    && word.confidence <= truncatedConfidence
            } else {
                fix = similarity(core, proposal) >= minimumSimilarity
                    && confidence >= minimumEnglishConfidence
                    && confidence >= word.confidence - confidenceMargin
            }
            guard fix || vote else { continue }

            var spelling = cores.map { spellings[normalized($0)] ?? $0 }.joined(separator: " ")
            if !(core.first?.isUppercase ?? false), spelling.first?.isUppercase ?? false,
               spellings[normalized(cores[0])] == nil {
                spelling = spelling.prefix(1).lowercased() + spelling.dropFirst()
            }
            guard let range = latinRange(in: word.text) else { continue }
            texts[index] = word.text.replacingCharacters(in: range, with: spelling)
            replaced += 1
        }
        guard replaced > 0 else { return unchanged }
        return Repaired(text: texts.joined().trimmingCharacters(in: .whitespacesAndNewlines), replaced: replaced)
    }

    /// The word's Latin spelling when it is a Latin word: Latin letters and no Chinese characters.
    private static func latinWord(_ word: TwoLanguageTimedWord) -> String? {
        guard !word.text.unicodeScalars.contains(where: isHan) else { return nil }
        return latinCore(of: word.text)
    }

    /// The first run of a Latin letter followed by letters, digits, and apostrophes between letters.
    private static func latinCore(of text: String) -> String? {
        latinRange(in: text).map { String(text[$0]) }
    }

    private static func latinRange(in text: String) -> Range<String.Index>? {
        guard let start = text.firstIndex(where: isLatinLetter) else { return nil }
        var end = text.index(after: start)
        while end < text.endIndex {
            let next = text.index(after: end)
            guard isLatinLetter(text[end]) || text[end].isASCII && text[end].isNumber
                || text[end] == "'" && next < text.endIndex && isLatinLetter(text[next])
            else { break }
            end = next
        }
        return start..<end
    }

    private static func isLatinLetter(_ character: Character) -> Bool {
        character.isASCII && character.isLetter
    }

    private static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        (0x3400...0x9FFF).contains(scalar.value) || (0xF900...0xFAFF).contains(scalar.value)
    }

    private static func isAcronym(_ word: String, letters: ClosedRange<Int>) -> Bool {
        letters.contains(word.count) && word == word.uppercased() && word != word.lowercased()
    }

    /// Lowercase letters and digits only: how spellings, the vocabulary, and stop words compare.
    private static func normalized(_ word: String) -> String {
        String(word.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) })
    }

    private static func similarity(_ first: String, _ second: String) -> Double {
        let a = Array(normalized(first)), b = Array(normalized(second))
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return 1 - Double(previous[b.count]) / Double(max(a.count, b.count))
    }

    private static func overlap(_ first: TwoLanguageTimedWord, _ second: TwoLanguageTimedWord) -> Double {
        max(0, min(first.end, second.end) - max(first.start, second.start))
    }

    private static func duration(_ word: TwoLanguageTimedWord) -> Double {
        max(0.001, word.end - word.start)
    }
}

#if canImport(UIKit)
@available(iOS 26.0, *)
extension ForkThreeLanguageEnglishWords {
    /// `repair` against the English words of Hex's own typing model (`en.hextm`), mapped once per
    /// process on the main actor and read off it. Not UIKit's dictionary: its first lookup of a
    /// misspelling in a process takes about 0.4 s on the main actor (iOS 27.2 simulator). Without an
    /// en-US reading or a Latin word in the chosen one, the model isn't read.
    static func repair(
        _ chosen: ForkThreeLanguage.Lane?,
        among lanes: [ForkThreeLanguage.Lane],
        vocabulary: [String]
    ) async -> Repaired {
        guard let chosen, chosen.locale != "en-US",
              lanes.contains(where: { $0.locale == "en-US" && !$0.words.isEmpty }),
              chosen.words.contains(where: { latinWord($0) != nil }),
              let english = await MainActor.run(body: { TypingDecoderModel.bundled("en") })
        else { return Repaired(text: chosen?.text ?? "", replaced: 0) }
        return repair(chosen, among: lanes, vocabulary: vocabulary) { english.index(of: $0.lowercased()) != nil }
    }
}
#endif
