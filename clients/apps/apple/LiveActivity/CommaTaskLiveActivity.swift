import ActivityKit
import CommaCore
import SwiftUI
import WidgetKit

@main
struct CommaActivityWidgets: WidgetBundle {
    var body: some Widget {
        CommaTaskLiveActivity()
        CommaCallLiveActivity()
    }
}

struct CommaTaskLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TaskActivityAttributes.self) { context in
            TaskActivityCard(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                // The top corners are the Island's tightest curves; inset both header items from them.
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        CommaMark(size: 16)
                        Text("Comma").font(.subheadline.weight(.semibold))
                    }
                    .padding(.leading, 8)
                    .padding(.top, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Group {
                        if context.isStale { TaskActivityStaleLabel() }
                        else { TaskActivityCount(count: context.state.tasks.count, short: false) }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 8)
                    .padding(.top, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    TaskActivityRows(context: context)
                        // A gap below the header, and clear of the rounded bottom corners.
                        .padding(.top, 10)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 6)
                }
            } compactLeading: {
                CommaMark(size: 16)
            } compactTrailing: {
                if context.isStale { Image(systemName: "clock") }
                else {
                    TaskActivityCount(count: context.state.tasks.count, short: true)
                        .foregroundStyle(context.state.needsAttention ? CommaTheme.attention : .white)
                }
            } minimal: {
                CommaMark(size: 16)
            }
            .widgetURL(context.state.tasks.first.flatMap { context.attributes.taskURL(id: $0.id) })
            .keylineTint(context.state.needsAttention ? CommaTheme.attention : .white)
        }
        .supplementalActivityFamilies([.small])
    }
}

private struct TaskActivityCount: View {
    let count: Int
    let short: Bool
    var body: some View {
        Text(short ? "\(count)" : count == 1 ? "1 task" : "\(count) tasks")
            .monospacedDigit()
            .contentTransition(.numericText(value: Double(count)))
    }
}

private struct TaskActivityStaleLabel: View {
    var body: some View {
        Label("Last known state", systemImage: "clock").labelStyle(.iconOnly)
    }
}

/// The app's Task board glyph. Live Activities run no loops, so in-progress holds still here.
private struct TaskActivityStatusIcon: View {
    let bucket: TaskBucket
    let size: CGFloat
    var body: some View {
        Image(bucket.iconName).renderingMode(.template).resizable().interpolation(.high)
            .foregroundStyle(bucket.tint)
            .frame(width: size, height: size)
            .id(bucket)
            .transition(.scale(scale: 0.6).combined(with: .opacity))
            .accessibilityHidden(true)
    }
}

private struct TaskActivityRows: View {
    let context: ActivityViewContext<TaskActivityAttributes>
    var body: some View {
        let tasks = Array(context.state.tasks.prefix(2))
        VStack(alignment: .leading, spacing: 10) {
            ForEach(tasks) { task in
                if let url = context.attributes.taskURL(id: task.id) {
                    // One Task may wrap to two lines; two Tasks keep one line each to stay inside the
                    // Activity's height limit.
                    Link(destination: url) { row(task, titleLines: tasks.count > 1 ? 1 : 2) }
                        .accessibilityLabel("\(task.title), \(task.presentation.label)")
                        .transition(.push(from: .bottom))
                }
            }
        }
        .animation(.smooth(duration: 0.6), value: context.state)
    }

    private func row(_ task: TaskActivityAttributes.TaskState, titleLines: Int) -> some View {
        let presentation = task.presentation
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            TaskActivityStatusIcon(bucket: presentation.bucket, size: 18)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(titleLines)
                // No elapsed timer: the Task's update time advances with every Message, not only on a status
                // change, so it cannot say how long the Task has been in its status.
                Text(presentation.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contentTransition(.interpolate)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The small family (Watch Smart Stack, CarPlay) features one Task under the brand line: the one waiting on
/// the reader, else the latest. A second Task shows as "+1" beside the brand.
private struct TaskActivitySmallCard: View {
    let context: ActivityViewContext<TaskActivityAttributes>
    var body: some View {
        let tasks = context.state.tasks.prefix(2)
        if let task = tasks.first(where: { $0.presentation.needsAttention }) ?? tasks.first {
            let presentation = task.presentation
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    CommaMark(size: 13)
                    Text("Comma")
                    Spacer(minLength: 4)
                    if context.isStale { Image(systemName: "clock") }
                    else if tasks.count > 1 {
                        Text(verbatim: "+\(tasks.count - 1)")
                            .contentTransition(.numericText(value: Double(tasks.count)))
                    }
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 8) {
                    TaskActivityStatusIcon(bucket: presentation.bucket, size: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(task.title)
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(2)
                            .minimumScaleFactor(0.85)
                        Text(presentation.label)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(presentation.needsAttention ? CommaTheme.attention : .secondary)
                            .lineLimit(1)
                            .contentTransition(.interpolate)
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .animation(.smooth(duration: 0.6), value: context.state)
            .widgetURL(context.attributes.taskURL(id: task.id))
            .accessibilityElement(children: .combine)
        }
    }
}

/// The system material is opaque. From iOS 26 the Lock Screen card is clear glass over the wallpaper instead;
/// earlier systems keep the system material.
private struct TaskActivityGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .background { Rectangle().fill(.clear).glassEffect(.regular, in: .rect) }
                .activityBackgroundTint(.clear)
        } else {
            content.activityBackgroundTint(nil)
        }
    }
}

private struct TaskActivityCard: View {
    @Environment(\.activityFamily) private var family
    let context: ActivityViewContext<TaskActivityAttributes>
    var body: some View {
        if family == .small { TaskActivitySmallCard(context: context) } else { card }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                CommaMark(size: 14)
                Text("Comma").fontWeight(.semibold)
                Spacer(minLength: 4)
                if context.isStale { Label("Last known state", systemImage: "clock").labelStyle(.iconOnly) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            TaskActivityRows(context: context)
        }
        .padding(16)
        .foregroundStyle(.primary)
        .modifier(TaskActivityGlass())
        .activitySystemActionForegroundColor(.primary)
    }
}

#if DEBUG
private let previewAttributes = TaskActivityAttributes(accountID: "preview", workspaceID: "preview", groupID: "preview")
private func previewState(_ tasks: [(String, String, String)]) -> TaskActivityAttributes.ContentState {
    let since = Int(Date().timeIntervalSince1970) - 95
    return .init(tasks: tasks.map { .init(id: $0.0, title: $0.1, status: $0.2, updatedAtEpochSeconds: since) },
                 updatedAtEpochSeconds: since)
}
private let previewStates = [
    previewState([("a", "Refactor the billing webhook", "queued")]),
    previewState([("a", "Refactor the billing webhook", "running")]),
    previewState([("a", "Refactor the billing webhook", "running"), ("b", "Write release notes", "queued")]),
    previewState([("a", "Refactor the billing webhook", "ready_for_review"), ("b", "Write release notes", "running")]),
    previewState([("b", "Write release notes", "completed")]),
]

#Preview("Lock Screen", as: .content, using: previewAttributes) { CommaTaskLiveActivity() }
contentStates: {
    previewStates[0]; previewStates[1]; previewStates[2]; previewStates[3]; previewStates[4]
}
#Preview("Expanded", as: .dynamicIsland(.expanded), using: previewAttributes) { CommaTaskLiveActivity() }
contentStates: {
    previewStates[0]; previewStates[1]; previewStates[2]; previewStates[3]; previewStates[4]
}
#Preview("Compact", as: .dynamicIsland(.compact), using: previewAttributes) { CommaTaskLiveActivity() }
contentStates: {
    previewStates[0]; previewStates[1]; previewStates[2]; previewStates[3]; previewStates[4]
}
#endif
