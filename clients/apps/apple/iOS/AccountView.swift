import SwiftUI
import UIKit
import CommaCore

/// Settings: profile, workspace and labels, task updates, Apple Watch, signed-in devices and sign-out.
struct AccountView: View {
    @Bindable var store: CommaStore
    @ObservedObject var activity: TaskActivityCoordinator
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        ProfileView(store: store)
                    } label: {
                        HStack(spacing: 14) {
                            UserAvatar(store: store, size: 56)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(displayName).font(.system(size: 18, weight: .semibold))
                                if displayName != email {
                                    Text(email).font(.system(size: 14)).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .accessibilityIdentifier("openProfile")
                }
                if store.workspaces.count > 1 {
                    Section("Workspace") {
                        Picker("Workspace", selection: Binding(get: { store.workspace?.id ?? "" }, set: { id in
                            if let workspace = store.workspaces.first(where: { $0.id == id }) {
                                Task { await store.chooseWorkspace(workspace) }
                            }
                        })) { ForEach(store.workspaces) { Text($0.name).tag($0.id) } }
                    }
                } else if let workspace = store.workspace {
                    Section("Workspace") { Text(workspace.name) }
                }
                if store.workspace != nil {
                    Section {
                        NavigationLink {
                            TaskLabelsView(store: store)
                        } label: {
                            Label("Task labels", systemImage: "tag")
                        }
                    }
                }
                if let notifications = store.taskNotifications {
                    TaskAlertsSettingsSection(notifications: notifications, hasWorkspaces: !store.workspaces.isEmpty)
                }
                Section {
                    Toggle("Automatically follow tasks started on iPhone", isOn: $store.automaticallyFollowPhoneTasks)
                    if activity.followedTaskID != nil {
                        Button("Stop showing the current task") { Task { await activity.stopFollowingCurrent() } }
                    }
                    if let message = activity.availabilityMessage {
                        Text(message).font(.subheadline).foregroundStyle(CommaTheme.textTertiary)
                    }
                } header: {
                    Text("Live task progress")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Turning off automatic following won’t remove the live task progress currently shown.")
                        if activity.followedTaskID != nil {
                            Text("Live task progress may show task titles on the Lock Screen. To stop showing it, tap “Stop showing the current task”.")
                        } else {
                            Text("Live task progress may show task titles on the Lock Screen.")
                        }
                    }.foregroundStyle(CommaTheme.textTertiary).fixedSize(horizontal: false, vertical: true)
                }
                Section("Apple Watch") {
                    Text("Open Comma on your Apple Watch and choose Connect with iPhone. After connecting, the watch can load tasks and send messages directly.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Section {
                    NavigationLink {
                        SessionsView(store: store)
                    } label: {
                        Label("Signed-in devices", systemImage: "laptopcomputer.and.iphone")
                    }
                }
                Section {
                    Button("Sign out", role: .destructive) {
                        Task {
                            await store.logout()
                            if store.session == nil { dismiss() }
                        }
                    }.disabled(store.loading)
                }
            }
            .tint(CommaTheme.brandSolid)
            .scrollContentBackground(.hidden)
            .background(CommaTheme.bgWindow)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await store.loadProfile() }
        }
    }
    private var email: String { store.profile?.email ?? store.session?.user.email ?? "" }
    private var displayName: String {
        let name = store.profile?.name ?? store.session?.user.name
        return name?.isEmpty == false ? name! : email
    }
}

/// The controller is injected; this view owns only the outcome of opening system Settings.
struct TaskAlertsSettingsSection: View {
    @Bindable var notifications: TaskNotificationController
    let hasWorkspaces: Bool
    @Environment(\.scenePhase) private var scenePhase
    @State private var settingsOpenFailed = false

    var body: some View {
        Section {
            if notifications.record != nil {
                Toggle("Task notifications", isOn: $notifications.intent)
                    .disabled(!notifications.canToggle)
                    .accessibilityIdentifier("taskAlertsToggle")
                    .accessibilityHint("Controls task notifications on this device. iOS Settings can still block notifications.")
            }
            // An unrecorded choice is unconfirmed, not a disabled OFF switch.
            // The following reconciliation/error row remains until DELETE acknowledges it.
            if notifications.busy {
                HStack(alignment: .top, spacing: 8) {
                    ProgressView().accessibilityHidden(true)
                    Text(statusText).fixedSize(horizontal: false, vertical: true)
                }
                .font(.subheadline).foregroundStyle(CommaTheme.textTertiary)
                .accessibilityIdentifier("taskAlertsStatus")
            } else if settingsOpenFailed || statusVisible {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: statusSymbol).accessibilityHidden(true)
                    Text(settingsOpenFailed ? LocalizedStringKey("Couldn’t open Settings. Open the Settings app, find Comma, and allow notifications.") : statusText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.subheadline)
                .foregroundStyle(settingsOpenFailed || notifications.hasFailure ? CommaTheme.errorPrimary : CommaTheme.textTertiary)
                .accessibilityIdentifier("taskAlertsStatus")
            }
            if !notifications.busy {
                if notifications.hasFailure {
                    Button("Retry") { settingsOpenFailed = false; notifications.retry() }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("taskAlertsRetry")
                        .accessibilityHint(statusText)
                } else if notifications.intent && notifications.workspace != nil {
                    Button("Open Settings") { Task { await openSettings() } }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("taskAlertsOpenSettings")
                }
            }
        } header: {
            Text("Task updates")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Get notified when a task needs your attention, completes, or can’t finish.")
                Text("Notifications cover the default task group in one workspace at a time. Other task groups and workspaces aren’t supported yet. Notifications change to the new workspace only after a successful switch. If switching fails, you may still receive notifications from the previous workspace.")
                Text("Task notifications won’t show task titles or content.")
            }
            .foregroundStyle(CommaTheme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .listRowBackground(CommaTheme.cardPrimary)
        .task { notifications.refresh(locale: PhoneAppDelegate.notificationLocale) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { settingsOpenFailed = false; notifications.refresh(locale: PhoneAppDelegate.notificationLocale) }
        }
    }

    private var statusVisible: Bool {
        notifications.hasFailure || [.denied, .quiet, .noWorkspace].contains(notifications.status) || notifications.workspace == nil
    }
    private var statusSymbol: String {
        if settingsOpenFailed || notifications.hasFailure { return "exclamationmark.circle" }
        return notifications.status == .denied ? "bell.slash" : "bell"
    }
    private var statusText: LocalizedStringKey {
        switch notifications.status {
        case .loading: "Task notifications"
        case .enabling: "Setting up task notifications…"
        case .disabling: "Turning off task notifications…"
        case .enableFailed: "Task notifications couldn’t be enabled. Please try again."
        case .scopeFailed: "Couldn’t confirm that task notifications switched to the new workspace. You may still receive notifications from the previous workspace. Please try again."
        case .disableFailed, .legacyFailed: "Couldn’t confirm that task notifications are off. Please try again."
        case .denied: "Notifications are turned off in iOS Settings. Allow notifications for Comma in Settings."
        case .quiet: "Notifications are set to deliver quietly. You can change how they alert you in Settings."
        case .noWorkspace, .off, .active:
            hasWorkspaces ? "Select a workspace before enabling task notifications." : "No workspace is available, so task notifications can’t be enabled."
        }
    }
    private func openSettings() async {
        settingsOpenFailed = false
        if let url = URL(string: UIApplication.openNotificationSettingsURLString), await UIApplication.shared.open(url) { return }
        if let url = URL(string: UIApplication.openSettingsURLString), await UIApplication.shared.open(url) { return }
        settingsOpenFailed = true
    }
}
