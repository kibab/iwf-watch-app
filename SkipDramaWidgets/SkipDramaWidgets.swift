import AppIntents
import SwiftUI
import WidgetKit

struct SkipDramaLockScreenEntry: TimelineEntry, Sendable {
    let date: Date
}

struct SkipDramaLockScreenProvider: TimelineProvider {
    func placeholder(in context: Context) -> SkipDramaLockScreenEntry {
        SkipDramaLockScreenEntry(date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (SkipDramaLockScreenEntry) -> Void) {
        completion(SkipDramaLockScreenEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SkipDramaLockScreenEntry>) -> Void) {
        let entry = SkipDramaLockScreenEntry(date: .now)
        completion(Timeline(entries: [entry], policy: .never))
    }
}

struct SkipDramaLockScreenWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SkipDramaLockScreenEntry

    var body: some View {
        Group {
            switch family {
            case .accessoryRectangular:
                HStack(spacing: 10) {
                    Image(systemName: "mic.circle.fill")
                        .font(.title2)
                        .widgetAccentable()

                    VStack(alignment: .leading, spacing: 2) {
                        Text("SkipDrama")
                            .font(.headline)
                            .lineLimit(1)
                        Text("Tap for Voice Capture")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            default:
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: "mic.fill")
                        .font(.title3.weight(.semibold))
                        .widgetAccentable()
                }
            }
        }
        .widgetURL(Config.deepLinkCaptureVoiceURL)
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct SkipDramaLockScreenWidget: Widget {
    let kind = "app.skipdrama.widget.lockscreen"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SkipDramaLockScreenProvider()) { entry in
            SkipDramaLockScreenWidgetView(entry: entry)
        }
        .configurationDisplayName("SkipDrama Voice")
        .description("Launch directly into voice recording.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular])
    }
}

struct VoiceCaptureControl: ControlWidget {
    let kind = "app.skipdrama.control.voice"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: kind) {
            ControlWidgetButton(action: StartVoiceCaptureIntent()) {
                Label("Voice Capture", systemImage: "mic.fill")
            }
        }
        .displayName("Voice Capture")
        .description("Start recording a voice memo in SkipDrama.")
    }
}

struct TextCaptureControl: ControlWidget {
    let kind = "app.skipdrama.control.text"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: kind) {
            ControlWidgetButton(action: OpenTextCaptureIntent()) {
                Label("Text Capture", systemImage: "square.and.pencil")
            }
        }
        .displayName("Text Capture")
        .description("Open SkipDrama with the text field focused.")
    }
}

@main
struct SkipDramaWidgetsBundle: WidgetBundle {
    var body: some Widget {
        SkipDramaLockScreenWidget()
        VoiceCaptureControl()
        TextCaptureControl()
    }
}
