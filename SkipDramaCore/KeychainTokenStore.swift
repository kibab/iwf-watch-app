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

/// Securely stores the SkipDrama capture Bearer token (`iwf_cap_...`) and non-sensitive token metadata.
///
/// Uses `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` inside the shared Keychain Access Group
/// (`$(AppIdentifierPrefix)app.skipdrama.shared`) so the iOS app, Share Extension, Control/Widget
/// extensions, and watchOS app can read the token even while the device is locked or running background
/// App Intents.
struct KeychainTokenStore: Sendable {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.skipdrama",
        category: "KeychainTokenStore"
    )

    static let defaultService = "app.skipdrama.shared.token"
    private static let legacyWatchService = "app.skipdrama.watchkitapp.token"

    private static let tokenAccount = "capture_token"
    private static let lastCharsAccount = "capture_token_last4"
    private static let deviceNameAccount = "capture_token_name"

    private static let sharedTokenDefaultsKey = "app.skipdrama.sharedMirror.token"
    private static let sharedLastCharsDefaultsKey = "app.skipdrama.sharedMirror.last4"
    private static let sharedDeviceNameDefaultsKey = "app.skipdrama.sharedMirror.deviceName"

    private let service: String

    init(service: String = KeychainTokenStore.defaultService) {
        self.service = service
    }

    static func isValidTokenFormat(_ raw: String) -> Bool {
        !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func isValidManualToken(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("iwf_cap_") && trimmed.count > 8
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

        try upsert(value: trimmedToken, account: Self.tokenAccount, service: service)

        let derivedLastChars = nonEmpty(lastChars) ?? String(trimmedToken.suffix(4))
        if !derivedLastChars.isEmpty {
            try upsert(value: derivedLastChars, account: Self.lastCharsAccount, service: service)
        } else {
            deleteValue(account: Self.lastCharsAccount, service: service)
        }

        let trimmedDeviceName = nonEmpty(deviceName)
        if let trimmedDeviceName {
            try upsert(value: trimmedDeviceName, account: Self.deviceNameAccount, service: service)
        } else {
            deleteValue(account: Self.deviceNameAccount, service: service)
        }

        // Mirror to shared App Group UserDefaults as a fallback for unsigned simulator builds / extensions.
        let defaults = Config.sharedDefaults
        defaults.set(trimmedToken, forKey: Self.sharedTokenDefaultsKey)
        defaults.set(derivedLastChars, forKey: Self.sharedLastCharsDefaultsKey)
        if let trimmedDeviceName {
            defaults.set(trimmedDeviceName, forKey: Self.sharedDeviceNameDefaultsKey)
        } else {
            defaults.removeObject(forKey: Self.sharedDeviceNameDefaultsKey)
        }
    }

    func readToken() -> String? {
        if let primary = nonEmpty(readValue(account: Self.tokenAccount, service: service)) {
            return primary
        }

        if service == Self.defaultService,
           let legacy = nonEmpty(readValue(account: Self.tokenAccount, service: Self.legacyWatchService)) {
            let legacyLastChars = nonEmpty(readValue(account: Self.lastCharsAccount, service: Self.legacyWatchService))
            let legacyName = nonEmpty(readValue(account: Self.deviceNameAccount, service: Self.legacyWatchService))
            try? saveToken(legacy, lastChars: legacyLastChars, deviceName: legacyName)
            return legacy
        }

        if let mirrored = nonEmpty(Config.sharedDefaults.string(forKey: Self.sharedTokenDefaultsKey)) {
            return mirrored
        }

        return nil
    }

    func readLastChars() -> String? {
        if let stored = nonEmpty(readValue(account: Self.lastCharsAccount, service: service)) {
            return stored
        }
        if let mirrored = nonEmpty(Config.sharedDefaults.string(forKey: Self.sharedLastCharsDefaultsKey)) {
            return mirrored
        }
        if let token = readToken() {
            return String(token.suffix(4))
        }
        return nil
    }

    func readDeviceName() -> String? {
        if let stored = nonEmpty(readValue(account: Self.deviceNameAccount, service: service)) {
            return stored
        }
        return nonEmpty(Config.sharedDefaults.string(forKey: Self.sharedDeviceNameDefaultsKey))
    }

    func deleteToken() {
        deleteValue(account: Self.tokenAccount, service: service)
        deleteValue(account: Self.lastCharsAccount, service: service)
        deleteValue(account: Self.deviceNameAccount, service: service)

        if service == Self.defaultService {
            deleteValue(account: Self.tokenAccount, service: Self.legacyWatchService)
            deleteValue(account: Self.lastCharsAccount, service: Self.legacyWatchService)
            deleteValue(account: Self.deviceNameAccount, service: Self.legacyWatchService)
        }

        let defaults = Config.sharedDefaults
        defaults.removeObject(forKey: Self.sharedTokenDefaultsKey)
        defaults.removeObject(forKey: Self.sharedLastCharsDefaultsKey)
        defaults.removeObject(forKey: Self.sharedDeviceNameDefaultsKey)
    }

    // MARK: - Keychain Operations

    private func upsert(value: String, account: String, service: String) throws {
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

    private func readValue(account: String, service: String) -> String? {
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

    private func deleteValue(account: String, service: String) {
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
