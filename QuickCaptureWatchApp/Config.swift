import Foundation

/// Centralized configuration for Quick Capture on watchOS.
///
/// Replace `defaultAPIBaseURL` and `defaultAPIToken` before deploying, or override
/// them at runtime via `UserDefaults.standard` or launch environment variables.
struct Config: Sendable {
    private init() {}

    // MARK: - API Defaults

    /// Base URL of the Quick Capture backend (without trailing `/api/capture`).
    static let defaultAPIBaseURL = "https://<your-service>.run.app"

    /// Bearer token prefixed with `iwf_cap_`.
    static let defaultAPIToken = "iwf_cap_<token>"

    /// Path appended to `apiBaseURL` when uploading captured audio.
    static let captureEndpointPath = "/api/capture"

    // MARK: - Recording & Lifecycle

    /// Maximum single voice memo length in seconds before automatic stop and upload.
    static let maxRecordingDuration: TimeInterval = 60.0

    /// Delay before transitioning `.success` or `.error` states back to `.idle`.
    static let autoResetDelay: Duration = .seconds(2)

    // MARK: - Deep Linking

    static let deepLinkScheme = "quickcapture"
    static let deepLinkRecordHost = "record"

    /// Deep link URL used by the watch face complication to launch straight into recording.
    static let deepLinkRecordURL = URL(string: "\(deepLinkScheme)://\(deepLinkRecordHost)")!

    static func isRecordDeepLink(_ url: URL) -> Bool {
        url.scheme?.caseInsensitiveCompare(deepLinkScheme) == .orderedSame
            && url.host?.caseInsensitiveCompare(deepLinkRecordHost) == .orderedSame
    }

    // MARK: - Runtime Storage Keys

    private static let apiBaseURLDefaultsKey = "com.iwf.quickcapture.apiBaseURL"
    private static let apiTokenDefaultsKey = "com.iwf.quickcapture.apiToken"

    private static let apiBaseURLEnvKey = "QUICK_CAPTURE_API_BASE_URL"
    private static let apiTokenEnvKey = "QUICK_CAPTURE_API_TOKEN"

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

    /// Resolved Bearer API token (environment override -> `UserDefaults` -> compile-time default).
    static var apiToken: String {
        if let envValue = nonEmpty(ProcessInfo.processInfo.environment[apiTokenEnvKey]) {
            return envValue
        }
        if let storedValue = nonEmpty(UserDefaults.standard.string(forKey: apiTokenDefaultsKey)) {
            return storedValue
        }
        return defaultAPIToken
    }

    static func setAPIBaseURL(_ value: String?) {
        if let trimmed = nonEmpty(value) {
            UserDefaults.standard.set(trimmed, forKey: apiBaseURLDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: apiBaseURLDefaultsKey)
        }
    }

    static func setAPIToken(_ value: String?) {
        if let trimmed = nonEmpty(value) {
            UserDefaults.standard.set(trimmed, forKey: apiTokenDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: apiTokenDefaultsKey)
        }
    }

    private static func nonEmpty(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
