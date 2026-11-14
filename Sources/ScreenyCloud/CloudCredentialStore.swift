import Foundation
import Security

/// Endpoint in UserDefaults, upload secret in the Keychain (generic password).
final class CloudCredentialStore: @unchecked Sendable {
    static let endpointKey = "ScreenyPro.cloud.endpoint"
    static let account = "upload-secret"

    private let defaults: UserDefaults
    private let service: String

    init(defaults: UserDefaults, service: String) {
        self.defaults = defaults
        self.service = service
    }

    var endpoint: URL? {
        get { defaults.string(forKey: Self.endpointKey).flatMap(URL.init(string:)) }
        set {
            if let newValue { defaults.set(newValue.absoluteString, forKey: Self.endpointKey) }
            else { defaults.removeObject(forKey: Self.endpointKey) }
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
        ]
    }

    func readSecret() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let text = String(data: data, encoding: .utf8), !text.isEmpty else { return nil }
            return text
        case errSecItemNotFound:
            return nil
        default:
            throw CloudError.keychain(status)
        }
    }

    func writeSecret(_ secret: String) throws {
        let data = Data(secret.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            add[kSecAttrLabel as String] = "ScreenyPro cloud upload secret"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CloudError.keychain(status) }
    }

    func deleteSecret() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
