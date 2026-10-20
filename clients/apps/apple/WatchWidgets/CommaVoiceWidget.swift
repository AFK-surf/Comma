import SwiftUI
import WidgetKit

private struct VoiceEntry: TimelineEntry { let date: Date }
private struct VoiceProvider: TimelineProvider {
    func placeholder(in context: Context) -> VoiceEntry { VoiceEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (VoiceEntry) -> Void) {
        completion(VoiceEntry(date: .now))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<VoiceEntry>) -> Void) {
        completion(Timeline(entries: [VoiceEntry(date: .now)], policy: .never))
    }
}

@main
struct CommaVoiceWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "CommaVoiceCall", provider: VoiceProvider()) { _ in
            VoiceWidgetView()
                .widgetURL(URL(string: "comma://call"))
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Comma")
        .description("Start a voice call with Comma.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryRectangular, .accessoryInline])
    }
}

private struct VoiceWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var body: some View {
        if family == .accessoryInline {
            Text("Comma · Voice call")
        } else if family == .accessoryRectangular {
            HStack {
                CommaMark(size: 24)
                VStack(alignment: .leading) {
                    Text("Comma").font(.headline)
                    Text("Voice call").font(.caption)
                }
            }
        } else {
            CommaMark(size: 24).accessibilityLabel("Comma Voice call")
        }
    }
}
