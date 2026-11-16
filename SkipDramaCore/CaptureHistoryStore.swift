import Foundation
import Observation
import OSLog

/// Represents a captured item stored in the shared App Group history log with offline retry metadata.
struct CaptureHistoryItem: Identifiable, Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        case voice
        case text
        case link
        case image
        case file

        var symbolName: String {
            switch self {
            case .voice:
                return "waveform"
            case .text:
                return "text.bubble"
            case .link:
                return "link"
            case .image:
                return "photo"
            case .file:
                return "doc"
            }
        }

        var displayLabel: String {
            switch self {
            case .voice:
                return "Voice"
            case .text:
                return "Text"
            case .link:
                return "Link"
            case .image:
                return "Image"
            case .file:
                return "File"
            }
        }
    }

    enum SyncStatus: String, Codable, Sendable {
        case queued
        case sending
        case sent
        case failed

        var badgeTitle: String {
            switch self {
            case .queued:
                return "Queued"
            case .sending:
                return "Sending"
            case .sent:
                return "Sent"
            case .failed:
                return "Retry"
            }
        }
    }

    let id: UUID
    let kind: Kind
    var title: String
    var subtitle: String?
    let createdAt: Date
    var status: SyncStatus
    var errorMessage: String?
    var payloadFilename: String?
    var originalFilename: String?
    var mimeType: String?
    var textPayload: String?
}

/// Manages local capture history and offline-resilient upload retries across the iOS app,
/// App Intents, and Share Extension via the shared App Group container.
@MainActor
@Observable
final class CaptureHistoryStore {
    static let shared = CaptureHistoryStore()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.skipdrama",
        category: "CaptureHistoryStore"
    )

    private static let historyDirectoryName = "CaptureHistory"
    private static let payloadsDirectoryName = "Payloads"
    private static let historyFilename = "history.json"
    private static let maxStoredItems = 100

    private(set) var items: [CaptureHistoryItem] = []

    var onUnauthorized: (@MainActor () -> Void)?

    private let client: CaptureClient
    private let historyFileURL: URL
    private let payloadsDirectoryURL: URL

    init(client: CaptureClient = CaptureClient()) {
        self.client = client
        let baseDirectory = Self.resolveHistoryDirectoryURL()
        self.historyFileURL = baseDirectory.appendingPathComponent(Self.historyFilename)
        self.payloadsDirectoryURL = baseDirectory.appendingPathComponent(Self.payloadsDirectoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: payloadsDirectoryURL, withIntermediateDirectories: true)
        reload()
    }

    func reload() {
        guard FileManager.default.fileExists(atPath: historyFileURL.path),
              let data = try? Data(contentsOf: historyFileURL) else {
            items = []
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([CaptureHistoryItem].self, from: data) {
            items = decoded.sorted { $0.createdAt > $1.createdAt }
        }
    }

    @discardableResult
    func submitText(
        _ text: String,
        kind: CaptureHistoryItem.Kind = .text,
        subtitle: String? = nil
    ) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let titlePreview = trimmed.components(separatedBy: .newlines).first ?? trimmed
        let item = CaptureHistoryItem(
            id: UUID(),
            kind: kind,
            title: String(titlePreview.prefix(120)),
            subtitle: subtitle,
            createdAt: Date(),
            status: .sending,
            errorMessage: nil,
            payloadFilename: nil,
            originalFilename: nil,
            mimeType: nil,
            textPayload: trimmed
        )

        insertOrUpdate(item)
        return await uploadTextItem(id: item.id)
    }

    @discardableResult
    func submitVoice(fileURL: URL, duration: TimeInterval) async -> Bool {
        let itemID = UUID()
        let payloadFilename = "\(itemID.uuidString).m4a"
        let persistedURL = payloadsDirectoryURL.appendingPathComponent(payloadFilename)

        do {
            if FileManager.default.fileExists(atPath: persistedURL.path) {
                try FileManager.default.removeItem(at: persistedURL)
            }
            try FileManager.default.copyItem(at: fileURL, to: persistedURL)
        } catch {
            Self.logger.warning("Failed to copy voice file into CaptureHistory payloads: \(error.localizedDescription, privacy: .public)")
        }

        let formattedDuration = Self.formatDuration(duration)
        let item = CaptureHistoryItem(
            id: itemID,
            kind: .voice,
            title: "Voice Memo (\(formattedDuration))",
            subtitle: nil,
            createdAt: Date(),
            status: .sending,
            errorMessage: nil,
            payloadFilename: FileManager.default.fileExists(atPath: persistedURL.path) ? payloadFilename : nil,
            originalFilename: fileURL.lastPathComponent,
            mimeType: "audio/m4a",
            textPayload: nil
        )

        insertOrUpdate(item)

        let sourceURL = FileManager.default.fileExists(atPath: persistedURL.path) ? persistedURL : fileURL
        let succeeded = await uploadVoiceItem(id: itemID, fileURL: sourceURL)
        if succeeded {
            try? FileManager.default.removeItem(at: fileURL)
        }
        return succeeded
    }

    @discardableResult
    func submitAttachment(
        data: Data,
        filename: String,
        mimeType: String,
        caption: String?,
        kind: CaptureHistoryItem.Kind
    ) async -> Bool {
        let itemID = UUID()
        let fileExtension = URL(fileURLWithPath: filename).pathExtension
        let payloadFilename = fileExtension.isEmpty
            ? itemID.uuidString
            : "\(itemID.uuidString).\(fileExtension)"
        let persistedURL = payloadsDirectoryURL.appendingPathComponent(payloadFilename)

        try? data.write(to: persistedURL, options: .atomic)

        let trimmedCaption = caption?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sizeDescription = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
        let title = (trimmedCaption?.isEmpty == false) ? trimmedCaption! : filename
        let subtitle = (trimmedCaption?.isEmpty == false) ? "\(filename) • \(sizeDescription)" : sizeDescription

        let item = CaptureHistoryItem(
            id: itemID,
            kind: kind,
            title: title,
            subtitle: subtitle,
            createdAt: Date(),
            status: .sending,
            errorMessage: nil,
            payloadFilename: FileManager.default.fileExists(atPath: persistedURL.path) ? payloadFilename : nil,
            originalFilename: filename,
            mimeType: mimeType,
            textPayload: trimmedCaption
        )

        insertOrUpdate(item)
        return await uploadAttachmentItem(id: itemID, inMemoryData: data)
    }

    func retry(itemID: UUID) async {
        reload()
        guard let item = items.first(where: { $0.id == itemID }) else { return }
        guard item.status != .sent && item.status != .sending else { return }

        updateItem(id: itemID) { entry in
            entry.status = .sending
            entry.errorMessage = nil
        }

        switch item.kind {
        case .text, .link:
            _ = await uploadTextItem(id: itemID)
        case .voice:
            if let payloadFilename = item.payloadFilename {
                let url = payloadsDirectoryURL.appendingPathComponent(payloadFilename)
                _ = await uploadVoiceItem(id: itemID, fileURL: url)
            } else {
                updateItem(id: itemID) { entry in
                    entry.status = .failed
                    entry.errorMessage = "Audio file unavailable"
                }
            }
        case .image, .file:
            _ = await uploadAttachmentItem(id: itemID, inMemoryData: nil)
        }
    }

    func retryAllPending() async {
        reload()
        let pendingIDs = items
            .filter { $0.status == .queued || $0.status == .failed }
            .sorted { $0.createdAt < $1.createdAt }
            .map(\.id)

        for id in pendingIDs {
            await retry(itemID: id)
        }
    }

    func remove(itemID: UUID) {
        reload()
        if let item = items.first(where: { $0.id == itemID }),
           let payloadFilename = item.payloadFilename {
            let fileURL = payloadsDirectoryURL.appendingPathComponent(payloadFilename)
            try? FileManager.default.removeItem(at: fileURL)
        }
        items.removeAll { $0.id == itemID }
        persist()
    }

    func clearSent() {
        reload()
        items.removeAll { $0.status == .sent }
        persist()
    }

    // MARK: - Upload Execution

    private func uploadTextItem(id: UUID) async -> Bool {
        guard let item = items.first(where: { $0.id == id }),
              let payload = item.textPayload else {
            return false
        }

        do {
            try await client.captureText(payload)
            updateItem(id: id) { entry in
                entry.status = .sent
                entry.errorMessage = nil
            }
            return true
        } catch CaptureError.unauthorized {
            updateItem(id: id) { entry in
                entry.status = .failed
                entry.errorMessage = "Authentication required"
            }
            onUnauthorized?()
            return false
        } catch {
            updateItem(id: id) { entry in
                entry.status = .failed
                entry.errorMessage = error.localizedDescription
            }
            return false
        }
    }

    private func uploadVoiceItem(id: UUID, fileURL: URL) async -> Bool {
        do {
            try await client.uploadVoiceMemo(fileURL: fileURL)
            if let payloadFilename = items.first(where: { $0.id == id })?.payloadFilename {
                let storedURL = payloadsDirectoryURL.appendingPathComponent(payloadFilename)
                try? FileManager.default.removeItem(at: storedURL)
            }
            updateItem(id: id) { entry in
                entry.status = .sent
                entry.errorMessage = nil
                entry.payloadFilename = nil
            }
            return true
        } catch CaptureError.unauthorized {
            updateItem(id: id) { entry in
                entry.status = .failed
                entry.errorMessage = "Authentication required"
            }
            onUnauthorized?()
            return false
        } catch {
            updateItem(id: id) { entry in
                entry.status = .failed
                entry.errorMessage = error.localizedDescription
            }
            return false
        }
    }

    private func uploadAttachmentItem(id: UUID, inMemoryData: Data?) async -> Bool {
        guard let item = items.first(where: { $0.id == id }) else {
            return false
        }

        let payloadData: Data
        if let inMemoryData {
            payloadData = inMemoryData
        } else if let payloadFilename = item.payloadFilename,
                  let diskData = try? Data(contentsOf: payloadsDirectoryURL.appendingPathComponent(payloadFilename)) {
            payloadData = diskData
        } else {
            updateItem(id: id) { entry in
                entry.status = .failed
                entry.errorMessage = "Attachment missing"
            }
            return false
        }

        do {
            try await client.captureMultipart(
                fileData: payloadData,
                filename: item.originalFilename ?? "attachment.bin",
                mimeType: item.mimeType ?? "application/octet-stream",
                caption: item.textPayload,
                fieldName: "file"
            )
            if let payloadFilename = item.payloadFilename {
                let storedURL = payloadsDirectoryURL.appendingPathComponent(payloadFilename)
                try? FileManager.default.removeItem(at: storedURL)
            }
            updateItem(id: id) { entry in
                entry.status = .sent
                entry.errorMessage = nil
                entry.payloadFilename = nil
            }
            return true
        } catch CaptureError.unauthorized {
            updateItem(id: id) { entry in
                entry.status = .failed
                entry.errorMessage = "Authentication required"
            }
            onUnauthorized?()
            return false
        } catch {
            updateItem(id: id) { entry in
                entry.status = .failed
                entry.errorMessage = error.localizedDescription
            }
            return false
        }
    }

    // MARK: - Persistence Helpers

    private func insertOrUpdate(_ item: CaptureHistoryItem) {
        reload()
        items.removeAll { $0.id == item.id }
        items.insert(item, at: 0)
        trimExcessItems()
        persist()
    }

    private func updateItem(id: UUID, mutate: (inout CaptureHistoryItem) -> Void) {
        reload()
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        mutate(&items[index])
        persist()
    }

    private func trimExcessItems() {
        guard items.count > Self.maxStoredItems else { return }
        let dropped = items[Self.maxStoredItems...]
        for old in dropped where old.status == .sent {
            if let payloadFilename = old.payloadFilename {
                try? FileManager.default.removeItem(at: payloadsDirectoryURL.appendingPathComponent(payloadFilename))
            }
        }
        items = Array(items.prefix(Self.maxStoredItems))
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(items) else { return }
        do {
            try data.write(to: historyFileURL, options: .atomic)
            NotificationCenter.default.post(name: .skipDramaHistoryDidChange, object: nil)
        } catch {
            Self.logger.warning("Failed to persist capture history: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func resolveHistoryDirectoryURL() -> URL {
        if let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Config.appGroupIdentifier
        ) {
            let dir = containerURL.appendingPathComponent(historyDirectoryName, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let dir = appSupport.appendingPathComponent(historyDirectoryName, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        let fallback = FileManager.default.temporaryDirectory.appendingPathComponent(historyDirectoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }

    private static func formatDuration(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
