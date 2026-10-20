import SwiftUI
import UIKit
import CommaCore

/// The controller is injected; this view owns only the outcome of opening system Settings.
struct TaskAlertsSettingsSection: View {
    @Bindable var notifications: TaskNotificationController
    let hasWorkspaces: Bool
    @Environment(\.scenePhase) private var scenePhase
    @State private var settingsOpenFailed = false

    var body: some View {
        SettingsSection {
            if notifications.record != nil {
                SettingsToggle(title: Text("Message notifications"), icon: "icon-bell", isOn: $notifications.intent)
                    .disabled(!notifications.canToggle)
                    .accessibilityIdentifier("taskAlertsToggle")
                    .accessibilityHint("Controls message notifications on this device. iOS Settings can still block notifications.")
            }
            // An unrecorded choice is unconfirmed, not a disabled OFF switch.
            // The following reconciliation/error row remains until DELETE acknowledges it.
            if notifications.busy {
                SettingsNote { ProgressView().controlSize(.small) } message: { Text(statusText) }
                    .foregroundStyle(CommaTheme.textTertiary)
                    .accessibilityIdentifier("taskAlertsStatus")
            } else if settingsOpenFailed || statusVisible {
                SettingsNote(icon: statusIcon) {
                    Text(settingsOpenFailed ? LocalizedStringKey("Couldn’t open Settings. Open the Settings app, find Comma, and allow notifications.") : statusText)
                    if !settingsOpenFailed, notifications.hasFailure, notifications.status != .enableFailed,
                       let message = notifications.failureMessage {
                        Text(LocalizedStringKey(message))
                    }
                }
                .foregroundStyle(settingsOpenFailed || notifications.hasFailure ? CommaTheme.errorPrimary : CommaTheme.textTertiary)
                .accessibilityIdentifier("taskAlertsStatus")
            }
            if !notifications.busy {
                if notifications.hasFailure {
                    action("Retry") { settingsOpenFailed = false; notifications.retry() }
                        .accessibilityIdentifier("taskAlertsRetry")
                        .accessibilityHint(statusText)
                } else if notifications.intent && notifications.workspace != nil {
                    action("Open Settings") { Task { await openSettings() } }
                        .accessibilityIdentifier("taskAlertsOpenSettings")
                }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Get notified about Router replies and tasks that need your attention, complete, or can’t finish.")
                Text("Notifications cover Router replies and task updates in the default group of the selected workspace. Notifications change to the new workspace only after a successful switch. If switching fails, you may still receive notifications from the previous workspace.")
                Text("Task alerts won’t show task titles or content. Router replies appear as message alerts.")
            }
        }
        .task { notifications.refresh(locale: PhoneAppDelegate.notificationLocale) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { settingsOpenFailed = false; notifications.refresh(locale: PhoneAppDelegate.notificationLocale) }
        }
    }

    private func action(_ title: LocalizedStringKey, perform: @escaping () -> Void) -> some View {
        Button(action: perform) { SettingsRow(Text(title), role: .action) }
            .buttonStyle(SurfaceRowButtonStyle())
    }

    private var statusVisible: Bool {
        notifications.hasFailure || [.denied, .quiet, .noWorkspace].contains(notifications.status) || notifications.workspace == nil
    }
    private var statusIcon: String {
        if settingsOpenFailed || notifications.hasFailure { return "central-exclamation-triangle" }
        return notifications.status == .denied ? "central-bell-off" : "icon-bell"
    }
    private var statusText: LocalizedStringKey {
        if notifications.status == .enableFailed, let message = notifications.failureMessage {
            return LocalizedStringKey(message)
        }
        return switch notifications.status {
        case .loading: "Message notifications"
        case .enabling: "Setting up message notifications…"
        case .disabling: "Turning off message notifications…"
        case .enableFailed: "Message notifications couldn’t be enabled. Please try again."
        case .scopeFailed: "Couldn’t confirm that message notifications switched to the new workspace. You may still receive notifications from the previous workspace. Please try again."
        case .disableFailed, .legacyFailed: "Couldn’t confirm that message notifications are off. Please try again."
        case .denied: "Notifications are turned off in iOS Settings. Allow notifications for Comma in Settings."
        case .quiet: "Notifications are set to deliver quietly. You can change how they alert you in Settings."
        case .noWorkspace, .off, .active:
            hasWorkspaces ? "Select a workspace before enabling message notifications." : "No workspace is available, so message notifications can’t be enabled."
        }
    }
    private func openSettings() async {
        settingsOpenFailed = false
        if let url = URL(string: UIApplication.openNotificationSettingsURLString), await UIApplication.shared.open(url) { return }
        if let url = URL(string: UIApplication.openSettingsURLString), await UIApplication.shared.open(url) { return }
        settingsOpenFailed = true
    }
}
