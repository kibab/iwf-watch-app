import Observation
import OSLog
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Share Content Model

private enum SharedPayload: Sendable {
    case link(url: URL, title: String?)
    case text(String)
    case attachment(data: Data, filename: String, mimeType: String, kind: CaptureHistoryItem.Kind)
}

private enum ShareExtensionLoadError: LocalizedError, Sendable {
    case emptyContent
    case fileTooLarge

    var errorDescription: String? {
        switch self {
        case .emptyContent:
            return "Nothing shareable was found in this item."
        case .fileTooLarge:
            return CaptureError.fileTooLarge.localizedDescription
        }
    }
}

// MARK: - ViewModel

@MainActor
@Observable
private final class ShareSheetViewModel {
    enum Phase: Equatable {
        case loading
        case unauthenticated
        case ready
        case submitting
        case success
        case loadError(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var payload: SharedPayload?
    private(set) var previewImage: UIImage?
    private(set) var submissionError: String?

    var note: String = ""

    private let tokenStore: KeychainTokenStore
    private let historyStore: CaptureHistoryStore

    init(
        tokenStore: KeychainTokenStore = KeychainTokenStore(),
        historyStore: CaptureHistoryStore = .shared
    ) {
        self.tokenStore = tokenStore
        self.historyStore = historyStore
    }

    func load(from inputItems: [NSExtensionItem]) async {
        guard tokenStore.hasToken else {
            phase = .unauthenticated
            return
        }

        do {
            let loaded = try await Self.extractPayload(from: inputItems)
            payload = loaded
            if case .attachment(let data, _, _, .image) = loaded {
                previewImage = UIImage(data: data)
            }
            phase = .ready
        } catch {
            phase = .loadError(error.localizedDescription)
        }
    }

    func appendChip(_ chip: String) {
        var tokens = note.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if let existingIndex = tokens.firstIndex(of: chip) {
            tokens.remove(at: existingIndex)
            note = tokens.joined(separator: " ")
        } else {
            let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
            note = trimmed.isEmpty ? chip : "\(trimmed) \(chip)"
        }
    }

    func isChipSelected(_ chip: String) -> Bool {
        let tokens = note.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return tokens.contains(chip)
    }

    func submit(onComplete: @escaping @MainActor @Sendable () -> Void) async {
        guard case .ready = phase, let payload else { return }

        submissionError = nil
        phase = .submitting

        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let succeeded: Bool

        switch payload {
        case .link(let url, let title):
            var lines: [String] = []
            if !trimmedNote.isEmpty {
                lines.append(trimmedNote)
            }
            if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines),
               !title.isEmpty,
               title != url.absoluteString {
                lines.append(title)
            }
            lines.append(url.absoluteString)
            let combined = lines.joined(separator: "\n")
            succeeded = await historyStore.submitText(
                combined,
                kind: .link,
                subtitle: url.host ?? url.absoluteString
            )

        case .text(let sharedText):
            let combined = trimmedNote.isEmpty ? sharedText : "\(trimmedNote)\n\n\(sharedText)"
            succeeded = await historyStore.submitText(combined, kind: .text)

        case .attachment(let data, let filename, let mimeType, let kind):
            succeeded = await historyStore.submitAttachment(
                data: data,
                filename: filename,
                mimeType: mimeType,
                caption: trimmedNote.isEmpty ? nil : trimmedNote,
                kind: kind
            )
        }

        if succeeded {
            phase = .success
            try? await Task.sleep(for: .milliseconds(650))
            onComplete()
        } else {
            submissionError = historyStore.items.first?.errorMessage ?? "Upload failed. Check your connection and try again."
            phase = .ready
        }
    }

    // MARK: - NSExtensionItem Extraction

    private static func extractPayload(from items: [NSExtensionItem]) async throws -> SharedPayload {
        for item in items {
            let candidateTitle = nonEmptyTitle(from: item)
            let providers = item.attachments ?? []

            for provider in providers {
                if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
                    return try await loadAttachment(
                        from: provider,
                        typeIdentifier: UTType.pdf.identifier,
                        defaultFilename: "document.pdf",
                        defaultMimeType: "application/pdf",
                        kind: .file
                    )
                }

                if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    return try await loadImageAttachment(from: provider)
                }

                if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                    return try await loadAttachment(
                        from: provider,
                        typeIdentifier: UTType.fileURL.identifier,
                        defaultFilename: "attachment.bin",
                        defaultMimeType: "application/octet-stream",
                        kind: .file
                    )
                }
            }

            for provider in providers {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let url = await loadURL(from: provider) {
                    if url.isFileURL {
                        return try loadLocalFilePayload(at: url)
                    }
                    return .link(url: url, title: candidateTitle)
                }
            }

            for provider in providers {
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                   let text = await loadPlainText(from: provider) {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        return .text(trimmed)
                    }
                }
            }

            for provider in providers {
                if provider.hasItemConformingToTypeIdentifier(UTType.data.identifier) {
                    return try await loadAttachment(
                        from: provider,
                        typeIdentifier: UTType.data.identifier,
                        defaultFilename: "attachment.bin",
                        defaultMimeType: "application/octet-stream",
                        kind: .file
                    )
                }
            }

            if let candidateTitle {
                return .text(candidateTitle)
            }
        }

        throw ShareExtensionLoadError.emptyContent
    }

    private static func nonEmptyTitle(from item: NSExtensionItem) -> String? {
        let candidates = [item.attributedTitle?.string, item.attributedContentText?.string]
        for candidate in candidates {
            if let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
               !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    private static func loadURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                if let url = item as? URL {
                    continuation.resume(returning: url)
                } else if let data = item as? Data,
                          let str = String(data: data, encoding: .utf8),
                          let url = URL(string: str) {
                    continuation.resume(returning: url)
                } else if let str = item as? String,
                          let url = URL(string: str) {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private static func loadPlainText(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                if let text = item as? String {
                    continuation.resume(returning: text)
                } else if let attributed = item as? NSAttributedString {
                    continuation.resume(returning: attributed.string)
                } else if let data = item as? Data,
                          let text = String(data: data, encoding: .utf8) {
                    continuation.resume(returning: text)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private static func loadImageAttachment(from provider: NSItemProvider) async throws -> SharedPayload {
        if let filePayload = try await loadFileRepresentationPayload(
            from: provider,
            typeIdentifier: UTType.image.identifier,
            defaultFilename: "image.jpg",
            defaultMimeType: "image/jpeg",
            kind: .image
        ) {
            return filePayload
        }

        let itemResult: Result<Data?, Error> = await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { item, error in
                if let error {
                    continuation.resume(returning: .failure(error))
                    return
                }
                if let image = item as? UIImage {
                    continuation.resume(returning: .success(image.jpegData(compressionQuality: 0.9) ?? image.pngData()))
                } else if let data = item as? Data {
                    continuation.resume(returning: .success(data))
                } else if let url = item as? URL, let data = try? Data(contentsOf: url) {
                    continuation.resume(returning: .success(data))
                } else {
                    continuation.resume(returning: .success(nil))
                }
            }
        }

        switch itemResult {
        case .success(let data?):
            guard data.count <= Config.maxUploadSizeBytes else {
                throw ShareExtensionLoadError.fileTooLarge
            }
            let suggested = provider.suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let filename = (suggested?.isEmpty == false ? suggested! : "image") + ".jpg"
            return .attachment(data: data, filename: filename, mimeType: "image/jpeg", kind: .image)
        case .success(nil):
            throw ShareExtensionLoadError.emptyContent
        case .failure(let error):
            throw error
        }
    }

    private static func loadAttachment(
        from provider: NSItemProvider,
        typeIdentifier: String,
        defaultFilename: String,
        defaultMimeType: String,
        kind: CaptureHistoryItem.Kind
    ) async throws -> SharedPayload {
        if let filePayload = try await loadFileRepresentationPayload(
            from: provider,
            typeIdentifier: typeIdentifier,
            defaultFilename: defaultFilename,
            defaultMimeType: defaultMimeType,
            kind: kind
        ) {
            return filePayload
        }

        if typeIdentifier == UTType.fileURL.identifier,
           let url = await loadURL(from: provider),
           url.isFileURL {
            return try loadLocalFilePayload(at: url)
        }

        let rawData: Data? = await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                continuation.resume(returning: data)
            }
        }

        guard let rawData, !rawData.isEmpty else {
            throw ShareExtensionLoadError.emptyContent
        }
        guard rawData.count <= Config.maxUploadSizeBytes else {
            throw ShareExtensionLoadError.fileTooLarge
        }

        let name = provider.suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let filename = (name?.isEmpty == false) ? name! : defaultFilename
        return .attachment(data: rawData, filename: filename, mimeType: defaultMimeType, kind: kind)
    }

    private static func loadFileRepresentationPayload(
        from provider: NSItemProvider,
        typeIdentifier: String,
        defaultFilename: String,
        defaultMimeType: String,
        kind: CaptureHistoryItem.Kind
    ) async throws -> SharedPayload? {
        let suggestedName = provider.suggestedName
        let outcome: Result<SharedPayload?, Error> = await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                if let error {
                    continuation.resume(returning: .failure(error))
                    return
                }
                guard let url else {
                    continuation.resume(returning: .success(nil))
                    return
                }
                do {
                    let payload = try Self.loadLocalFilePayload(
                        at: url,
                        suggestedFilename: suggestedName,
                        fallbackFilename: defaultFilename,
                        fallbackMimeType: defaultMimeType,
                        forcedKind: kind
                    )
                    continuation.resume(returning: .success(payload))
                } catch {
                    continuation.resume(returning: .failure(error))
                }
            }
        }

        switch outcome {
        case .success(let payload):
            return payload
        case .failure(let error):
            if error is ShareExtensionLoadError {
                throw error
            }
            return nil
        }
    }

    private static nonisolated func loadLocalFilePayload(
        at url: URL,
        suggestedFilename: String? = nil,
        fallbackFilename: String = "attachment.bin",
        fallbackMimeType: String = "application/octet-stream",
        forcedKind: CaptureHistoryItem.Kind? = nil
    ) throws -> SharedPayload {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        if let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
           let fileSize = values.fileSize,
           fileSize > Config.maxUploadSizeBytes {
            throw ShareExtensionLoadError.fileTooLarge
        }

        let data = try Data(contentsOf: url)
        guard !data.isEmpty else {
            throw ShareExtensionLoadError.emptyContent
        }
        guard data.count <= Config.maxUploadSizeBytes else {
            throw ShareExtensionLoadError.fileTooLarge
        }

        let utType = UTType(filenameExtension: url.pathExtension)
        let mimeType = utType?.preferredMIMEType ?? fallbackMimeType
        let inferredKind: CaptureHistoryItem.Kind = forcedKind ?? ((utType?.conforms(to: .image) == true) ? .image : .file)

        let rawName = url.lastPathComponent
        let filename: String
        if !rawName.isEmpty && rawName != "/" {
            filename = rawName
        } else if let suggested = suggestedFilename?.trimmingCharacters(in: .whitespacesAndNewlines), !suggested.isEmpty {
            filename = suggested
        } else {
            filename = fallbackFilename
        }

        return .attachment(data: data, filename: filename, mimeType: mimeType, kind: inferredKind)
    }
}

// MARK: - SwiftUI Share Sheet View

private struct ShareSheetView: View {
    @Bindable var viewModel: ShareSheetViewModel
    let onCancel: @MainActor @Sendable () -> Void
    let onComplete: @MainActor @Sendable () -> Void

    private static let quickChips = ["@mac", "@online", "@calls", "@errands", "5m", "15m"]

    var body: some View {
        NavigationStack {
            Group {
                switch viewModel.phase {
                case .loading:
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Preparing capture…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                case .unauthenticated:
                    ContentUnavailableView {
                        Label("Sign In Required", systemImage: "person.crop.circle.badge.exclamationmark")
                    } description: {
                        Text("Open the SkipDrama app and pair your account before sharing items.")
                    } actions: {
                        Button("Close", role: .cancel, action: onCancel)
                            .buttonStyle(.borderedProminent)
                    }

                case .loadError(let message):
                    ContentUnavailableView {
                        Label("Cannot Capture Item", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Close", role: .cancel, action: onCancel)
                            .buttonStyle(.borderedProminent)
                    }

                case .success:
                    VStack(spacing: 14) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(.green)
                        Text("Captured to SkipDrama")
                            .font(.headline)
                        Text("202 Accepted • Queued")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                case .ready, .submitting:
                    composerForm
                }
            }
            .navigationTitle("SkipDrama")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .disabled(viewModel.phase == .submitting || viewModel.phase == .success)
                }
            }
        }
    }

    private var composerForm: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let payload = viewModel.payload {
                    payloadPreviewCard(payload)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Note / Caption")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    TextField("Add a note, context (@mac), or duration (15m)…", text: $viewModel.note, axis: .vertical)
                        .lineLimit(3...6)
                        .padding(12)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Self.quickChips, id: \.self) { chip in
                            let selected = viewModel.isChipSelected(chip)
                            Button {
                                viewModel.appendChip(chip)
                            } label: {
                                Text(chip)
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(
                                        Capsule()
                                            .fill(selected ? Color.accentColor : Color(.secondarySystemGroupedBackground))
                                    )
                                    .foregroundStyle(selected ? Color.white : Color.primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if let error = viewModel.submissionError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }

                Button {
                    Task {
                        await viewModel.submit(onComplete: onComplete)
                    }
                } label: {
                    HStack {
                        Spacer()
                        if viewModel.phase == .submitting {
                            ProgressView()
                                .tint(.white)
                                .padding(.trailing, 6)
                            Text("Sending…")
                        } else {
                            Label("Capture to SkipDrama", systemImage: "arrow.up.circle.fill")
                        }
                        Spacer()
                    }
                    .font(.headline)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.phase == .submitting)
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
    }

    @ViewBuilder
    private func payloadPreviewCard(_ payload: SharedPayload) -> some View {
        switch payload {
        case .link(let url, let title):
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "link.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    if let title, !title.isEmpty, title != url.absoluteString {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                    }
                    Text(url.absoluteString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

        case .text(let text):
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "text.quote")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                Text(text)
                    .font(.subheadline)
                    .lineLimit(5)
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

        case .attachment(let data, let filename, _, let kind):
            HStack(spacing: 12) {
                if let image = viewModel.previewImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    Image(systemName: kind == .image ? "photo.fill" : "doc.fill")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 44, height: 44)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(filename)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

// MARK: - UIViewController Entry Point

@objc(ShareViewController)
final class ShareViewController: UIViewController {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.skipdrama.share",
        category: "ShareViewController"
    )

    private var viewModel: ShareSheetViewModel?

    override func viewDidLoad() {
        super.viewDidLoad()

        let vm = ShareSheetViewModel()
        self.viewModel = vm

        let rootView = ShareSheetView(
            viewModel: vm,
            onCancel: { [weak self] in
                let error = NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
                self?.extensionContext?.cancelRequest(withError: error)
            },
            onComplete: { [weak self] in
                self?.extensionContext?.completeRequest(returningItems: nil)
            }
        )

        let hostingController = UIHostingController(rootView: rootView)
        addChild(hostingController)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hostingController.view)
        NSLayoutConstraint.activate([
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        hostingController.didMove(toParent: self)

        let inputItems = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        Self.logger.debug("Share sheet received \(inputItems.count) extension items.")
        Task {
            await vm.load(from: inputItems)
        }
    }
}
