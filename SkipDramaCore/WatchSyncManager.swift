import Foundation
import Observation
import OSLog

#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

/// Synchronizes the `iwf_cap_...` capture token and backend URL from iPhone to paired Apple Watch
/// via `WatchConnectivity`, while preserving standalone Watch pairing as a fallback.
@MainActor
@Observable
final class WatchSyncManager: NSObject {
    static let shared = WatchSyncManager()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.skipdrama",
        category: "WatchSyncManager"
    )

    private enum PayloadKey {
        static let token = "token"
        static let lastChars = "lastChars"
        static let deviceName = "deviceName"
        static let apiBaseURL = "apiBaseURL"
        static let updatedAt = "updatedAt"
    }

    private struct SyncPayload: Sendable {
        let token: String?
        let lastChars: String?
        let deviceName: String?
        let apiBaseURL: String?

        nonisolated init?(dictionary: [String: Any]) {
            let apiBaseURL = dictionary[PayloadKey.apiBaseURL] as? String
            let token = dictionary[PayloadKey.token] as? String
            let lastChars = dictionary[PayloadKey.lastChars] as? String
            let deviceName = dictionary[PayloadKey.deviceName] as? String
            if apiBaseURL == nil && token == nil {
                return nil
            }
            self.token = token
            self.lastChars = lastChars
            self.deviceName = deviceName
            self.apiBaseURL = apiBaseURL
        }
    }

    private struct SessionSnapshot: Sendable {
        let isReachable: Bool
        let isWatchPaired: Bool
        let isWatchAppInstalled: Bool

        #if canImport(WatchConnectivity)
        nonisolated init(session: WCSession) {
            self.isReachable = session.isReachable
            #if os(iOS)
            self.isWatchPaired = session.isPaired
            self.isWatchAppInstalled = session.isWatchAppInstalled
            #else
            self.isWatchPaired = true
            self.isWatchAppInstalled = true
            #endif
        }
        #endif
    }

    private(set) var isSupported = false
    private(set) var isReachable = false
    private(set) var isWatchPaired = false
    private(set) var isWatchAppInstalled = false
    private(set) var lastSyncedAt: Date?

    var onTokenUpdatedFromPeer: (@MainActor () -> Void)?

    private let tokenStore = KeychainTokenStore()
    private var hasActivated = false

    private override init() {
        super.init()
    }

    func activate() {
        guard !hasActivated else { return }
        hasActivated = true

        #if canImport(WatchConnectivity)
        guard WCSession.isSupported() else {
            isSupported = false
            return
        }
        isSupported = true
        let session = WCSession.default
        session.delegate = self
        session.activate()
        applySnapshot(SessionSnapshot(session: session))
        #endif
    }

    /// Pushes the active iPhone token and server URL to the paired Apple Watch in the background.
    func pushCurrentStateToWatch() {
        #if os(iOS) && canImport(WatchConnectivity)
        activate()
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        guard session.isPaired else { return }

        guard let token = tokenStore.readToken(), !token.isEmpty else {
            return
        }

        var payload: [String: Any] = [
            PayloadKey.token: token,
            PayloadKey.apiBaseURL: Config.apiBaseURL,
            PayloadKey.updatedAt: Date().timeIntervalSince1970
        ]
        if let lastChars = tokenStore.readLastChars() {
            payload[PayloadKey.lastChars] = lastChars
        }
        if let deviceName = tokenStore.readDeviceName() {
            payload[PayloadKey.deviceName] = deviceName
        }

        do {
            try session.updateApplicationContext(payload)
            lastSyncedAt = Date()
            Self.logger.info("Updated Watch applicationContext with SkipDrama token.")
        } catch {
            Self.logger.warning("updateApplicationContext failed: \(error.localizedDescription, privacy: .public)")
        }

        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil) { error in
                Self.logger.debug("sendMessage to Watch failed: \(error.localizedDescription, privacy: .public)")
            }
        } else if session.isWatchAppInstalled {
            session.transferUserInfo(payload)
        }
        #endif
    }

    /// Preserves Watch standalone pairing as a fallback when iPhone unpairs.
    func pushUnpairNoticeIfNeeded() {
        #if os(iOS) && canImport(WatchConnectivity)
        Self.logger.debug("iPhone unpaired; leaving Watch standalone pairing intact as fallback.")
        #endif
    }

    // MARK: - Receiving Peer Payloads

    private func applyIncomingPayload(_ payload: SyncPayload) {
        if let incomingBaseURL = payload.apiBaseURL,
           !incomingBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Config.setAPIBaseURL(incomingBaseURL)
        }

        guard let incomingToken = payload.token else {
            return
        }

        let trimmed = incomingToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        do {
            try tokenStore.saveToken(
                trimmed,
                lastChars: payload.lastChars,
                deviceName: payload.deviceName
            )
            lastSyncedAt = Date()
            Self.logger.info("Saved capture token synced from companion peer.")
            onTokenUpdatedFromPeer?()
        } catch {
            Self.logger.error("Failed to save synced token: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func applySnapshot(_ snapshot: SessionSnapshot) {
        isReachable = snapshot.isReachable
        isWatchPaired = snapshot.isWatchPaired
        isWatchAppInstalled = snapshot.isWatchAppInstalled
    }
}

#if canImport(WatchConnectivity)
extension WatchSyncManager: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        let snapshot = SessionSnapshot(session: session)
        let incomingPayload = SyncPayload(dictionary: session.receivedApplicationContext)
        let errorMessage = error?.localizedDescription
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.applySnapshot(snapshot)
            if let errorMessage {
                Self.logger.warning("WCSession activation error: \(errorMessage, privacy: .public)")
            }
            if activationState == .activated {
                if let incomingPayload {
                    self.applyIncomingPayload(incomingPayload)
                }
                #if os(iOS)
                self.pushCurrentStateToWatch()
                #endif
            }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let snapshot = SessionSnapshot(session: session)
        Task { @MainActor [weak self] in
            self?.applySnapshot(snapshot)
        }
    }

    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        let snapshot = SessionSnapshot(session: session)
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.applySnapshot(snapshot)
            self.pushCurrentStateToWatch()
        }
    }
    #endif

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let payload = SyncPayload(dictionary: applicationContext) else { return }
        Task { @MainActor [weak self] in
            self?.applyIncomingPayload(payload)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard let payload = SyncPayload(dictionary: userInfo) else { return }
        Task { @MainActor [weak self] in
            self?.applyIncomingPayload(payload)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let payload = SyncPayload(dictionary: message) else { return }
        Task { @MainActor [weak self] in
            self?.applyIncomingPayload(payload)
        }
    }
}
#endif
