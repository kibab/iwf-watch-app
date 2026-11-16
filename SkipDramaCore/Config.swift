import Foundation

/// Centralized configuration for SkipDrama across iOS, watchOS, Widgets, and Share Extension.
///
/// The backend base URL defaults to `https://skipdrama.app` and can be overridden
/// at runtime via Settings (`sharedDefaults`) or launch environment variables.
struct Config: Sendable {
    private init() {}

    // MARK: - App Group & Keychain Sharing

    static let appGroupIdentifier = "group.app.skipdrama.shared"
    static let keychainAccessGroupSuffix = "app.skipdrama.shared"

    static var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    }

    // MARK: - API Defaults

    /// Single configuration constant for the SkipDrama backend base URL.
    static let defaultAPIBaseURL = "https://skipdrama.app"

    /// Path appended to `apiBaseURL` when uploading captured items.
    static let captureEndpointPath = "/api/capture"

    /// Path appended to `apiBaseURL` to start a device-code pairing session.
    static let pairStartEndpointPath = "/api/integrations/watch/pair/start"

    /// Path appended to `apiBaseURL` to poll a device-code pairing session.
    static let pairPollEndpointPath = "/api/integrations/watch/pair/poll"

    /// Web URL path for viewing/creating integration tokens on SkipDrama.
    static let settingsIntegrationsPath = "/settings/integrations"

    // MARK: - Recording & Upload Limits

    /// Maximum single voice memo length in seconds before automatic stop and upload.
    static let maxRecordingDuration: TimeInterval = 60.0

    /// Maximum attachment upload size (25 MiB) enforced by `/api/capture`.
    static let maxUploadSizeBytes: Int = 25 * 1024 * 1024

    /// Delay before transitioning `.success` or `.error` states back to `.idle`.
    static let autoResetDelay: Duration = .seconds(2)

    // MARK: - Deep Linking

    enum DeepLinkDestination: Equatable, Sendable {
        case voiceCapture
        case textCapture
    }

    static let deepLinkScheme = "skipdrama"
    static let deepLinkRecordHost = "record"
    static let deepLinkCaptureHost = "capture"

    /// Deep link URL used by the watch face complication to launch straight into recording.
    static let deepLinkRecordURL = URL(string: "\(deepLinkScheme)://\(deepLinkRecordHost)")!

    /// Deep link URL for iOS voice capture (`skipdrama://capture/voice`).
    static let deepLinkCaptureVoiceURL = URL(string: "\(deepLinkScheme)://\(deepLinkCaptureHost)/voice")!

    /// Deep link URL for iOS text capture (`skipdrama://capture/text`).
    static let deepLinkCaptureTextURL = URL(string: "\(deepLinkScheme)://\(deepLinkCaptureHost)/text")!

    static func parseDeepLink(_ url: URL) -> DeepLinkDestination? {
        guard url.scheme?.caseInsensitiveCompare(deepLinkScheme) == .orderedSame else {
            return nil
        }

        let host = url.host?.lowercased() ?? ""
        let trimmedPath = url.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()

        if host == deepLinkRecordHost {
            return .voiceCapture
        }

        if host == deepLinkCaptureHost {
            switch trimmedPath {
            case "voice", "":
                return .voiceCapture
            case "text":
                return .textCapture
            default:
                return nil
            }
        }

        return nil
    }

    static func isRecordDeepLink(_ url: URL) -> Bool {
        parseDeepLink(url) == .voiceCapture
    }

    // MARK: - Runtime Storage Keys

    private static let apiBaseURLDefaultsKey = "app.skipdrama.apiBaseURL"
    private static let apiBaseURLEnvKey = "SKIPDRAMA_API_BASE_URL"
    private static let pendingVoiceCaptureTimestampKey = "app.skipdrama.pendingVoiceCaptureTimestamp"
    private static let pendingTextCaptureTimestampKey = "app.skipdrama.pendingTextCaptureTimestamp"
    private static let pendingCaptureWindowSeconds: TimeInterval = 15.0

    // MARK: - AppIntent Cross-Process Launch Triggers

    static func requestImmediateVoiceCapture() {
        let defaults = sharedDefaults
        defaults.removeObject(forKey: pendingTextCaptureTimestampKey)
        defaults.set(Date().timeIntervalSince1970, forKey: pendingVoiceCaptureTimestampKey)
    }

    static func consumePendingVoiceCaptureRequest() -> Bool {
        consumePendingRequest(forKey: pendingVoiceCaptureTimestampKey)
    }

    static func requestImmediateTextCapture() {
        let defaults = sharedDefaults
        defaults.removeObject(forKey: pendingVoiceCaptureTimestampKey)
        defaults.set(Date().timeIntervalSince1970, forKey: pendingTextCaptureTimestampKey)
    }

    static func consumePendingTextCaptureRequest() -> Bool {
        consumePendingRequest(forKey: pendingTextCaptureTimestampKey)
    }

    private static func consumePendingRequest(forKey key: String) -> Bool {
        let defaults = sharedDefaults
        let timestamp = defaults.double(forKey: key)
        guard timestamp > 0 else { return false }
        defaults.removeObject(forKey: key)
        let age = Date().timeIntervalSince1970 - timestamp
        return age >= 0 && age <= pendingCaptureWindowSeconds
    }

    // MARK: - Resolved Settings

    /// Resolved backend base URL (environment override -> shared `UserDefaults` -> standard `UserDefaults` -> default).
    static var apiBaseURL: String {
        if let envValue = nonEmpty(ProcessInfo.processInfo.environment[apiBaseURLEnvKey]) {
            return envValue
        }
        if let storedShared = nonEmpty(sharedDefaults.string(forKey: apiBaseURLDefaultsKey)) {
            return storedShared
        }
        if let storedStandard = nonEmpty(UserDefaults.standard.string(forKey: apiBaseURLDefaultsKey)) {
            return storedStandard
        }
        return defaultAPIBaseURL
    }

    static func setAPIBaseURL(_ value: String?) {
        if let trimmed = nonEmpty(value) {
            sharedDefaults.set(trimmed, forKey: apiBaseURLDefaultsKey)
            UserDefaults.standard.set(trimmed, forKey: apiBaseURLDefaultsKey)
        } else {
            sharedDefaults.removeObject(forKey: apiBaseURLDefaultsKey)
            UserDefaults.standard.removeObject(forKey: apiBaseURLDefaultsKey)
        }
    }

    /// Resolves a backend endpoint URL from `apiBaseURL` and a relative API `path`.
    static func resolvedEndpointURL(path: String) throws -> URL {
        let rawBaseURL = apiBaseURL

        guard var components = URLComponents(string: rawBaseURL),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host,
              !host.isEmpty else {
            throw ConfigURLError.invalidURL("Invalid API URL")
        }

        let trimmedBasePath = components.path.hasSuffix("/")
            ? String(components.path.dropLast())
            : components.path

        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        if trimmedBasePath.hasSuffix(normalizedPath) {
            components.path = trimmedBasePath
        } else {
            components.path = trimmedBasePath + normalizedPath
        }

        guard let url = components.url else {
            throw ConfigURLError.invalidURL("Invalid API URL")
        }
        return url
    }

    /// Extracts a concise host string for UI display (e.g., `skipdrama.app`).
    static func displayHost(for urlString: String? = nil) -> String {
        let candidate = nonEmpty(urlString) ?? apiBaseURL
        if let url = URL(string: candidate), let host = url.host, !host.isEmpty {
            if let port = url.port {
                return "\(host):\(port)"
            }
            return host
        }
        return URL(string: defaultAPIBaseURL)?.host ?? "skipdrama.app"
    }

    static var settingsIntegrationsURL: URL {
        (try? resolvedEndpointURL(path: settingsIntegrationsPath))
            ?? URL(string: defaultAPIBaseURL + settingsIntegrationsPath)!
    }

    private static func nonEmpty(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

enum ConfigURLError: LocalizedError, Sendable, Equatable {
    case invalidURL(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let message):
            return message
        }
    }
}

extension Notification.Name {
    static let skipDramaStartVoiceCapture = Notification.Name("app.skipdrama.notification.startVoiceCapture")
    static let skipDramaOpenTextCapture = Notification.Name("app.skipdrama.notification.openTextCapture")
    static let skipDramaHistoryDidChange = Notification.Name("app.skipdrama.notification.historyDidChange")
}
