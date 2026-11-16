import AppIntents
import Foundation

enum SkipDramaIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notAuthenticated

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notAuthenticated:
            return "Open SkipDrama and pair your account first."
        }
    }
}

/// Opens SkipDrama straight into active voice capture mode.
/// Exposed automatically in Settings → Action Button, Control Center, Shortcuts, and Siri.
struct StartVoiceCaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Voice Capture"
    static let description = IntentDescription("Opens SkipDrama and immediately starts recording a voice memo.")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        Config.requestImmediateVoiceCapture()
        NotificationCenter.default.post(name: .skipDramaStartVoiceCapture, object: nil)
        return .result()
    }
}

/// Opens SkipDrama with the quick text capture field focused.
struct OpenTextCaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Text Capture"
    static let description = IntentDescription("Opens SkipDrama with the text capture input ready.")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        Config.requestImmediateTextCapture()
        NotificationCenter.default.post(name: .skipDramaOpenTextCapture, object: nil)
        return .result()
    }
}
