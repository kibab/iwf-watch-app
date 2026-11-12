import SwiftUI
import WidgetKit

struct CaptureEntry: TimelineEntry {
    let date: Date
}

struct CaptureTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> CaptureEntry {
        CaptureEntry(date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (CaptureEntry) -> Void) {
        completion(CaptureEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CaptureEntry>) -> Void) {
        let entry = CaptureEntry(date: .now)
        completion(Timeline(entries: [entry], policy: .never))
    }
}

struct CaptureComplicationView: View {
    @Environment(\.widgetFamily) private var family
    let entry: CaptureEntry

    private static let recordDeepLinkURL = URL(string: "quickcapture://record")!

    var body: some View {
        Group {
            switch family {
            case .accessoryCorner:
                Image(systemName: "mic.fill")
                    .font(.title3.weight(.semibold))
                    .widgetAccentable()
                    .widgetLabel {
                        Text("Capture")
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
        .widgetURL(Self.recordDeepLinkURL)
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

@main
struct CaptureWidget: Widget {
    let kind = "CaptureWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CaptureTimelineProvider()) { entry in
            CaptureComplicationView(entry: entry)
        }
        .configurationDisplayName("Quick Capture")
        .description("Launch directly into voice recording.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner])
    }
}

#Preview("Circular", as: .accessoryCircular) {
    CaptureWidget()
} timeline: {
    CaptureEntry(date: .now)
}

#Preview("Corner", as: .accessoryCorner) {
    CaptureWidget()
} timeline: {
    CaptureEntry(date: .now)
}

