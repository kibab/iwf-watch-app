import Foundation
import OSLog

struct PairStartRequest: Encodable, Sendable {
    let deviceName: String

    enum CodingKeys: String, CodingKey {
        case deviceName = "device_name"
    }
}

struct PairStartResponse: Decodable, Sendable, Equatable {
    let deviceSecret: String
    let userCode: String
    let userCodeFormatted: String
    let pairURL: String
    let expiresAt: Date
    let pollIntervalSeconds: Int

    enum CodingKeys: String, CodingKey {
        case deviceSecret = "device_secret"
        case userCode = "user_code"
        case userCodeFormatted = "user_code_formatted"
        case pairURL = "pair_url"
        case expiresAt = "expires_at"
        case pollIntervalSeconds = "poll_interval_seconds"
    }
}

struct PairPollRequest: Encodable, Sendable {
    let deviceSecret: String

    enum CodingKeys: String, CodingKey {
        case deviceSecret = "device_secret"
    }
}

struct PairPollResponse: Decodable, Sendable, Equatable {
    let status: String
    let token: String?
    let name: String?
    let lastChars: String?

    enum CodingKeys: String, CodingKey {
        case status
        case token
        case name
        case lastChars = "last_chars"
    }
}

enum PairPollResult: Sendable, Equatable {
    case pending
    case paired(token: String, name: String?, lastChars: String?)
}

enum PairingError: LocalizedError, Sendable, Equatable {
    case rateLimited
    case codeExpired
    case invalidConfiguration(String)
    case serverError(statusCode: Int)
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .rateLimited:
            return "Too many attempts, tap Retry in a moment"
        case .codeExpired:
            return "Code Expired"
        case .invalidConfiguration(let message):
            return message
        case .serverError(let statusCode):
            return "Server error (\(statusCode))"
        case .networkError(let message):
            return message
        }
    }
}

/// Communicates with the RFC 8628-style device pairing endpoints (`/pair/start` and `/pair/poll`).
struct PairingService: Sendable {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.skipdrama",
        category: "PairingService"
    )

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func startPairing(deviceName: String) async throws -> PairStartResponse {
        let endpointURL: URL
        do {
            endpointURL = try Config.resolvedEndpointURL(path: Config.pairStartEndpointPath)
        } catch {
            throw PairingError.invalidConfiguration(error.localizedDescription)
        }

        let payload = PairStartRequest(deviceName: deviceName)
        let (data, httpResponse) = try await postJSON(url: endpointURL, body: payload)

        switch httpResponse.statusCode {
        case 200, 201:
            do {
                return try Self.makeDecoder().decode(PairStartResponse.self, from: data)
            } catch {
                Self.logger.error("Failed to decode PairStartResponse: \(error.localizedDescription, privacy: .public)")
                throw PairingError.networkError("Invalid server response")
            }
        case 429:
            Self.logger.warning("Pair start rate-limited (HTTP 429)")
            throw PairingError.rateLimited
        default:
            Self.logger.error("Pair start failed with HTTP \(httpResponse.statusCode)")
            throw PairingError.serverError(statusCode: httpResponse.statusCode)
        }
    }

    func pollPairing(deviceSecret: String) async throws -> PairPollResult {
        let endpointURL: URL
        do {
            endpointURL = try Config.resolvedEndpointURL(path: Config.pairPollEndpointPath)
        } catch {
            throw PairingError.invalidConfiguration(error.localizedDescription)
        }

        let payload = PairPollRequest(deviceSecret: deviceSecret)
        let (data, httpResponse) = try await postJSON(url: endpointURL, body: payload)

        switch httpResponse.statusCode {
        case 200:
            let decoded: PairPollResponse
            do {
                decoded = try Self.makeDecoder().decode(PairPollResponse.self, from: data)
            } catch {
                Self.logger.error("Failed to decode PairPollResponse: \(error.localizedDescription, privacy: .public)")
                throw PairingError.networkError("Invalid server response")
            }

            switch decoded.status.lowercased() {
            case "pending":
                return .pending
            case "paired":
                guard let token = decoded.token?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !token.isEmpty else {
                    Self.logger.error("Pair poll returned status=paired without a token")
                    throw PairingError.networkError("Missing token in response")
                }
                return .paired(token: token, name: decoded.name, lastChars: decoded.lastChars)
            default:
                Self.logger.warning("Unexpected poll status: \(decoded.status, privacy: .public)")
                return .pending
            }
        case 410:
            Self.logger.info("Pairing session expired or already consumed (HTTP 410)")
            throw PairingError.codeExpired
        case 429:
            Self.logger.warning("Pair poll rate-limited (HTTP 429)")
            throw PairingError.rateLimited
        default:
            Self.logger.error("Pair poll failed with HTTP \(httpResponse.statusCode)")
            throw PairingError.serverError(statusCode: httpResponse.statusCode)
        }
    }

    // MARK: - Networking Helpers

    private func postJSON<Body: Encodable>(url: URL, body: Body) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw PairingError.networkError("Encoding error")
        }

        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw CancellationError()
        } catch let urlError as URLError {
            Self.logger.error("Pairing network error (\(urlError.code.rawValue)): \(urlError.localizedDescription, privacy: .public)")
            throw PairingError.networkError(Self.conciseMessage(for: urlError))
        } catch {
            Self.logger.error("Unexpected pairing error: \(error.localizedDescription, privacy: .public)")
            throw PairingError.networkError("Connection failed")
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PairingError.networkError("Invalid response")
        }
        return (data, httpResponse)
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)

            let fractionalFormatter = ISO8601DateFormatter()
            fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractionalFormatter.date(from: string) {
                return date
            }

            let standardFormatter = ISO8601DateFormatter()
            standardFormatter.formatOptions = [.withInternetDateTime]
            if let date = standardFormatter.date(from: string) {
                return date
            }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO-8601 date: \(string)"
            )
        }
        return decoder
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
