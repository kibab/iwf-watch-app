import Foundation
import OSLog

/// Typed errors returned by `CaptureClient` when uploading voice memos.
enum CaptureError: LocalizedError, Sendable, Equatable {
    case invalidConfiguration(String)
    case unauthorized
    case serverError(statusCode: Int)
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message):
            return message
        case .unauthorized:
            return "Unauthorized"
        case .serverError(let statusCode):
            return "Server error (\(statusCode))"
        case .networkError(let message):
            return message
        }
    }
}

/// JSON payload expected from `POST /api/capture` on HTTP `202 Accepted`.
struct CaptureResponse: Decodable, Sendable {
    let status: String
}

/// Streams raw `.m4a` voice recordings directly from disk to the Quick Capture API.
struct CaptureClient: Sendable {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.iwf.quickcapture",
        category: "CaptureClient"
    )

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Streams `fileURL` via `URLSession.upload(for:fromFile:)` to keep RAM usage minimal on Series 6/7.
    func uploadVoiceMemo(fileURL: URL) async throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw CaptureError.networkError("Recording missing")
        }

        let endpointURL = try resolvedEndpointURL()
        let token = try resolvedToken()

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/m4a", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await session.upload(for: request, fromFile: fileURL)
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw CancellationError()
        } catch let urlError as URLError {
            Self.logger.error("Upload network error (\(urlError.code.rawValue)): \(urlError.localizedDescription, privacy: .public)")
            throw CaptureError.networkError(Self.conciseMessage(for: urlError))
        } catch {
            Self.logger.error("Unexpected upload error: \(error.localizedDescription, privacy: .public)")
            throw CaptureError.networkError("Upload failed")
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CaptureError.networkError("Invalid response")
        }

        switch httpResponse.statusCode {
        case 200...299:
            if let decoded = try? JSONDecoder().decode(CaptureResponse.self, from: data) {
                Self.logger.info("Voice memo accepted (HTTP \(httpResponse.statusCode)): status=\(decoded.status, privacy: .public)")
            } else {
                Self.logger.info("Voice memo accepted (HTTP \(httpResponse.statusCode))")
            }
        case 401, 403:
            Self.logger.warning("Upload rejected with HTTP \(httpResponse.statusCode)")
            throw CaptureError.unauthorized
        default:
            Self.logger.error("Upload failed with HTTP \(httpResponse.statusCode)")
            throw CaptureError.serverError(statusCode: httpResponse.statusCode)
        }
    }

    // MARK: - Validation Helpers

    private func resolvedEndpointURL() throws -> URL {
        let rawBaseURL = Config.apiBaseURL
        guard !rawBaseURL.contains("<your-service>") else {
            throw CaptureError.invalidConfiguration("Set API URL")
        }

        guard var components = URLComponents(string: rawBaseURL),
              components.scheme?.lowercased() == "https",
              let host = components.host,
              !host.isEmpty else {
            throw CaptureError.invalidConfiguration("Invalid API URL")
        }

        let trimmedPath = components.path.hasSuffix("/")
            ? String(components.path.dropLast())
            : components.path

        if trimmedPath.hasSuffix(Config.captureEndpointPath) {
            components.path = trimmedPath
        } else {
            components.path = trimmedPath + Config.captureEndpointPath
        }

        guard let url = components.url else {
            throw CaptureError.invalidConfiguration("Invalid API URL")
        }
        return url
    }

    private func resolvedToken() throws -> String {
        let token = Config.apiToken
        guard !token.isEmpty, !token.contains("<token>") else {
            throw CaptureError.invalidConfiguration("Set API token")
        }
        return token
    }

    private static func conciseMessage(for error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
            return "Offline"
        case .timedOut:
            return "Timed out"
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return "Server unreachable"
        case .secureConnectionFailed, .serverCertificateUntrusted:
            return "TLS error"
        default:
            return "Network error"
        }
    }
}

