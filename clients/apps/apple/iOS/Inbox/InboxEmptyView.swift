import SwiftUI
import CommaCore

/// The Inbox without rows, as the app's empty state: nothing has arrived yet, with a way to turn on
/// notifications; everything is handled; or the filters hide rows, with a way to clear them. Caught up because
/// Unread only hides the read rows, Clear Filters is the way back to them.
struct InboxEmptyView: View {
    let state: InboxEmptyState
    let hidesRead: Bool
    let notifications: TaskNotificationController?
    let clearFilters: () -> Void

    var body: some View {
        EmptyState(title, icon: state.isFiltered ? "icon-filter" : "icon-inbox", description: description) {
            switch state {
            case .nothingYet:
                if let notifications, !notifications.intent, notifications.canToggle {
                    Button("Turn on notifications") { notifications.intent = true }
                        .accessibilityIdentifier("inboxTurnOnNotifications")
                }
            case .caughtUp:
                if hidesRead { clearButton }
            case .filtered: clearButton
            }
        }
        .accessibilityIdentifier("inboxEmpty")
    }

    private var clearButton: some View {
        Button("Clear Filters", action: clearFilters).accessibilityIdentifier("inboxClearFilters")
    }

    private var title: Text {
        switch state {
        case .nothingYet: Text("No notifications")
        case .caughtUp: Text("You’re all caught up")
        case .filtered(let hidden): Text("\(hidden) notifications hidden by filters")
        }
    }

    private var description: Text? {
        switch state {
        case .nothingYet: Text("When Comma finishes a task or needs your review, it shows up here.")
        case .caughtUp where hidesRead: Text("Read notifications are hidden by Unread only.")
        case .caughtUp: Text("Cleared notifications come back when their tasks update.")
        case .filtered: nil
        }
    }
}

private extension InboxEmptyState {
    var isFiltered: Bool { if case .filtered = self { true } else { false } }
}
