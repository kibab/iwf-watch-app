import Foundation
import Observation
import WatchKit

/// Observable state machine coordinating audio recording, timer auto-stop, haptics, and upload.
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

    private let recorder: AudioRecorder
    private let client: CaptureClient

    private var timerTask: Task<Void, Never>?
    private var resetTask: Task<Void, Never>?
    private var recordingStartDate: Date?
    private var isTransitioning = false

    init(
        recorder: AudioRecorder = AudioRecorder(),
        client: CaptureClient = CaptureClient()
    ) {
        self.recorder = recorder
        self.client = client

        self.recorder.onUnexpectedStop = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await self.handleUnexpectedRecorderStop()
            }
        }
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

    /// Launches straight into recording when opened from the Watch Face complication (`quickcapture://record`).
    func handleDeepLink(_ url: URL) {
        guard Config.isRecordDeepLink(url), !isTransitioning else {
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

    /// Stops recording, triggers upload streaming from disk, and always cleans up the temp file.
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

        guard let fileURL else {
            isTransitioning = false
            WKInterfaceDevice.current().play(.failure)
            state = .error("No audio captured")
            scheduleAutoReset()
            return
        }

        state = .uploading
        isTransitioning = false

        defer {
            recorder.deleteRecording(at: fileURL)
        }

        do {
            try await client.uploadVoiceMemo(fileURL: fileURL)
            WKInterfaceDevice.current().play(.success)
            state = .success
            scheduleAutoReset()
        } catch is CancellationError {
            state = .idle
        } catch {
            WKInterfaceDevice.current().play(.failure)
            state = .error(error.localizedDescription)
            scheduleAutoReset()
        }
    }

    // MARK: - Private Helpers

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

        if let fileURL = recorder.stopRecording() {
            WKInterfaceDevice.current().play(.stop)
            state = .uploading

            defer {
                recorder.deleteRecording(at: fileURL)
            }

            do {
                try await client.uploadVoiceMemo(fileURL: fileURL)
                WKInterfaceDevice.current().play(.success)
                state = .success
                scheduleAutoReset()
            } catch is CancellationError {
                state = .idle
            } catch {
                WKInterfaceDevice.current().play(.failure)
                state = .error(error.localizedDescription)
                scheduleAutoReset()
            }
        } else {
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

