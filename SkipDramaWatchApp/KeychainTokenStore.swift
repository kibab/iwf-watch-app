import Foundation
import OSLog
import Security

enum KeychainError: LocalizedError, Sendable, Equatable {
    case unexpectedStatus(OSStatus)
    case invalidToken

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            return "Keychain error (\(status))"
        case .invalidToken:
            return "Invalid token"
        }
    }
}

/// Securely stores the Watch capture Bearer token and non-sensitive token metadata in the Keychain.
///
/// Uses `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` so background `URLSession` uploads,
/// Smart Stack widgets/complications, and Action Button quick launches can read the token even
/// when the Apple Watch screen dims or locks.
struct KeychainTokenStore: Sendable {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.iwf.quickcapture",
        category: "KeychainTokenStore"
    )

    private static let defaultService = "com.iwf.quickcapture.watchkitapp.token"
    private static let tokenAccount = "capture_token"
    private static let lastCharsAccount = "capture_token_last4"
    private static let deviceNameAccount = "capture_token_name"

    private let service: String

    init(service: String = KeychainTokenStore.defaultService) {
        self.service = service
    }

    var hasToken: Bool {
        guard let token = readToken() else { return false }
        return !token.isEmpty
    }

    func saveToken(_ token: String, lastChars: String? = nil, deviceName: String? = nil) throws {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            throw KeychainError.invalidToken
        }

        try upsert(value: trimmedToken, account: Self.tokenAccount)

        let derivedLastChars = nonEmpty(lastChars) ?? String(trimmedToken.suffix(4))
        if !derivedLastChars.isEmpty {
            try upsert(value: derivedLastChars, account: Self.lastCharsAccount)
        } else {
            deleteValue(account: Self.lastCharsAccount)
        }

        if let deviceName = nonEmpty(deviceName) {
            try upsert(value: deviceName, account: Self.deviceNameAccount)
        } else {
            deleteValue(account: Self.deviceNameAccount)
        }
    }

    func readToken() -> String? {
        nonEmpty(readValue(account: Self.tokenAccount))
    }

    func readLastChars() -> String? {
        if let stored = nonEmpty(readValue(account: Self.lastCharsAccount)) {
            return stored
        }
        if let token = readToken() {
            return String(token.suffix(4))
        }
        return nil
    }

    func readDeviceName() -> String? {
        nonEmpty(readValue(account: Self.deviceNameAccount))
    }

    func deleteToken() {
        deleteValue(account: Self.tokenAccount)
        deleteValue(account: Self.lastCharsAccount)
        deleteValue(account: Self.deviceNameAccount)
    }

    // MARK: - Keychain Operations

    private func upsert(value: String, account: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.invalidToken
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let existingStatus = SecItemCopyMatching(query as CFDictionary, nil)
        switch existingStatus {
        case errSecSuccess:
            let attributesToUpdate: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ]
            let updateStatus = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)
            if updateStatus != errSecSuccess {
                Self.logger.error("SecItemUpdate failed for account \(account, privacy: .public): \(updateStatus)")
                throw KeychainError.unexpectedStatus(updateStatus)
            }
        case errSecItemNotFound:
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus != errSecSuccess {
                Self.logger.error("SecItemAdd failed for account \(account, privacy: .public): \(addStatus)")
                throw KeychainError.unexpectedStatus(addStatus)
            }
        default:
            // Fall back to delete-then-add if item metadata is in an unexpected state.
            SecItemDelete(query as CFDictionary)
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus != errSecSuccess {
                Self.logger.error("SecItemAdd fallback failed for account \(account, privacy: .public): \(addStatus)")
                throw KeychainError.unexpectedStatus(addStatus)
            }
        }
    }

    private func readValue(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8) else {
            if status != errSecItemNotFound && status != errSecSuccess {
                Self.logger.error("SecItemCopyMatching failed for account \(account, privacy: .public): \(status)")
            }
            return nil
        }
        return string
    }

    private func deleteValue(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            Self.logger.warning("SecItemDelete failed for account \(account, privacy: .public): \(status)")
        }
    }

    private func nonEmpty(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

