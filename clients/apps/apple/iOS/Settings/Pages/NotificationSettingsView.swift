import SwiftUI
import CommaCore

/// How Comma reaches the member outside the app: message notifications and live task progress.
struct NotificationSettingsView: View {
    @Bindable var store: CommaStore
    @EnvironmentObject private var activity: TaskActivityCoordinator

    var body: some View {
        SettingsPage {
            if let notifications = store.taskNotifications {
                TaskAlertsSettingsSection(notifications: notifications, hasWorkspaces: !store.workspaces.isEmpty)
            }
            liveProgress
        }
        .pageTitle("Notifications")
    }

    private var liveProgress: some View {
        SettingsSection(Text("Live task progress")) {
            SettingsToggle(title: Text("Automatically follow active tasks"), isOn: $store.automaticallyFollowTasks)
            if !activity.followedTaskIDs.isEmpty {
                Button { Task { await activity.stopFollowingCurrent() } } label: {
                    SettingsRow(Text("Stop showing current tasks"), role: .action)
                }
                .buttonStyle(SurfaceRowButtonStyle())
            }
            if let message = activity.availabilityMessage {
                SettingsNote(icon: "central-exclamation-triangle") { Text(message) }
                    .foregroundStyle(CommaTheme.textTertiary)
                Button {
                    Task { await store.refreshTaskActivity(); await activity.retry() }
                } label: {
                    SettingsRow(Text("Retry"), role: .action)
                }
                .buttonStyle(SurfaceRowButtonStyle())
            }
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Shows up to two current tasks from any source. Turning off automatic following removes live task progress.")
                if !activity.followedTaskIDs.isEmpty {
                    Text("Live task progress may show task titles on the Lock Screen. To stop showing it, tap “Stop showing current tasks”.")
                } else {
                    Text("Live task progress may show task titles on the Lock Screen.")
                }
            }
        }
    }
}

extension TaskNotificationController {
    /// Notifications the member turned on can't reach this device, so Settings has something to fix.
    var needsAttention: Bool { intent && (hasFailure || status == .denied) }
}
