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

/// Manages `AVAudioSession`, `AVAudioRecorder`, and the persistent `.m4a` upload queue on Apple Watch.
@MainActor
final class AudioRecorder: NSObject {
    /// Invoked if watchOS interrupts or halts an active recording unexpectedly.
    var onUnexpectedStop: (@MainActor () -> Void)?

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.iwf.quickcapture",
        category: "AudioRecorder"
    )

    private static let queueDirectoryName = "PendingCaptures"
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

    private let queueDirectoryURL: URL
    private var recorder: AVAudioRecorder?
    private var currentFileURL: URL?
    private nonisolated(unsafe) var interruptionObserver: NSObjectProtocol?

    override init() {
        self.queueDirectoryURL = Self.resolveQueueDirectoryURL()
        super.init()
        cleanupEmptyOrphanedFiles()
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

    /// Starts recording to a unique `.m4a` file in the persistent local upload queue directory.
    func startRecording() throws {
        if recorder != nil {
            _ = stopRecording()
        }

        ensureQueueDirectoryExists()

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)
        } catch {
            Self.logger.error("Failed to configure AVAudioSession: \(error.localizedDescription, privacy: .public)")
            throw AudioRecorderError.sessionConfigurationFailed(error.localizedDescription)
        }

        let timestampMillis = UInt64(max(0, Date().timeIntervalSince1970 * 1000))
        let filename = String(format: "%@%013llu-%@", Self.filePrefix, timestampMillis, UUID().uuidString)
        let fileURL = queueDirectoryURL
            .appendingPathComponent(filename)
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

    /// Returns all pending non-empty `.m4a` files in the upload queue sorted oldest-first.
    func pendingRecordings() -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: queueDirectoryURL,
            includingPropertiesForKeys: [.creationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let activeURL = currentFileURL?.standardizedFileURL
        return contents
            .filter { url in
                url.standardizedFileURL != activeURL
                    && url.lastPathComponent.hasPrefix(Self.filePrefix)
                    && url.pathExtension.lowercased() == Self.fileExtension
                    && hasNonZeroFileSize(at: url)
            }
            .sorted { lhs, rhs in
                lhs.lastPathComponent < rhs.lastPathComponent
            }
    }

    /// Number of `.m4a` recordings currently waiting in the local upload queue.
    func pendingRecordingCount() -> Int {
        pendingRecordings().count
    }

    /// Deletes a queued audio file from disk (call only after confirmed upload success or if invalid/empty).
    func deleteRecording(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            Self.logger.warning("Failed to delete audio file: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Private Helpers

    private static func resolveQueueDirectoryURL() -> URL {
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let queueURL = appSupport.appendingPathComponent(queueDirectoryName, isDirectory: true)
            try? FileManager.default.createDirectory(at: queueURL, withIntermediateDirectories: true)
            return queueURL
        }
        let fallback = FileManager.default.temporaryDirectory.appendingPathComponent(queueDirectoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }

    private func ensureQueueDirectoryExists() {
        if !FileManager.default.fileExists(atPath: queueDirectoryURL.path) {
            try? FileManager.default.createDirectory(at: queueDirectoryURL, withIntermediateDirectories: true)
        }
    }

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

    /// Removes only zero-byte leftovers on startup; preserves valid `.m4a` recordings in the upload queue.
    private func cleanupEmptyOrphanedFiles() {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: queueDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for url in contents where url.lastPathComponent.hasPrefix(Self.filePrefix)
            && url.pathExtension.lowercased() == Self.fileExtension
            && !hasNonZeroFileSize(at: url) {
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
