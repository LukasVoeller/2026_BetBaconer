import Foundation
import Security

enum KeychainSecretStoreError: LocalizedError {
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .unexpectedStatus(status):
            return "Keychain-Zugriff fehlgeschlagen (\(status))."
        }
    }
}

struct KeychainSecretStore {
    /// Service name used while the app ran unbundled (`swift run`); secrets saved there are migrated once.
    static let legacyService = "BetBaconer"

    private let service: String
    private let migrateFrom: String?

    init(service: String = Bundle.main.bundleIdentifier ?? KeychainSecretStore.legacyService, migrateFrom: String? = KeychainSecretStore.legacyService) {
        self.service = service
        self.migrateFrom = migrateFrom == service ? nil : migrateFrom
    }

    func loadSecret(account: String) throws -> String? {
        if let value = try loadSecret(account: account, service: service) {
            return value
        }
        guard let migrateFrom, let legacy = try loadSecret(account: account, service: migrateFrom) else {
            return nil
        }
        try saveSecret(legacy, account: account)
        return legacy
    }

    private func loadSecret(account: String, service: String) throws -> String? {
        var query = baseQuery(account: account, service: service)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainSecretStoreError.unexpectedStatus(status)
        }
    }

    func saveSecret(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let query = baseQuery(account: account)
        let attributes = [kSecValueData as String: data]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var insertQuery = query
            insertQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(insertQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainSecretStoreError.unexpectedStatus(addStatus)
            }
        default:
            throw KeychainSecretStoreError.unexpectedStatus(updateStatus)
        }
    }

    func deleteSecret(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainSecretStoreError.unexpectedStatus(status)
        }
    }

    private func baseQuery(account: String, service: String? = nil) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service ?? self.service,
            kSecAttrAccount as String: account,
        ]
    }
}
