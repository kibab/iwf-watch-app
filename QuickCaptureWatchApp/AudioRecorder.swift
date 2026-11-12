import AVFoundation
import Foundation
import OSLog

/// Errors raised while configuring the watchOS audio session or recording a memo.
enum AudioRecorderError: LocalizedError, Sendable, Equatable {
    case permissionDenied
    case sessionConfigurationFailed(String)
    case recorderInitFailed(String)
    case recordingFailedToStart

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Mic access denied"
        case .sessionConfigurationFailed:
            return "Audio setup failed"
        case .recorderInitFailed:
            return "Recorder init failed"
        case .recordingFailedToStart:
            return "Could not record"
        }
    }
}

/// Manages `AVAudioSession` and `AVAudioRecorder` for low-memory voice capture on Apple Watch.
@MainActor
final class AudioRecorder: NSObject {
    /// Invoked if watchOS interrupts or halts an active recording unexpectedly.
    var onUnexpectedStop: (@MainActor () -> Void)?

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.iwf.quickcapture",
        category: "AudioRecorder"
    )

    private static let filePrefix = "memo-"
    private static let fileExtension = "m4a"

    /// AAC-LC mono 44.1 kHz @ 64 kbps tuned for voice bandwidth and S6/S7 audio DSP.
    private static let recordingSettings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: 44_100.0,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 64_000,
        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
    ]

    private var recorder: AVAudioRecorder?
    private var currentFileURL: URL?
    private nonisolated(unsafe) var interruptionObserver: NSObjectProtocol?

    override init() {
        super.init()
        cleanupOrphanedRecordings()
        registerForInterruptions()
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
    }

    /// Requests microphone permission using watchOS 10+ `AVAudioApplication`.
    func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    /// Starts recording to a unique `.m4a` file in `FileManager.default.temporaryDirectory`.
    func startRecording() throws {
        if recorder != nil {
            _ = stopRecording()
        }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .spokenAudio)
            try session.setActive(true)
        } catch {
            Self.logger.error("Failed to configure AVAudioSession: \(error.localizedDescription, privacy: .public)")
            throw AudioRecorderError.sessionConfigurationFailed(error.localizedDescription)
        }

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(Self.filePrefix)\(UUID().uuidString)")
            .appendingPathExtension(Self.fileExtension)

        let audioRecorder: AVAudioRecorder
        do {
            audioRecorder = try AVAudioRecorder(url: fileURL, settings: Self.recordingSettings)
        } catch {
            deactivateAudioSession()
            deleteRecording(at: fileURL)
            Self.logger.error("Failed to initialize AVAudioRecorder: \(error.localizedDescription, privacy: .public)")
            throw AudioRecorderError.recorderInitFailed(error.localizedDescription)
        }

        audioRecorder.delegate = self

        guard audioRecorder.prepareToRecord(), audioRecorder.record() else {
            audioRecorder.delegate = nil
            deactivateAudioSession()
            deleteRecording(at: fileURL)
            Self.logger.error("AVAudioRecorder failed to prepare or start recording.")
            throw AudioRecorderError.recordingFailedToStart
        }

        recorder = audioRecorder
        currentFileURL = fileURL
    }

    /// Stops the active recording, deactivates the audio session, and returns the `.m4a` file URL if non-empty.
    func stopRecording() -> URL? {
        guard let activeRecorder = recorder else {
            return nil
        }

        let fileURL = currentFileURL
        activeRecorder.delegate = nil
        if activeRecorder.isRecording {
            activeRecorder.stop()
        }

        recorder = nil
        currentFileURL = nil
        deactivateAudioSession()

        guard let fileURL else {
            return nil
        }

        guard hasNonZeroFileSize(at: fileURL) else {
            deleteRecording(at: fileURL)
            return nil
        }

        return fileURL
    }

    /// Deletes a temporary audio file from disk after upload succeeds or fails.
    func deleteRecording(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            Self.logger.warning("Failed to delete temporary audio file: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Private Helpers

    private func deactivateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            Self.logger.debug("Audio session deactivation returned: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func hasNonZeroFileSize(at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = (attributes[.size] as? NSNumber)?.uint64Value else {
            return false
        }
        return fileSize > 0
    }

    private func cleanupOrphanedRecordings() {
        let tempDir = FileManager.default.temporaryDirectory
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: tempDir,
            includingPropertiesForKeys: nil
        ) else {
            return
        }

        for url in contents where url.lastPathComponent.hasPrefix(Self.filePrefix)
            && url.pathExtension.lowercased() == Self.fileExtension {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func registerForInterruptions() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { [weak self] notification in
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard let rawType,
                  let type = AVAudioSession.InterruptionType(rawValue: rawType),
                  type == .began else {
                return
            }

            Task { @MainActor [weak self] in
                guard let self, self.recorder != nil else { return }
                Self.logger.notice("Audio session interrupted during active recording.")
                self.onUnexpectedStop?()
            }
        }
    }
}

// MARK: - AVAudioRecorderDelegate

extension AudioRecorder: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.recorder === recorder else { return }
            Self.logger.notice("AVAudioRecorder finished unexpectedly (successfully=\(flag, privacy: .public)).")
            self.onUnexpectedStop?()
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: (any Error)?) {
        let description = error?.localizedDescription ?? "Unknown encode error"
        Task { @MainActor [weak self] in
            guard let self, self.recorder === recorder else { return }
            Self.logger.error("AVAudioRecorder encode error: \(description, privacy: .public)")
            self.onUnexpectedStop?()
        }
    }
}

