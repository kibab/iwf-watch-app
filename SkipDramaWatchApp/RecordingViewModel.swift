import Foundation
import Observation
import WatchKit

/// Observable state machine coordinating audio recording, timer auto-stop, haptics, and queued uploads.
@MainActor
@Observable
final class RecordingViewModel {
    enum State: Equatable, Sendable {
        case idle
        case recording(duration: TimeInterval)
        case uploading
        case success
        case error(String)
    }

    private(set) var state: State = .idle
    private(set) var pendingQueueCount: Int = 0

    var onUnauthorized: (@MainActor () -> Void)?

    private let recorder: AudioRecorder
    private let client: CaptureClient
    private let tokenStore: KeychainTokenStore

    private var timerTask: Task<Void, Never>?
    private var resetTask: Task<Void, Never>?
    private var recordingStartDate: Date?
    private var isTransitioning = false
    private var isUploadingQueue = false

    init(
        recorder: AudioRecorder = AudioRecorder(),
        client: CaptureClient? = nil,
        tokenStore: KeychainTokenStore = KeychainTokenStore()
    ) {
        self.recorder = recorder
        self.tokenStore = tokenStore
        self.client = client ?? CaptureClient(tokenStore: tokenStore)
        self.pendingQueueCount = recorder.pendingRecordingCount()

        self.recorder.onUnexpectedStop = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await self.handleUnexpectedRecorderStop()
            }
        }
    }

    /// Refreshes the count of `.m4a` files waiting in the local upload queue.
    func refreshPendingQueueCount() {
        pendingQueueCount = recorder.pendingRecordingCount()
    }

    /// Handles tapping the central action button.
    func toggleRecording() {
        switch state {
        case .idle:
            Task { await startRecording() }
        case .recording:
            Task { await stopRecordingAndUpload() }
        case .error:
            resetTask?.cancel()
            resetTask = nil
            state = .idle
        case .uploading, .success:
            break
        }
    }

    /// Launches straight into recording when opened from the Watch Face complication.
    func handleDeepLink(_ url: URL) {
        guard Config.isRecordDeepLink(url), !isTransitioning, tokenStore.hasToken else {
            return
        }

        switch state {
        case .recording, .uploading:
            return
        case .success, .error:
            resetTask?.cancel()
            resetTask = nil
            state = .idle
        case .idle:
            break
        }

        Task { await startRecording() }
    }

    /// Requests microphone access, plays `.start` haptic, and begins recording up to `Config.maxRecordingDuration`.
    func startRecording() async {
        guard !isTransitioning, case .idle = state else {
            return
        }

        isTransitioning = true
        defer { isTransitioning = false }

        resetTask?.cancel()
        resetTask = nil

        let granted = await recorder.requestPermission()
        guard granted else {
            WKInterfaceDevice.current().play(.failure)
            state = .error(AudioRecorderError.permissionDenied.localizedDescription)
            scheduleAutoReset()
            return
        }

        // Trigger the start haptic before activating `.record` so watchOS does not suppress it.
        WKInterfaceDevice.current().play(.start)

        do {
            try recorder.startRecording()
        } catch {
            WKInterfaceDevice.current().play(.failure)
            state = .error(error.localizedDescription)
            scheduleAutoReset()
            return
        }

        recordingStartDate = Date()
        state = .recording(duration: 0)
        startDurationTimer()
    }

    /// Stops recording and uploads queued `.m4a` files, deleting each file only after HTTP `202` success.
    func stopRecordingAndUpload() async {
        guard !isTransitioning, case .recording = state else {
            return
        }

        isTransitioning = true
        timerTask?.cancel()
        timerTask = nil
        recordingStartDate = nil

        let fileURL = recorder.stopRecording()
        WKInterfaceDevice.current().play(.stop)
        refreshPendingQueueCount()

        guard fileURL != nil else {
            isTransitioning = false
            WKInterfaceDevice.current().play(.failure)
            state = .error("No audio captured")
            scheduleAutoReset()
            return
        }

        isTransitioning = false
        await uploadPendingQueue()
    }

    /// Automatically uploads any queued `.m4a` recordings (for example after re-pairing or app launch).
    func resumePendingUploads() async {
        guard !isTransitioning, !isUploadingQueue, tokenStore.hasToken else {
            refreshPendingQueueCount()
            return
        }

        switch state {
        case .recording, .uploading:
            return
        case .success, .error:
            resetTask?.cancel()
            resetTask = nil
        case .idle:
            break
        }

        let pending = recorder.pendingRecordings()
        pendingQueueCount = pending.count
        guard !pending.isEmpty else {
            return
        }

        await uploadPendingQueue()
    }

    // MARK: - Private Helpers

    private func uploadPendingQueue() async {
        guard !isUploadingQueue else { return }

        let queuedFiles = recorder.pendingRecordings()
        pendingQueueCount = queuedFiles.count
        guard !queuedFiles.isEmpty else {
            state = .idle
            return
        }

        isUploadingQueue = true
        defer { isUploadingQueue = false }

        resetTask?.cancel()
        resetTask = nil
        state = .uploading

        for fileURL in queuedFiles {
            do {
                try await client.uploadVoiceMemo(fileURL: fileURL)
                recorder.deleteRecording(at: fileURL)
                refreshPendingQueueCount()
            } catch is CancellationError {
                refreshPendingQueueCount()
                state = .idle
                return
            } catch CaptureError.unauthorized {
                // CRITICAL: Preserve all queued `.m4a` files, clear the revoked token, and re-pair.
                tokenStore.deleteToken()
                refreshPendingQueueCount()
                state = .idle
                WKInterfaceDevice.current().play(.failure)
                onUnauthorized?()
                return
            } catch {
                refreshPendingQueueCount()
                WKInterfaceDevice.current().play(.failure)
                state = .error(error.localizedDescription)
                scheduleAutoReset()
                return
            }
        }

        refreshPendingQueueCount()
        WKInterfaceDevice.current().play(.success)
        state = .success
        scheduleAutoReset()
    }

    private func startDurationTimer() {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self else { return }

                guard let startDate = self.recordingStartDate,
                      case .recording = self.state else {
                    return
                }

                let elapsed = min(
                    Date().timeIntervalSince(startDate),
                    Config.maxRecordingDuration
                )
                self.state = .recording(duration: elapsed)

                if elapsed >= Config.maxRecordingDuration {
                    await self.stopRecordingAndUpload()
                    return
                }
            }
        }
    }

    private func handleUnexpectedRecorderStop() async {
        guard case .recording = state else {
            return
        }

        timerTask?.cancel()
        timerTask = nil
        recordingStartDate = nil

        if recorder.stopRecording() != nil {
            WKInterfaceDevice.current().play(.stop)
            refreshPendingQueueCount()
            await uploadPendingQueue()
        } else {
            refreshPendingQueueCount()
            WKInterfaceDevice.current().play(.failure)
            state = .error("Recording interrupted")
            scheduleAutoReset()
        }
    }

    private func scheduleAutoReset() {
        resetTask?.cancel()
        resetTask = Task { [weak self] in
            try? await Task.sleep(for: Config.autoResetDelay)
            guard !Task.isCancelled, let self else { return }

            switch self.state {
            case .success, .error:
                self.state = .idle
            case .idle, .recording, .uploading:
                break
            }
        }
    }
}
