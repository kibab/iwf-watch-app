import AppIntents
import Foundation

/// Background App Intent that sends a task straight to `POST /api/capture` without opening the app.
struct QuickTextCaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture Task to SkipDrama"
    static let description = IntentDescription("Sends a task directly to SkipDrama in the background without opening the app.")
    static let openAppWhenRun: Bool = false

    @Parameter(
        title: "Task",
        requestValueDialog: IntentDialog("What would you like to capture?")
    )
    var text: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .result(dialog: "Nothing to capture.")
        }

        let tokenStore = KeychainTokenStore()
        guard tokenStore.hasToken else {
            throw SkipDramaIntentError.notAuthenticated
        }

        let succeeded = await CaptureHistoryStore.shared.submitText(trimmed)
        if succeeded {
            return .result(dialog: "Captured to SkipDrama.")
        } else {
            let errorDetail = CaptureHistoryStore.shared.items.first?.errorMessage ?? "Saved offline to retry later."
            return .result(dialog: "Saved for retry: \(errorDetail)")
        }
    }
}

/// Registers SkipDrama intents with the system so they appear immediately in
/// Settings → Action Button, Shortcuts, Spotlight, and Siri without `.shortcut` downloads.
struct SkipDramaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartVoiceCaptureIntent(),
            phrases: [
                "Record a voice memo in \(.applicationName)",
                "Start voice capture in \(.applicationName)",
                "Voice capture in \(.applicationName)"
            ],
            shortTitle: "Voice Capture",
            systemImageName: "mic.fill"
        )
        AppShortcut(
            intent: QuickTextCaptureIntent(),
            phrases: [
                "Capture a task in \(.applicationName)",
                "Add a task in \(.applicationName)",
                "Quick capture in \(.applicationName)"
            ],
            shortTitle: "Capture Task",
            systemImageName: "square.and.pencil"
        )
    }
}
