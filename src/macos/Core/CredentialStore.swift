import Foundation
import Security

public enum CredentialStoreError: LocalizedError, Sendable {
    case keychain(OSStatus)
    case missing

    public var errorDescription: String? {
        switch self {
        case .keychain(let status):
            return SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)."
        case .missing:
            return "No provider credential is configured."
        }
    }
}

public protocol CredentialStore: Sendable {
    func save(_ secret: String, account: String) async throws
    func load(account: String) async throws -> String
    func delete(account: String) async throws
}

public actor KeychainCredentialStore: CredentialStore {
    private let service: String

    public init(service: String = "com.openminis.runtime.providers") {
        self.service = service
    }

    public func save(_ secret: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(secret.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecItemNotFound {
            var item = query
            for (key, value) in attributes { item[key] = value }
            let status = SecItemAdd(item as CFDictionary, nil)
            guard status == errSecSuccess else { throw CredentialStoreError.keychain(status) }
        } else if update != errSecSuccess {
            throw CredentialStoreError.keychain(update)
        }
    }

    public func load(account: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { throw CredentialStoreError.missing }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw CredentialStoreError.keychain(status)
        }
        return value
    }

    public func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialStoreError.keychain(status) }
    }
}

public actor InMemoryCredentialStore: CredentialStore {
    private var values: [String: String] = [:]
    public init() {}
    public func save(_ secret: String, account: String) { values[account] = secret }
    public func load(account: String) throws -> String { guard let value = values[account] else { throw CredentialStoreError.missing }; return value }
    public func delete(account: String) { values.removeValue(forKey: account) }
}
