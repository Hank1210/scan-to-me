import Foundation
import Security

/// Geheimnisse im Anmelde-Schlüsselbund des Benutzers. Werte werden nie in Dateien oder Protokolle geschrieben.
public struct KeychainStore: Sendable {
    public let service: String
    public let account: String
    public let label: String

    public init(service: String, account: String, label: String) {
        self.service = service
        self.account = account
        self.label = label
    }

    /// Der Anthropic-API-Schlüssel von Scan to me.
    public static let anthropicAPIKey = KeychainStore(
        service: "io.github.scantome.app", account: "anthropic-api-key", label: "Scan to me – Anthropic API-Schlüssel")

    private var baseQuery: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }

    public func read() -> String? {
        var query = baseQuery
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let value = String(data: data, encoding: .utf8), !value.isEmpty
        else { return nil }
        return value
    }

    @discardableResult
    public func save(_ value: String) -> Bool {
        SecItemDelete(baseQuery as CFDictionary)
        var add = baseQuery
        add[kSecValueData] = Data(value.utf8)
        add[kSecAttrLabel] = label
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    public func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
