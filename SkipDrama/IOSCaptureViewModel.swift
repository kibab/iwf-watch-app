import Foundation
import Observation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class IOSCaptureViewModel {
    enum VoiceState: Equatable, Sendable {
        case idle
        case recording(duration: TimeInterval, level: Float)
        case sending
    }

    struct StatusBanner: Equatable, Sendable {
        let isError: Bool
        let message: String
    }

    struct PendingAttachment: Equatable, Sendable {
        let data: Data
        let filename: String
        let mimeType: String
        let kind: CaptureHistoryItem.Kind

        var sizeDescription: String {
            ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
        }
    }

    static let gtdContexts = ["@mac", "@online", "@calls", "@errands", "@home"]
    static let durationChips = ["5m", "10m", "15m", "25m", "40m"]
    private static let levelBarCount = 24

    private(set) var voiceState: VoiceState = .idle
    private(set) var audioLevels: [Float] = Array(repeating: 0.08, count: levelBarCount)
    private(set) var banner: StatusBanner?
    private(set) var pendingAttachment: PendingAttachment?
    private(set) var isSubmittingText = false

    var textDraft = ""
    var shouldFocusTextField = false

    let historyStore: CaptureHistoryStore
    private let recorder: AudioRecorder
    private let tokenStore: KeychainTokenStore

    private var timerTask: Task<Void, Never>?
    private var bannerDismissTask: Task<Void, Never>?
    private var recordingStartDate: Date?
    private var isTransitioning = false
    private var pendingVoiceTriggerAfterAuth = false
    private var pendingTextTriggerAfterAuth = false

    init(
        recorder: AudioRecorder = AudioRecorder(),
        historyStore: CaptureHistoryStore = .shared,
        tokenStore: KeychainTokenStore = KeychainTokenStore()
    ) {
        self.recorder = recorder
        self.historyStore = historyStore
        self.tokenStore = tokenStore

        self.recorder.onUnexpectedStop = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await self.handleUnexpectedRecorderStop()
            }
        }
    }

    // MARK: - Deep Links & Intent Triggers

    func handleDeepLink(_ url: URL) {
        guard let destination = Config.parseDeepLink(url) else { return }
        switch destination {
        case .voiceCapture:
            triggerVoiceCaptureFromSystem()
        case .textCapture:
            triggerTextCaptureFromSystem()
        }
    }

    func consumePendingIntentRequests() {
        if Config.consumePendingVoiceCaptureRequest() {
            triggerVoiceCaptureFromSystem()
        } else if Config.consumePendingTextCaptureRequest() {
            triggerTextCaptureFromSystem()
        }
    }

    func triggerVoiceCaptureFromSystem() {
        guard tokenStore.hasToken else {
            pendingVoiceTriggerAfterAuth = true
            pendingTextTriggerAfterAuth = false
            return
        }
        Task {
            await startVoiceCapture()
        }
    }

    func triggerTextCaptureFromSystem() {
        guard tokenStore.hasToken else {
            pendingTextTriggerAfterAuth = true
            pendingVoiceTriggerAfterAuth = false
            return
        }
        shouldFocusTextField = true
    }

    func handleBecamePaired() async {
        await resumePendingUploads()
        if pendingVoiceTriggerAfterAuth {
            pendingVoiceTriggerAfterAuth = false
            await startVoiceCapture()
        } else if pendingTextTriggerAfterAuth {
            pendingTextTriggerAfterAuth = false
            shouldFocusTextField = true
        }
    }

    // MARK: - Voice Capture

    func toggleVoiceCapture() {
        switch voiceState {
        case .idle:
            Task { await startVoiceCapture() }
        case .recording:
            Task { await stopVoiceCaptureAndSend() }
        case .sending:
            break
        }
    }

    func startVoiceCapture() async {
        guard !isTransitioning, case .idle = voiceState, tokenStore.hasToken else {
            return
        }

        isTransitioning = true
        defer { isTransitioning = false }

        banner = nil
        bannerDismissTask?.cancel()

        let granted = await recorder.requestPermission()
        guard granted else {
            PlatformFeedback.playFailure()
            showBanner(isError: true, message: "Microphone access denied. Enable it in Settings.")
            return
        }

        PlatformFeedback.playStart()
        audioLevels = Array(repeating: 0.08, count: Self.levelBarCount)

        do {
            try recorder.startRecording()
        } catch {
            PlatformFeedback.playFailure()
            showBanner(isError: true, message: error.localizedDescription)
            return
        }

        recordingStartDate = Date()
        voiceState = .recording(duration: 0, level: 0)
        startMeteringTimer()
    }

    func stopVoiceCaptureAndSend() async {
        guard !isTransitioning, case .recording(let capturedDuration, _) = voiceState else {
            return
        }

        isTransitioning = true
        timerTask?.cancel()
        timerTask = nil
        recordingStartDate = nil

        let fileURL = recorder.stopRecording()
        PlatformFeedback.playStop()

        guard let fileURL else {
            voiceState = .idle
            isTransitioning = false
            PlatformFeedback.playFailure()
            showBanner(isError: true, message: "No audio captured")
            return
        }

        voiceState = .sending
        isTransitioning = false

        let succeeded = await historyStore.submitVoice(fileURL: fileURL, duration: capturedDuration)
        voiceState = .idle

        if succeeded {
            PlatformFeedback.playSuccess()
            showBanner(isError: false, message: "202 Accepted • Voice queued")
        } else {
            PlatformFeedback.playFailure()
            let errorText = historyStore.items.first?.errorMessage ?? "Offline"
            showBanner(isError: true, message: "Saved for retry (\(errorText))")
        }
    }

    // MARK: - Text, Chips & Attachments

    func isChipSelected(_ chip: String) -> Bool {
        let tokens = textDraft.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return tokens.contains(chip)
    }

    func toggleChip(_ chip: String) {
        PlatformFeedback.playSelection()
        var tokens = textDraft.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if let index = tokens.firstIndex(of: chip) {
            tokens.remove(at: index)
            textDraft = tokens.joined(separator: " ")
        } else {
            let trimmed = textDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            textDraft = trimmed.isEmpty ? chip : "\(trimmed) \(chip)"
        }
    }

    func clearPendingAttachment() {
        pendingAttachment = nil
    }

    func loadPhotoItem(_ item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self), !data.isEmpty else {
                showBanner(isError: true, message: "Could not load selected photo")
                return
            }

            guard data.count <= Config.maxUploadSizeBytes else {
                PlatformFeedback.playFailure()
                showBanner(isError: true, message: CaptureError.fileTooLarge.localizedDescription)
                return
            }

            let contentType = item.supportedContentTypes.first ?? .jpeg
            let ext = contentType.preferredFilenameExtension ?? "jpg"
            let mimeType = contentType.preferredMIMEType ?? "image/jpeg"
            let filename = "photo-\(Int(Date().timeIntervalSince1970)).\(ext)"

            pendingAttachment = PendingAttachment(
                data: data,
                filename: filename,
                mimeType: mimeType,
                kind: .image
            )
            PlatformFeedback.playSelection()
        } catch {
            PlatformFeedback.playFailure()
            showBanner(isError: true, message: "Could not read selected photo")
        }
    }

    func loadDocumentURL(_ url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        if let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
           let size = values.fileSize,
           size > Config.maxUploadSizeBytes {
            PlatformFeedback.playFailure()
            showBanner(isError: true, message: CaptureError.fileTooLarge.localizedDescription)
            return
        }

        do {
            let data = try Data(contentsOf: url)
            guard !data.isEmpty else {
                showBanner(isError: true, message: "Selected file is empty")
                return
            }
            guard data.count <= Config.maxUploadSizeBytes else {
                PlatformFeedback.playFailure()
                showBanner(isError: true, message: CaptureError.fileTooLarge.localizedDescription)
                return
            }

            let utType = UTType(filenameExtension: url.pathExtension)
            let mimeType = utType?.preferredMIMEType ?? "application/octet-stream"
            let kind: CaptureHistoryItem.Kind = (utType?.conforms(to: .image) == true) ? .image : .file

            pendingAttachment = PendingAttachment(
                data: data,
                filename: url.lastPathComponent,
                mimeType: mimeType,
                kind: kind
            )
            PlatformFeedback.playSelection()
        } catch {
            PlatformFeedback.playFailure()
            showBanner(isError: true, message: "Failed to read file")
        }
    }

    var canSubmitComposer: Bool {
        !isSubmittingText && (
            !textDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pendingAttachment != nil
        )
    }

    func submitTextOrAttachment() async {
        guard canSubmitComposer else { return }

        let trimmedText = textDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachment = pendingAttachment

        isSubmittingText = true
        defer { isSubmittingText = false }

        textDraft = ""
        pendingAttachment = nil

        let succeeded: Bool
        if let attachment {
            succeeded = await historyStore.submitAttachment(
                data: attachment.data,
                filename: attachment.filename,
                mimeType: attachment.mimeType,
                caption: trimmedText.isEmpty ? nil : trimmedText,
                kind: attachment.kind
            )
        } else {
            let kind: CaptureHistoryItem.Kind = isLikelyURL(trimmedText) ? .link : .text
            succeeded = await historyStore.submitText(trimmedText, kind: kind)
        }

        if succeeded {
            PlatformFeedback.playSuccess()
            showBanner(isError: false, message: "202 Accepted • Queued")
        } else {
            PlatformFeedback.playFailure()
            let errorText = historyStore.items.first?.errorMessage ?? "Offline"
            showBanner(isError: true, message: "Saved for retry (\(errorText))")
        }
    }

    func resumePendingUploads() async {
        historyStore.reload()
        guard tokenStore.hasToken else { return }

        // Recover any raw `.m4a` recordings left on disk before tracking in history.
        let orphanMemos = recorder.pendingRecordings()
        for fileURL in orphanMemos {
            _ = await historyStore.submitVoice(fileURL: fileURL, duration: 0)
        }

        await historyStore.retryAllPending()
    }

    func dismissBanner() {
        bannerDismissTask?.cancel()
        banner = nil
    }

    // MARK: - Private Helpers

    private func startMeteringTimer() {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled, let self else { return }
                guard let startDate = self.recordingStartDate,
                      case .recording = self.voiceState else {
                    return
                }

                let elapsed = min(Date().timeIntervalSince(startDate), Config.maxRecordingDuration)
                let level = self.recorder.currentNormalizedLevel()

                var updatedLevels = self.audioLevels
                if !updatedLevels.isEmpty {
                    updatedLevels.removeFirst()
                    updatedLevels.append(max(0.08, level))
                    self.audioLevels = updatedLevels
                }

                self.voiceState = .recording(duration: elapsed, level: level)

                if elapsed >= Config.maxRecordingDuration {
                    await self.stopVoiceCaptureAndSend()
                    return
                }
            }
        }
    }

    private func handleUnexpectedRecorderStop() async {
        guard case .recording(let capturedDuration, _) = voiceState else {
            return
        }

        timerTask?.cancel()
        timerTask = nil
        recordingStartDate = nil

        if let fileURL = recorder.stopRecording() {
            PlatformFeedback.playStop()
            voiceState = .sending
            let succeeded = await historyStore.submitVoice(fileURL: fileURL, duration: capturedDuration)
            voiceState = .idle
            if succeeded {
                PlatformFeedback.playSuccess()
                showBanner(isError: false, message: "202 Accepted • Voice queued")
            } else {
                PlatformFeedback.playFailure()
                showBanner(isError: true, message: "Recording saved for retry")
            }
        } else {
            voiceState = .idle
            PlatformFeedback.playFailure()
            showBanner(isError: true, message: "Recording interrupted")
        }
    }

    private func showBanner(isError: Bool, message: String) {
        bannerDismissTask?.cancel()
        banner = StatusBanner(isError: isError, message: message)
        bannerDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled else { return }
            self?.banner = nil
        }
    }

    private func isLikelyURL(_ text: String) -> Bool {
        guard !text.contains(" "),
              let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            return false
        }
        return true
    }
}
