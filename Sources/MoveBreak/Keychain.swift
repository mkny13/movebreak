import Foundation
import Security

/// Typed errors produced during Keychain operations.
/// Deliberately omits secret material from error descriptions and diagnostics.
enum KeychainError: Error, LocalizedError, CustomStringConvertible, Equatable {
    case itemNotFound(account: String, service: String)
    case addFailed(status: OSStatus)
    case updateFailed(status: OSStatus)
    case readFailed(status: OSStatus)
    case deleteFailed(status: OSStatus)
    case decodingFailed

    var description: String {
        switch self {
        case .itemNotFound(let account, let service):
            return "Keychain item not found for account '\(account)' in service '\(service)'"
        case .addFailed(let status):
            let msg = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Failed to add Keychain item (\(msg))"
        case .updateFailed(let status):
            let msg = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Failed to update Keychain item (\(msg))"
        case .readFailed(let status):
            let msg = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Failed to read Keychain item (\(msg))"
        case .deleteFailed(let status):
            let msg = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Failed to delete Keychain item (\(msg))"
        case .decodingFailed:
            return "Failed to decode Keychain data as UTF-8 string"
        }
    }

    var errorDescription: String? {
        description
    }
}

/// Pluggable backend for Keychain operations, enabling isolated testing without
/// touching the owner's Keychain.
protocol KeychainStorageBackend: AnyObject {
    func get(account: String, service: String) throws -> Data?
    func set(data: Data, account: String, service: String) throws
    func delete(account: String, service: String) throws
}

/// Standard system Keychain backend using Security framework.
/// Uses `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` for device-local storage
/// suitable for a login-time desktop app.
final class SystemKeychainBackend: KeychainStorageBackend {
    func set(data: Data, account: String, service: String) throws {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return
        }

        if addStatus == errSecDuplicateItem {
            let updateAttributes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updateAttributes as CFDictionary)
            if updateStatus != errSecSuccess {
                throw KeychainError.updateFailed(status: updateStatus)
            }
            return
        }

        throw KeychainError.addFailed(status: addStatus)
    }

    func get(account: String, service: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError.readFailed(status: status)
        }
        guard let data = result as? Data else {
            throw KeychainError.decodingFailed
        }
        return data
    }

    func delete(account: String, service: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw KeychainError.deleteFailed(status: status)
        }
    }
}

/// Minimal Keychain wrapper for explicitly named integration credentials.
enum Keychain {
    static var backend: KeychainStorageBackend = SystemKeychainBackend()

    @discardableResult
    static func withBackend<T>(_ testBackend: KeychainStorageBackend, perform: () throws -> T) rethrows -> T {
        let previous = backend
        backend = testBackend
        defer { backend = previous }
        return try perform()
    }

    static func set(_ value: String, forAccount account: String, service: String) throws {
        let data = Data(value.utf8)
        try backend.set(data: data, account: account, service: service)
    }

    static func get(forAccount account: String, service: String) throws -> String? {
        guard let data = try backend.get(account: account, service: service) else {
            return nil
        }
        guard let string = String(data: data, encoding: .utf8) else {
            throw KeychainError.decodingFailed
        }
        return string
    }

    static func delete(forAccount account: String, service: String) throws {
        try backend.delete(account: account, service: service)
    }
}
