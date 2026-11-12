import SwiftUI

@main
struct QuickCaptureApp: App {
    @State private var viewModel = RecordingViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .onOpenURL { url in
                    viewModel.handleDeepLink(url)
                }
        }
    }
}

