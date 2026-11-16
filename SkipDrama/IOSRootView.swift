import SwiftUI

struct IOSRootView: View {
    @Bindable var pairingViewModel: PairingViewModel
    @Bindable var captureViewModel: IOSCaptureViewModel

    var body: some View {
        Group {
            if pairingViewModel.isPaired {
                IOSMainCaptureView(
                    viewModel: captureViewModel,
                    pairingViewModel: pairingViewModel
                )
                .task {
                    await captureViewModel.handleBecamePaired()
                }
            } else {
                IOSOnboardingView(pairingViewModel: pairingViewModel)
            }
        }
    }
}
