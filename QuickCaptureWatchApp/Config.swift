import Foundation

/// Centralized configuration for Quick Capture on watchOS.
///
/// The backend base URL defaults to `https://gtd.bakulin.de` and can be overridden
/// at runtime via Watch Settings (`UserDefaults.standard`) or launch environment variables.
struct Config: Sendable {
    private init() {}

    // MARK: - API Defaults

    /// Single configuration constant for the Quick Capture backend base URL.
    static let defaultAPIBaseURL = "https://gtd.bakulin.de"

    /// Path appended to `apiBaseURL` when uploading captured audio.
    static let captureEndpointPath = "/api/capture"

    /// Path appended to `apiBaseURL` to start a device-code pairing session.
    static let pairStartEndpointPath = "/api/integrations/watch/pair/start"

    /// Path appended to `apiBaseURL` to poll a device-code pairing session.
    static let pairPollEndpointPath = "/api/integrations/watch/pair/poll"

    // MARK: - Recording & Lifecycle

    /// Maximum single voice memo length in seconds before automatic stop and upload.
    static let maxRecordingDuration: TimeInterval = 60.0

    /// Delay before transitioning `.success` or `.error` states back to `.idle`.
    static let autoResetDelay: Duration = .seconds(2)

    // MARK: - Deep Linking

    static let deepLinkScheme = "iwfquickcapture"
    static let deepLinkRecordHost = "record"

    /// Deep link URL used by the watch face complication to launch straight into recording.
    static let deepLinkRecordURL = URL(string: "\(deepLinkScheme)://\(deepLinkRecordHost)")!

    static func isRecordDeepLink(_ url: URL) -> Bool {
        url.scheme?.caseInsensitiveCompare(deepLinkScheme) == .orderedSame
            && url.host?.caseInsensitiveCompare(deepLinkRecordHost) == .orderedSame
    }

    // MARK: - Runtime Storage Keys

    private static let apiBaseURLDefaultsKey = "com.iwf.quickcapture.apiBaseURL"

    private static let apiBaseURLEnvKey = "IWF_CAPTURE_API_BASE_URL"

    // MARK: - Resolved Settings

    /// Resolved backend base URL (environment override -> `UserDefaults` -> compile-time default).
    static var apiBaseURL: String {
        if let envValue = nonEmpty(ProcessInfo.processInfo.environment[apiBaseURLEnvKey]) {
            return envValue
        }
        if let storedValue = nonEmpty(UserDefaults.standard.string(forKey: apiBaseURLDefaultsKey)) {
            return storedValue
        }
        return defaultAPIBaseURL
    }

    static func setAPIBaseURL(_ value: String?) {
        if let trimmed = nonEmpty(value) {
            UserDefaults.standard.set(trimmed, forKey: apiBaseURLDefaultsKey)
        } else {
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

    /// Extracts a concise host string for UI display (e.g., `gtd.bakulin.de`).
    static func displayHost(for urlString: String? = nil) -> String {
        let candidate = nonEmpty(urlString) ?? apiBaseURL
        if let url = URL(string: candidate), let host = url.host, !host.isEmpty {
            if let port = url.port {
                return "\(host):\(port)"
            }
            return host
        }
        return URL(string: defaultAPIBaseURL)?.host ?? "gtd.bakulin.de"
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
