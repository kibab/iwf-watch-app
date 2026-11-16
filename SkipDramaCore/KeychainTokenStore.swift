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
/// Stores items with `kSecAttrSynchronizable = true` and `kSecAttrAccessibleAfterFirstUnlock` inside
/// the shared Keychain Access Group (`$(AppIdentifierPrefix)app.skipdrama.shared`) so tokens sync
/// automatically across the user's iPhone and iPad via iCloud Keychain and remain accessible to
/// extensions, background App Intents, and widgets on each device.
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

        mirrorToSharedDefaults(
            token: trimmedToken,
            lastChars: derivedLastChars,
            deviceName: trimmedDeviceName
        )
    }

    func readToken() -> String? {
        if let synced = nonEmpty(readValue(account: Self.tokenAccount, service: service, synchronizable: kCFBooleanTrue)) {
            let syncedLastChars = nonEmpty(readValue(account: Self.lastCharsAccount, service: service, synchronizable: kCFBooleanTrue))
                ?? String(synced.suffix(4))
            let syncedDeviceName = nonEmpty(readValue(account: Self.deviceNameAccount, service: service, synchronizable: kCFBooleanTrue))
            mirrorToSharedDefaultsIfNeeded(token: synced, lastChars: syncedLastChars, deviceName: syncedDeviceName)
            return synced
        }

        // Auto-migrate existing non-synchronizable token items into iCloud Keychain.
        if let local = nonEmpty(readValue(account: Self.tokenAccount, service: service, synchronizable: kCFBooleanFalse)) {
            let localLastChars = nonEmpty(readValue(account: Self.lastCharsAccount, service: service, synchronizable: kCFBooleanFalse))
                ?? nonEmpty(Config.sharedDefaults.string(forKey: Self.sharedLastCharsDefaultsKey))
            let localDeviceName = nonEmpty(readValue(account: Self.deviceNameAccount, service: service, synchronizable: kCFBooleanFalse))
                ?? nonEmpty(Config.sharedDefaults.string(forKey: Self.sharedDeviceNameDefaultsKey))
            try? saveToken(local, lastChars: localLastChars, deviceName: localDeviceName)
            return local
        }

        if service == Self.defaultService,
           let legacy = nonEmpty(readValue(account: Self.tokenAccount, service: Self.legacyWatchService, synchronizable: kSecAttrSynchronizableAny)) {
            let legacyLastChars = nonEmpty(readValue(account: Self.lastCharsAccount, service: Self.legacyWatchService, synchronizable: kSecAttrSynchronizableAny))
            let legacyName = nonEmpty(readValue(account: Self.deviceNameAccount, service: Self.legacyWatchService, synchronizable: kSecAttrSynchronizableAny))
            if (try? saveToken(legacy, lastChars: legacyLastChars, deviceName: legacyName)) != nil {
                deleteValue(account: Self.tokenAccount, service: Self.legacyWatchService)
                deleteValue(account: Self.lastCharsAccount, service: Self.legacyWatchService)
                deleteValue(account: Self.deviceNameAccount, service: Self.legacyWatchService)
            }
            return legacy
        }

        if let mirrored = nonEmpty(Config.sharedDefaults.string(forKey: Self.sharedTokenDefaultsKey)) {
            let mirroredLastChars = nonEmpty(Config.sharedDefaults.string(forKey: Self.sharedLastCharsDefaultsKey))
            let mirroredDeviceName = nonEmpty(Config.sharedDefaults.string(forKey: Self.sharedDeviceNameDefaultsKey))
            try? saveToken(mirrored, lastChars: mirroredLastChars, deviceName: mirroredDeviceName)
            return mirrored
        }

        return nil
    }

    func readLastChars() -> String? {
        if let synced = nonEmpty(readValue(account: Self.lastCharsAccount, service: service, synchronizable: kCFBooleanTrue)) {
            return synced
        }
        if let local = nonEmpty(readValue(account: Self.lastCharsAccount, service: service, synchronizable: kCFBooleanFalse)) {
            return local
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
        if let synced = nonEmpty(readValue(account: Self.deviceNameAccount, service: service, synchronizable: kCFBooleanTrue)) {
            return synced
        }
        if let local = nonEmpty(readValue(account: Self.deviceNameAccount, service: service, synchronizable: kCFBooleanFalse)) {
            return local
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

        do {
            try upsertItem(
                data: data,
                account: account,
                service: service,
                synchronizable: kCFBooleanTrue,
                accessible: kSecAttrAccessibleAfterFirstUnlock
            )
            // Remove any stale local-only item so it does not shadow the iCloud-synced record.
            deleteValue(account: account, service: service, synchronizable: kCFBooleanFalse)
        } catch {
            Self.logger.notice("Synchronizable Keychain write failed for \(account, privacy: .public), falling back to local Keychain: \(error.localizedDescription, privacy: .public)")
            try upsertItem(
                data: data,
                account: account,
                service: service,
                synchronizable: kCFBooleanFalse,
                accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            )
        }
    }

    private func upsertItem(
        data: Data,
        account: String,
        service: String,
        synchronizable: CFBoolean,
        accessible: CFString
    ) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: synchronizable
        ]

        let existingStatus = SecItemCopyMatching(query as CFDictionary, nil)
        switch existingStatus {
        case errSecSuccess:
            let attributesToUpdate: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: accessible
            ]
            let updateStatus = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)
            if updateStatus != errSecSuccess {
                Self.logger.error("SecItemUpdate failed for account \(account, privacy: .public): \(updateStatus)")
                throw KeychainError.unexpectedStatus(updateStatus)
            }
        case errSecItemNotFound:
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = accessible
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus != errSecSuccess {
                Self.logger.error("SecItemAdd failed for account \(account, privacy: .public): \(addStatus)")
                throw KeychainError.unexpectedStatus(addStatus)
            }
        default:
            SecItemDelete(query as CFDictionary)
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = accessible
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus != errSecSuccess {
                Self.logger.error("SecItemAdd fallback failed for account \(account, privacy: .public): \(addStatus)")
                throw KeychainError.unexpectedStatus(addStatus)
            }
        }
    }

    private func readValue(account: String, service: String, synchronizable: CFTypeRef) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: synchronizable,
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

    private func deleteValue(account: String, service: String, synchronizable: CFTypeRef = kSecAttrSynchronizableAny) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: synchronizable
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            Self.logger.warning("SecItemDelete failed for account \(account, privacy: .public): \(status)")
        }
    }

    private func mirrorToSharedDefaultsIfNeeded(token: String, lastChars: String, deviceName: String?) {
        let defaults = Config.sharedDefaults
        if defaults.string(forKey: Self.sharedTokenDefaultsKey) != token
            || defaults.string(forKey: Self.sharedLastCharsDefaultsKey) != lastChars
            || defaults.string(forKey: Self.sharedDeviceNameDefaultsKey) != deviceName {
            mirrorToSharedDefaults(token: token, lastChars: lastChars, deviceName: deviceName)
        }
    }

    private func mirrorToSharedDefaults(token: String, lastChars: String, deviceName: String?) {
        let defaults = Config.sharedDefaults
        defaults.set(token, forKey: Self.sharedTokenDefaultsKey)
        defaults.set(lastChars, forKey: Self.sharedLastCharsDefaultsKey)
        if let deviceName {
            defaults.set(deviceName, forKey: Self.sharedDeviceNameDefaultsKey)
        } else {
            defaults.removeObject(forKey: Self.sharedDeviceNameDefaultsKey)
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
