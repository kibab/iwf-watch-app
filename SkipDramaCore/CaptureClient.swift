import Foundation
import OSLog

/// Typed errors returned by `CaptureClient` when calling `POST /api/capture`.
enum CaptureError: LocalizedError, Sendable, Equatable {
    case invalidConfiguration(String)
    case unauthorized
    case fileTooLarge
    case emptyInput
    case serverError(statusCode: Int)
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message):
            return message
        case .unauthorized:
            return "Device unpaired"
        case .fileTooLarge:
            return "Attachment exceeds 25 MB limit"
        case .emptyInput:
            return "Nothing to capture"
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

private struct TextCapturePayload: Encodable, Sendable {
    let text: String
}

/// Client for `POST /api/capture` supporting JSON text, raw `.m4a` voice streaming, and multipart attachments.
struct CaptureClient: Sendable {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.skipdrama",
        category: "CaptureClient"
    )

    private let session: URLSession
    private let tokenStore: KeychainTokenStore

    init(
        session: URLSession = .shared,
        tokenStore: KeychainTokenStore = KeychainTokenStore()
    ) {
        self.session = session
        self.tokenStore = tokenStore
    }

    /// Streams `fileURL` via `URLSession.upload(for:fromFile:)` to keep RAM usage minimal.
    @discardableResult
    func uploadVoiceMemo(fileURL: URL) async throws -> CaptureResponse {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw CaptureError.networkError("Recording missing")
        }

        if let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let fileSize = (attributes[.size] as? NSNumber)?.intValue,
           fileSize > Config.maxUploadSizeBytes {
            throw CaptureError.fileTooLarge
        }

        let endpointURL = try resolvedEndpointURL()
        let token = try resolvedToken()

        var request = makeBaseRequest(url: endpointURL, token: token, timeoutInterval: 45)
        request.setValue("audio/m4a", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await performUpload(request: request, fileURL: fileURL)
        return try validateResponse(data: data, response: response)
    }

    /// Captures plain text or URLs as `application/json` (`{"text": "..."}`).
    @discardableResult
    func captureText(_ text: String) async throws -> CaptureResponse {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CaptureError.emptyInput
        }

        let endpointURL = try resolvedEndpointURL()
        let token = try resolvedToken()

        var request = makeBaseRequest(url: endpointURL, token: token, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let bodyData: Data
        do {
            bodyData = try JSONEncoder().encode(TextCapturePayload(text: trimmed))
        } catch {
            throw CaptureError.networkError("Encoding error")
        }

        let (data, response) = try await performUpload(request: request, bodyData: bodyData)
        return try validateResponse(data: data, response: response)
    }

    /// Captures an image, PDF, audio file, or generic file via `multipart/form-data` (up to 25 MiB).
    @discardableResult
    func captureMultipart(
        fileData: Data,
        filename: String,
        mimeType: String,
        caption: String? = nil,
        fieldName: String = "file"
    ) async throws -> CaptureResponse {
        guard !fileData.isEmpty else {
            throw CaptureError.emptyInput
        }
        guard fileData.count <= Config.maxUploadSizeBytes else {
            throw CaptureError.fileTooLarge
        }

        let endpointURL = try resolvedEndpointURL()
        let token = try resolvedToken()

        let boundary = "Boundary-\(UUID().uuidString)"
        let safeFilename = sanitizedFilename(filename)
        let bodyData = buildMultipartBody(
            boundary: boundary,
            fileData: fileData,
            filename: safeFilename,
            mimeType: mimeType,
            caption: caption,
            fieldName: fieldName
        )

        var request = makeBaseRequest(url: endpointURL, token: token, timeoutInterval: 60)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await performUpload(request: request, bodyData: bodyData)
        return try validateResponse(data: data, response: response)
    }

    // MARK: - Request & Multipart Helpers

    private func makeBaseRequest(url: URL, token: String, timeoutInterval: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutInterval
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("respond-async", forHTTPHeaderField: "Prefer")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func buildMultipartBody(
        boundary: String,
        fileData: Data,
        filename: String,
        mimeType: String,
        caption: String?,
        fieldName: String
    ) -> Data {
        var body = Data()
        let lineBreak = "\r\n"

        if let trimmedCaption = caption?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmedCaption.isEmpty {
            body.appendUTF8("--\(boundary)\(lineBreak)")
            body.appendUTF8("Content-Disposition: form-data; name=\"text\"\(lineBreak)\(lineBreak)")
            body.appendUTF8("\(trimmedCaption)\(lineBreak)")
        }

        body.appendUTF8("--\(boundary)\(lineBreak)")
        body.appendUTF8("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(filename)\"\(lineBreak)")
        body.appendUTF8("Content-Type: \(mimeType)\(lineBreak)\(lineBreak)")
        body.append(fileData)
        body.appendUTF8(lineBreak)
        body.appendUTF8("--\(boundary)--\(lineBreak)")

        return body
    }

    private func sanitizedFilename(_ raw: String) -> String {
        let cleaned = raw
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "attachment.bin" : cleaned
    }

    private func performUpload(request: URLRequest, fileURL: URL) async throws -> (Data, URLResponse) {
        do {
            return try await session.upload(for: request, fromFile: fileURL)
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
    }

    private func performUpload(request: URLRequest, bodyData: Data) async throws -> (Data, URLResponse) {
        do {
            return try await session.upload(for: request, from: bodyData)
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw CancellationError()
        } catch let urlError as URLError {
            Self.logger.error("Capture network error (\(urlError.code.rawValue)): \(urlError.localizedDescription, privacy: .public)")
            throw CaptureError.networkError(Self.conciseMessage(for: urlError))
        } catch {
            Self.logger.error("Unexpected capture error: \(error.localizedDescription, privacy: .public)")
            throw CaptureError.networkError("Upload failed")
        }
    }

    private func validateResponse(data: Data, response: URLResponse) throws -> CaptureResponse {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CaptureError.networkError("Invalid response")
        }

        switch httpResponse.statusCode {
        case 200...299:
            if let decoded = try? JSONDecoder().decode(CaptureResponse.self, from: data) {
                Self.logger.info("Capture accepted (HTTP \(httpResponse.statusCode)): status=\(decoded.status, privacy: .public)")
                return decoded
            } else {
                Self.logger.info("Capture accepted (HTTP \(httpResponse.statusCode))")
                return CaptureResponse(status: "queued")
            }
        case 401, 403:
            Self.logger.warning("Capture rejected with HTTP \(httpResponse.statusCode)")
            throw CaptureError.unauthorized
        case 413:
            Self.logger.warning("Capture rejected as too large (HTTP 413)")
            throw CaptureError.fileTooLarge
        default:
            Self.logger.error("Capture failed with HTTP \(httpResponse.statusCode)")
            throw CaptureError.serverError(statusCode: httpResponse.statusCode)
        }
    }

    // MARK: - Validation Helpers

    private func resolvedEndpointURL() throws -> URL {
        do {
            return try Config.resolvedEndpointURL(path: Config.captureEndpointPath)
        } catch {
            throw CaptureError.invalidConfiguration(error.localizedDescription)
        }
    }

    private func resolvedToken() throws -> String {
        guard let token = tokenStore.readToken() else {
            throw CaptureError.unauthorized
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

private extension Data {
    mutating func appendUTF8(_ string: String) {
        if let encoded = string.data(using: .utf8) {
            append(encoded)
        }
    }
}
