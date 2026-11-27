import ActivityKit
import CommaCore
import SwiftUI
import WidgetKit

struct CommaLiveStatusActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LiveStatusAttributes.self) { context in
            LiveStatusLockScreenContainer(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    LiveStatusExpandedLeadingView(state: context.state, isStale: context.isStale)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    LiveStatusExpandedTrailingView(state: context.state, isStale: context.isStale)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    LiveStatusExpandedBottomView(state: context.state, isStale: context.isStale)
                }
            } compactLeading: {
                LiveStatusCompactLeadingView(state: context.state)
            } compactTrailing: {
                LiveStatusCompactTrailingView(state: context.state, isStale: context.isStale)
            } minimal: {
                LiveStatusMinimalView(state: context.state)
            }
            .widgetURL(context.attributes.deepLinkURL)
            .keylineTint(LiveStatusVisualStyle(state: context.state).islandAccent)
        }
        .supplementalActivityFamilies([.small])
    }
}

private struct LiveStatusGlass: ViewModifier {
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

private struct LiveStatusLockScreenContainer: View {
    @Environment(\.activityFamily) private var family
    let context: ActivityViewContext<LiveStatusAttributes>

    var body: some View {
        Group {
            if family == .small {
                LiveStatusSmallCardView(state: context.state, isStale: context.isStale)
            } else {
                LiveStatusCardView(state: context.state, isStale: context.isStale)
                    .modifier(LiveStatusGlass())
                    .activitySystemActionForegroundColor(.primary)
            }
        }
        .widgetURL(context.attributes.deepLinkURL)
        .animation(.smooth(duration: 0.45), value: context.state)
    }
}

#if DEBUG
private let liveStatusPreviewAttributes = LiveStatusAttributes(
    accountID: "preview", workspaceID: "preview", groupID: "preview",
    liveKey: "didi:preview", conversationID: "conv-preview"
)

#Preview("Lock Screen", as: .content, using: liveStatusPreviewAttributes) { CommaLiveStatusActivity() }
contentStates: {
    LiveStatusAttributes.ContentState(
        category: "car", status: "active", accent: "green",
        title: "沪A·D8821 · 白色比亚迪汉",
        subtitle: "距您 1.2 km · 沿南京西路驶来",
        compactLabel: nil,
        etaEpochSeconds: Int(Date().timeIntervalSince1970) + 180,
        progress: 0.65, stepCurrent: 2, stepTotal: 4, stepLabel: "接驾中",
        detailLeft: "张师傅 · 4.9★", detailRight: "快车 · 约 ¥17",
        updatedAtEpochSeconds: Int(Date().timeIntervalSince1970)
    )
    LiveStatusAttributes.ContentState(
        category: "car", status: "attention", accent: "amber",
        title: "司机已到达上车点",
        subtitle: "请在静安嘉里中心南门上车",
        compactLabel: "已到达",
        progress: 1.0, stepCurrent: 3, stepTotal: 4, stepLabel: "已到达",
        detailLeft: "沪A·D8821 · 免费等候 02:45", detailRight: "尾号 4821",
        updatedAtEpochSeconds: Int(Date().timeIntervalSince1970)
    )
}
#endif
