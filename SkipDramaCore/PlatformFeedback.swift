import Foundation

#if os(watchOS)
import WatchKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Cross-platform device metadata and tactile feedback helpers for iOS and watchOS.
@MainActor
enum PlatformFeedback {
    private static var isAppExtension: Bool {
        Bundle.main.bundlePath.hasSuffix(".appex")
    }

    static var defaultDeviceName: String {
        #if os(watchOS)
        let rawName = WKInterfaceDevice.current().name.trimmingCharacters(in: .whitespacesAndNewlines)
        return rawName.isEmpty ? "Apple Watch" : rawName
        #elseif canImport(UIKit)
        let rawName = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return rawName.isEmpty ? "iPhone" : rawName
        #else
        return "SkipDrama Device"
        #endif
    }

    static func playStart() {
        #if os(watchOS)
        WKInterfaceDevice.current().play(.start)
        #elseif canImport(UIKit)
        guard !isAppExtension else { return }
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        generator.impactOccurred()
        #endif
    }

    static func playStop() {
        #if os(watchOS)
        WKInterfaceDevice.current().play(.stop)
        #elseif canImport(UIKit)
        guard !isAppExtension else { return }
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred()
        #endif
    }

    static func playSuccess() {
        #if os(watchOS)
        WKInterfaceDevice.current().play(.success)
        #elseif canImport(UIKit)
        guard !isAppExtension else { return }
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.success)
        #endif
    }

    static func playFailure() {
        #if os(watchOS)
        WKInterfaceDevice.current().play(.failure)
        #elseif canImport(UIKit)
        guard !isAppExtension else { return }
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.error)
        #endif
    }

    static func playSelection() {
        #if os(watchOS)
        WKInterfaceDevice.current().play(.click)
        #elseif canImport(UIKit)
        guard !isAppExtension else { return }
        let generator = UISelectionFeedbackGenerator()
        generator.prepare()
        generator.selectionChanged()
        #endif
    }
}
