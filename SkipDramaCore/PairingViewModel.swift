import Foundation
import Observation
import OSLog
import SwiftUI

/// Coordinates RFC 8628-style device pairing, manual token entry, Keychain storage, and Watch sync.
@MainActor
@Observable
final class PairingViewModel {
    struct SessionDisplay: Equatable, Sendable {
        let userCode: String
        let userCodeFormatted: String
        let pairURL: String
        let pairHost: String
        let expiresAt: Date
        let pollIntervalSeconds: Int
    }

    enum Phase: Equatable, Sendable {
        case loading
        case active(SessionDisplay)
        case expired
        case rateLimited
        case error(String)
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.skipdrama",
        category: "PairingViewModel"
    )

    private(set) var isPaired: Bool
    private(set) var tokenLastChars: String
    private(set) var phase: Phase = .loading

    var manualTokenInput: String = ""
    var manualTokenError: String?

    var onPaired: (@MainActor () -> Void)?

    private let pairingService: PairingService
    private let tokenStore: KeychainTokenStore

    // Held strictly in memory during an active pairing session; never persisted to disk/UserDefaults/Keychain.
    private var deviceSecret: String?
    private var startTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var isViewVisible = false

    init(
        pairingService: PairingService = PairingService(),
        tokenStore: KeychainTokenStore = KeychainTokenStore()
    ) {
        self.pairingService = pairingService
        self.tokenStore = tokenStore
        self.isPaired = tokenStore.hasToken
        self.tokenLastChars = tokenStore.readLastChars() ?? "••••"
    }

    // MARK: - Lifecycle

    func onAppear(isSceneActive: Bool) {
        isViewVisible = true
        refreshFromTokenStore()
        guard !isPaired, isSceneActive else { return }

        switch phase {
        case .active(let session) where deviceSecret != nil:
            resumeIfUnexpired(session: session)
        case .loading:
            if startTask == nil {
                requestNewCode()
            }
        case .active, .expired, .rateLimited, .error:
            if case .active = phase, deviceSecret == nil {
                requestNewCode()
            }
        }
    }

    func onDisappear() {
        isViewVisible = false
        cancelBackgroundTasks()
    }

    func handleScenePhaseChange(_ newPhase: ScenePhase) {
        guard !isPaired else {
            cancelBackgroundTasks()
            return
        }

        if newPhase != .active {
            cancelBackgroundTasks()
            return
        }

        guard isViewVisible else { return }

        switch phase {
        case .active(let session) where deviceSecret != nil:
            resumeIfUnexpired(session: session)
        case .loading:
            if startTask == nil {
                requestNewCode()
            }
        case .active:
            requestNewCode()
        case .expired, .rateLimited, .error:
            break
        }
    }

    // MARK: - Actions

    func requestNewCode() {
        cancelBackgroundTasks()
        deviceSecret = nil
        phase = .loading

        let deviceName = PlatformFeedback.defaultDeviceName

        startTask = Task { [weak self] in
            guard let self else { return }
            defer { self.startTask = nil }

            do {
                let response = try await self.pairingService.startPairing(deviceName: deviceName)
                guard !Task.isCancelled else { return }

                if Date() >= response.expiresAt {
                    self.deviceSecret = nil
                    self.phase = .expired
                    return
                }

                let session = SessionDisplay(
                    userCode: response.userCode,
                    userCodeFormatted: response.userCodeFormatted,
                    pairURL: response.pairURL,
                    pairHost: Config.displayHost(for: response.pairURL),
                    expiresAt: response.expiresAt,
                    pollIntervalSeconds: max(1, response.pollIntervalSeconds)
                )

                self.deviceSecret = response.deviceSecret
                self.phase = .active(session)

                if self.isViewVisible {
                    self.scheduleExpiry(for: session.expiresAt)
                    self.startPollingLoop(immediatePoll: false, session: session)
                }
            } catch is CancellationError {
                return
            } catch PairingError.rateLimited {
                self.deviceSecret = nil
                self.phase = .rateLimited
            } catch {
                self.deviceSecret = nil
                self.phase = .error(error.localizedDescription)
            }
        }
    }

    /// Pairs immediately using a manually pasted `iwf_cap_...` token from `/settings/integrations`.
    @discardableResult
    func pairWithManualToken(_ rawToken: String, deviceName: String? = nil) -> Bool {
        let trimmed = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard KeychainTokenStore.isValidManualToken(trimmed) else {
            manualTokenError = "Enter a valid token starting with iwf_cap_"
            PlatformFeedback.playFailure()
            return false
        }

        do {
            try tokenStore.saveToken(
                trimmed,
                lastChars: String(trimmed.suffix(4)),
                deviceName: deviceName ?? PlatformFeedback.defaultDeviceName
            )
        } catch {
            manualTokenError = error.localizedDescription
            PlatformFeedback.playFailure()
            return false
        }

        manualTokenError = nil
        manualTokenInput = ""
        deviceSecret = nil
        cancelBackgroundTasks()
        tokenLastChars = tokenStore.readLastChars() ?? String(trimmed.suffix(4))
        isPaired = true
        PlatformFeedback.playSuccess()
        WatchSyncManager.shared.pushCurrentStateToWatch()
        onPaired?()
        return true
    }

    /// Refreshes pairing state after Keychain or WatchConnectivity updates.
    func refreshFromTokenStore() {
        let currentlyHasToken = tokenStore.hasToken
        let latestLastChars = tokenStore.readLastChars() ?? "••••"
        let newlyPaired = !isPaired && currentlyHasToken

        tokenLastChars = latestLastChars
        isPaired = currentlyHasToken

        if newlyPaired {
            deviceSecret = nil
            cancelBackgroundTasks()
            PlatformFeedback.playSuccess()
            onPaired?()
        }
    }

    /// Clears the Keychain token and returns to the pairing flow.
    func unpair() {
        cancelBackgroundTasks()
        deviceSecret = nil
        manualTokenError = nil
        tokenStore.deleteToken()
        tokenLastChars = "••••"
        isPaired = false
        phase = .loading
        WatchSyncManager.shared.pushUnpairNoticeIfNeeded()
        if isViewVisible {
            requestNewCode()
        }
    }

    /// Invoked when an upload receives `401 Unauthorized` and the revoked token has been removed.
    func handleUnauthorized() {
        cancelBackgroundTasks()
        deviceSecret = nil
        tokenStore.deleteToken()
        tokenLastChars = "••••"
        isPaired = false
        phase = .loading
    }

    /// Refreshes pairing state after changing backend URL in Settings.
    func handleServerURLChanged() {
        WatchSyncManager.shared.pushCurrentStateToWatch()
        guard !isPaired else { return }
        requestNewCode()
    }

    // MARK: - Polling & Expiration

    private func resumeIfUnexpired(session: SessionDisplay) {
        if Date() >= session.expiresAt {
            markExpired()
            return
        }
        scheduleExpiry(for: session.expiresAt)
        startPollingLoop(immediatePoll: true, session: session)
    }

    private func startPollingLoop(immediatePoll: Bool, session: SessionDisplay) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            let interval = Duration.seconds(session.pollIntervalSeconds)

            if immediatePoll {
                let shouldContinue = await self.performSinglePoll(session: session)
                if !shouldContinue || Task.isCancelled { return }
            }

            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }

                let shouldContinue = await self.performSinglePoll(session: session)
                if !shouldContinue { return }
            }
        }
    }

    private func performSinglePoll(session: SessionDisplay) async -> Bool {
        if Date() >= session.expiresAt {
            markExpired()
            return false
        }

        guard let secret = deviceSecret else {
            return false
        }

        do {
            let result = try await pairingService.pollPairing(deviceSecret: secret)
            guard !Task.isCancelled else { return false }

            switch result {
            case .pending:
                return true
            case .paired(let token, let name, let lastChars):
                do {
                    try tokenStore.saveToken(token, lastChars: lastChars, deviceName: name)
                } catch {
                    Self.logger.error("Failed to persist token to Keychain: \(error.localizedDescription, privacy: .public)")
                    self.deviceSecret = nil
                    self.cancelBackgroundTasks()
                    self.phase = .error(error.localizedDescription)
                    return false
                }

                self.deviceSecret = nil
                self.cancelBackgroundTasks()
                self.tokenLastChars = self.tokenStore.readLastChars() ?? lastChars ?? String(token.suffix(4))
                self.isPaired = true
                PlatformFeedback.playSuccess()
                WatchSyncManager.shared.pushCurrentStateToWatch()
                self.onPaired?()
                return false
            }
        } catch is CancellationError {
            return false
        } catch PairingError.codeExpired {
            markExpired()
            return false
        } catch PairingError.rateLimited {
            cancelBackgroundTasks()
            deviceSecret = nil
            phase = .rateLimited
            return false
        } catch PairingError.invalidConfiguration(let message) {
            cancelBackgroundTasks()
            deviceSecret = nil
            phase = .error(message)
            return false
        } catch {
            // Keep the active pairing code on screen and continue polling on transient network errors until expiresAt.
            Self.logger.debug("Transient poll error: \(error.localizedDescription, privacy: .public)")
            return true
        }
    }

    private func scheduleExpiry(for expiresAt: Date) {
        expiryTask?.cancel()
        let remaining = expiresAt.timeIntervalSinceNow
        if remaining <= 0 {
            markExpired()
            return
        }

        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled, let self else { return }
            self.markExpired()
        }
    }

    private func markExpired() {
        cancelBackgroundTasks()
        deviceSecret = nil
        phase = .expired
    }

    private func cancelBackgroundTasks() {
        startTask?.cancel()
        startTask = nil
        pollTask?.cancel()
        pollTask = nil
        expiryTask?.cancel()
        expiryTask = nil
    }
}
