import Foundation
import Security

/// The Dropline private API provider's settings, in the App Group so the keyboard reads
/// them too: the token endpoint, whether Dropline replaces the local engine, and the last
/// time a dictation fell back to the local engine. The bearer token lives in the Keychain
/// (`ForkDroplineKeychain`). Unchecked because UserDefaults is thread-safe but not marked Sendable.
nonisolated struct ForkDroplineSettings: @unchecked Sendable {
    static let providerName = "Dropline 私人 API"
    static let defaultEndpoint = "https://voice.veraze.io/v1/dropline-private/token"

    struct Fallback: Equatable {
        let reason: String
        let at: Date
    }

    private enum Key {
        static let endpoint = "fork.dropline.endpoint"
        static let enabled = "fork.dropline.enabled"
        static let fallbackReason = "fork.dropline.fallbackReason"
        static let fallbackAt = "fork.dropline.fallbackAt"
    }

    private let defaults: UserDefaults?

    init(defaults: UserDefaults? = UserDefaults(suiteName: KeyboardBridge.appGroup)) {
        self.defaults = defaults
    }

    var endpoint: URL? {
        get { defaults?.string(forKey: Key.endpoint).flatMap(URL.init(string:)) }
        nonmutating set { defaults?.set(newValue?.absoluteString, forKey: Key.endpoint) }
    }

    var isEnabled: Bool {
        get { defaults?.bool(forKey: Key.enabled) ?? false }
        nonmutating set { defaults?.set(newValue, forKey: Key.enabled) }
    }

    var lastFallback: Fallback? {
        guard let reason = defaults?.string(forKey: Key.fallbackReason),
              let at = defaults?.object(forKey: Key.fallbackAt) as? Double else { return nil }
        return Fallback(reason: reason, at: Date(timeIntervalSince1970: at))
    }

    func recordFallback(_ reason: String, at date: Date) {
        defaults?.set(reason, forKey: Key.fallbackReason)
        defaults?.set(date.timeIntervalSince1970, forKey: Key.fallbackAt)
    }

    func clear() {
        for key in [Key.endpoint, Key.enabled, Key.fallbackReason, Key.fallbackAt] {
            defaults?.removeObject(forKey: key)
        }
    }
}

/// Where the bearer token for the token endpoint is kept.
nonisolated protocol ForkDroplineSecretStore: Sendable {
    func bearer() -> String?
    func saveBearer(_ bearer: String) throws
    func deleteBearer()
}

nonisolated struct ForkDroplineKeychainError: Error, Equatable {
    let status: OSStatus
}

/// A generic password shared by the app and the keyboard through the App Group, which iOS
/// also treats as a keychain access group, so no keychain-access-groups entitlement is needed.
/// Readable after first unlock because the keyboard dictates on a locked iPhone.
nonisolated struct ForkDroplineKeychain: ForkDroplineSecretStore {
    static let service = "anomaly.hex.fork.dropline-private"
    static let account = "bearer"

    func bearer() -> String? {
        var item: CFTypeRef?
        var query = baseQuery(accessGroup: KeyboardBridge.appGroup)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var status = SecItemCopyMatching(query as CFDictionary, &item)
        if Self.retriesWithoutAccessGroup(status) {
            query[kSecAttrAccessGroup as String] = nil
            status = SecItemCopyMatching(query as CFDictionary, &item)
        }
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func saveBearer(_ bearer: String) throws {
        deleteBearer()
        var item = baseQuery(accessGroup: KeyboardBridge.appGroup)
        item[kSecValueData as String] = Data(bearer.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        var status = SecItemAdd(item as CFDictionary, nil)
        if Self.retriesWithoutAccessGroup(status) {
            item[kSecAttrAccessGroup as String] = nil
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ForkDroplineKeychainError(status: status) }
    }

    func deleteBearer() {
        SecItemDelete(baseQuery(accessGroup: KeyboardBridge.appGroup) as CFDictionary)
        #if targetEnvironment(simulator)
        SecItemDelete(baseQuery(accessGroup: nil) as CFDictionary)
        #endif
    }

    private func baseQuery(accessGroup: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    /// An unsigned simulator build has no App Group entitlement, so the Keychain refuses the
    /// access group; it falls back to the app's own items there only.
    private static func retriesWithoutAccessGroup(_ status: OSStatus) -> Bool {
        #if targetEnvironment(simulator)
        return status == errSecMissingEntitlement
        #else
        return false
        #endif
    }
}
