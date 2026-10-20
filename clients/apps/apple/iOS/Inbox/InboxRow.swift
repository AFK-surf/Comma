import SwiftUI
import CommaCore

/// An Inbox row: the Task row every list shows, with its unread dot, then whether it is stale and how long
/// ago the Task changed. The press surface appears on touch-down; the action runs on touch-up.
struct InboxRow: View {
    let task: TaskSummary
    let unread: Bool
    let pinned: Bool
    let action: () -> Void

    var body: some View {
        let date = InboxProjection.date(of: task)
        Button(action: action) {
            TaskRowLabel(task: task, pinned: pinned, unread: unread) { tail(date: date) }
        }
        .buttonStyle(TaskRowButtonStyle())
        .accessibilityLabel(unread ? Text("Unread") + Text(verbatim: ", " + task.title) : Text(verbatim: task.title))
        .accessibilityValue(Text(verbatim: details(date: date)))
        .accessibilityIdentifier("inbox-" + task.id)
    }

    /// Stale and the compact age, after the row's pin, in the desktop's order.
    @ViewBuilder private func tail(date: Date) -> some View {
        if isStale {
            Text("Stale").font(.footnote.weight(.medium)).foregroundStyle(CommaTheme.attention)
        }
        TimelineView(.everyMinute) { context in
            Text(Self.age(of: date, now: context.date))
                .font(.footnote.monospacedDigit()).foregroundStyle(CommaTheme.textTertiary)
        }
    }

    private var isStale: Bool { task.freshness == "stale" }

    /// What VoiceOver reads after the title: the status, the Loop's kind on a Loop Task, whether it is pinned or
    /// stale, where it was asked for and when it changed.
    private func details(date: Date) -> String {
        [String(localized: task.bucket.label),
         task.loop?.kind.label,
         pinned ? String(localized: "Pinned") : nil,
         isStale ? String(localized: "Stale") : nil,
         task.origin.flatMap(TaskOrigin.init(rawValue:))?.label,
         date.formatted(.relative(presentation: .named))]
            .compactMap { $0 }.joined(separator: ", ")
    }

    /// The desktop's compact age: "now" under a minute, then whole minutes, hours and days, each rounded.
    static func age(of date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return String(localized: "now") }
        let minutes = (seconds / 60).rounded()
        if minutes < 60 { return Duration.seconds(minutes * 60).formatted(.units(allowed: [.minutes], width: .narrow)) }
        let hours = (minutes / 60).rounded()
        if hours < 24 { return Duration.seconds(hours * 3600).formatted(.units(allowed: [.hours], width: .narrow)) }
        return Duration.seconds((hours / 24).rounded() * 86_400).formatted(.units(allowed: [.days], width: .narrow))
    }
}
