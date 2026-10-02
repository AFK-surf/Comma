import ActivityKit
import SwiftUI
import WidgetKit

@main
struct CommaActivityWidgets: WidgetBundle {
    var body: some Widget { CommaTaskLiveActivity() }
}

struct CommaTaskLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TaskActivityAttributes.self) { context in
            TaskActivityCard(context: context)
                .activityBackgroundTint(.black)
                .activitySystemActionForegroundColor(.white)
                .widgetURL(context.attributes.taskURL)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.presentation.symbol)
                        .foregroundStyle(context.state.presentation.needsAttention ? .orange : .white)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.isStale ? "Last known state" : context.state.presentation.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(context.state.title).font(.headline).lineLimit(2)
                        Text(context.state.presentation.needsAttention ? "Open Comma to respond" : "Open task")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: context.state.presentation.symbol)
                    .foregroundStyle(context.state.presentation.needsAttention ? .orange : .white)
            } compactTrailing: {
                Image(systemName: context.isStale ? "clock" : "arrow.up.right")
            } minimal: {
                Image(systemName: context.isStale ? "clock" : context.state.presentation.symbol)
            }
            .widgetURL(context.attributes.taskURL)
            .keylineTint(context.state.presentation.needsAttention ? .orange : .white)
        }
        .supplementalActivityFamilies([.small])
    }
}

private struct TaskActivityCard: View {
    @Environment(\.activityFamily) private var family
    let context: ActivityViewContext<TaskActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: family == .small ? 4 : 8) {
            HStack(spacing: 6) {
                Image(systemName: context.state.presentation.symbol)
                Text("Comma").fontWeight(.semibold)
                Spacer(minLength: 4)
                if context.isStale { Image(systemName: "clock") }
            }
            .font(.caption)
            .foregroundStyle(context.state.presentation.needsAttention ? Color.orange : Color.secondary)
            Text(context.state.title)
                .font(family == .small ? .subheadline : .headline)
                .lineLimit(family == .small ? 2 : 3)
            Text(context.isStale ? "Last known state · \(context.state.presentation.label)" : context.state.presentation.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(family == .small ? 10 : 16)
        .foregroundStyle(.white)
    }
}
