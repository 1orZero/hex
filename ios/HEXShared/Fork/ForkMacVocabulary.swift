import Foundation

/// Hex fork (see FORK.md): the Mac's vocabulary on this iPhone, one way. Each night
/// `fork/daily.sh` copies the Mac's terms, in the Mac's order, into the App Group as
/// `Library/fork-mac-vocabulary.json` (`{"terms": [...]}`), and the app and the keyboard fold a
/// new copy into Hex's list (`CustomVocabularySettings`) the next time they come on screen.
///
/// The list keeps the iPhone's own terms first, then the Mac's in its order while the list holds
/// `listLimit` terms, which leaves room under the 100-term cap for terms added here before the
/// next copy. Every iOS reader (Apple's contextual strings, spelling, the keys) reads the whole
/// list; upstream's writers enforce the cap by dropping the end, so the iPhone's own terms go
/// first. The terms that came from the Mac are recorded, so a later copy removes the ones the Mac
/// no longer lists and never removes the iPhone's own.
nonisolated enum ForkMacVocabulary {
    static let relativePath = "Library/fork-mac-vocabulary.json"
    static let listLimit = 90
    static let syncedKey = "fork.macVocabulary.synced"
    static let appliedKey = "fork.macVocabulary.applied"

    private struct Copy: Decodable {
        let terms: [String]
    }

    static var copyURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: KeyboardBridge.appGroup)?
            .appendingPathComponent(relativePath)
    }

    /// Folds in the Mac's copy, once per copy. True when Hex's list changed.
    @discardableResult
    static func apply(
        from url: URL? = copyURL,
        defaults: UserDefaults? = UserDefaults(suiteName: KeyboardBridge.appGroup)
    ) -> Bool {
        guard let url, let defaults, let data = try? Data(contentsOf: url),
              let mac = try? JSONDecoder().decode(Copy.self, from: data).terms,
              defaults.stringArray(forKey: appliedKey) != mac else { return false }
        let settings = CustomVocabularySettings(defaults: defaults)
        let before = settings.terms
        let merged = merge(current: before, synced: defaults.stringArray(forKey: syncedKey) ?? [], mac: mac)
        settings.terms = merged.terms
        defaults.set(merged.synced, forKey: syncedKey)
        defaults.set(mac, forKey: appliedKey)
        return merged.terms != before
    }

    /// The iPhone's own terms (those not recorded as the Mac's) in their order, then the Mac's
    /// terms the list accepts, in the Mac's order, while the list holds `listLimit`.
    static func merge(current: [String], synced: [String], mac: [String]) -> (terms: [String], synced: [String]) {
        let fromMac = Set(synced.map(VocabularySpelling.normalizedKey))
        let own = current.filter { !fromMac.contains(VocabularySpelling.normalizedKey($0)) }
        let room = max(0, listLimit - own.count)
        let picked = Array(CustomVocabularySettings.sanitize(own + mac).dropFirst(own.count).prefix(room))
        return (own + picked, picked)
    }
}
