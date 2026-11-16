import SwiftUI

@main
struct SkipDramaIOSApp: App {
    @Environment(\.scenePhase) private var scenePhase

    @State private var pairingViewModel: PairingViewModel
    @State private var captureViewModel: IOSCaptureViewModel

    init() {
        let tokenStore = KeychainTokenStore()
        let pairing = PairingViewModel(tokenStore: tokenStore)
        let historyStore = CaptureHistoryStore.shared
        let capture = IOSCaptureViewModel(historyStore: historyStore, tokenStore: tokenStore)

        historyStore.onUnauthorized = { [weak pairing] in
            pairing?.handleUnauthorized()
        }

        pairing.onPaired = { [weak capture] in
            WatchSyncManager.shared.pushCurrentStateToWatch()
            guard let capture else { return }
            Task { @MainActor in
                await capture.handleBecamePaired()
            }
        }

        WatchSyncManager.shared.onTokenUpdatedFromPeer = { [weak pairing] in
            pairing?.refreshFromTokenStore()
        }
        WatchSyncManager.shared.activate()

        _pairingViewModel = State(initialValue: pairing)
        _captureViewModel = State(initialValue: capture)
    }

    var body: some Scene {
        WindowGroup {
            IOSRootView(
                pairingViewModel: pairingViewModel,
                captureViewModel: captureViewModel
            )
            .onOpenURL { url in
                captureViewModel.handleDeepLink(url)
            }
            .onReceive(NotificationCenter.default.publisher(for: .skipDramaStartVoiceCapture)) { _ in
                captureViewModel.triggerVoiceCaptureFromSystem()
            }
            .onReceive(NotificationCenter.default.publisher(for: .skipDramaOpenTextCapture)) { _ in
                captureViewModel.triggerTextCaptureFromSystem()
            }
            .onReceive(NotificationCenter.default.publisher(for: .skipDramaHistoryDidChange)) { _ in
                captureViewModel.historyStore.reload()
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    pairingViewModel.refreshFromTokenStore()
                    captureViewModel.consumePendingIntentRequests()
                    if pairingViewModel.isPaired {
                        WatchSyncManager.shared.pushCurrentStateToWatch()
                        Task {
                            await captureViewModel.resumePendingUploads()
                        }
                    }
                }
            }
            .task {
                captureViewModel.consumePendingIntentRequests()
            }
        }
    }
}
