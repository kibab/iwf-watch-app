import SwiftUI

@main
struct QuickCaptureApp: App {
    @Environment(\.scenePhase) private var scenePhase

    @State private var pairingViewModel: PairingViewModel
    @State private var recordingViewModel: RecordingViewModel

    init() {
        let tokenStore = KeychainTokenStore()
        let pairing = PairingViewModel(tokenStore: tokenStore)
        let recording = RecordingViewModel(tokenStore: tokenStore)

        recording.onUnauthorized = { [weak pairing] in
            pairing?.handleUnauthorized()
        }
        pairing.onPaired = { [weak recording] in
            guard let recording else { return }
            Task { @MainActor in
                await recording.resumePendingUploads()
            }
        }

        _pairingViewModel = State(initialValue: pairing)
        _recordingViewModel = State(initialValue: recording)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if pairingViewModel.isPaired {
                    ContentView(
                        viewModel: recordingViewModel,
                        pairingViewModel: pairingViewModel
                    )
                    .task {
                        await recordingViewModel.resumePendingUploads()
                    }
                } else {
                    PairingView(
                        viewModel: pairingViewModel,
                        pendingQueueCount: recordingViewModel.pendingQueueCount
                    )
                }
            }
            .onOpenURL { url in
                guard pairingViewModel.isPaired else { return }
                recordingViewModel.handleDeepLink(url)
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active,
                   pairingViewModel.isPaired,
                   recordingViewModel.pendingQueueCount > 0 {
                    Task {
                        await recordingViewModel.resumePendingUploads()
                    }
                }
            }
        }
    }
}
