import SwiftUI
import UIKit
import CommaCore

enum SettingsRoute: Hashable { case profile, workspace, notifications, labels, devices, myDevices, deleteAccount, changeEmail, plugins, models, router, routines, usage, drive, requests, shares, voice, channels, routerKeys, compute }

extension EnvironmentValues {
    /// Nil for a single column; otherwise the shell's current hinge posture.
    @Entry var settingsColumnsFolded: Bool? = nil
}

/// Settings follows the desktop groups. Comma holds desktop navigation entries without a phone tab.
/// Selecting this tab again returns to the top of the list.
struct SettingsView: View {
    let store: CommaStore
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.openURL) private var openURL
    @Environment(\.settingsColumnsFolded) private var columnsFolded
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmingSignOut = false
    @State private var archivedOpen = false

    private static let top = "settings-top"

    var body: some View {
        @Bindable var navigation = navigation
        GeometryReader { geometry in
            let split = columnsFolded != nil && !navigation.settingsPath.isEmpty
            let columns = ShellColumnLayout(width: geometry.size.width, folded: columnsFolded ?? false,
                                            division: geometry.shellFoldDivision)
            ZStack(alignment: .leading) {
                // The native push owns detail entry, back navigation, and nested pages.
                NavigationStack(path: $navigation.settingsPath) {
                    Group {
                        if columnsFolded == nil { settingsList.pageTitle("Settings") }
                        else { GroupedSurface.page.navigationTitle("Settings") }
                    }
                    .navigationDestination(for: SettingsRoute.self) { route in
                        destination(route)
                            .background(SettingsPopGesturePolicy(blocked: columnsFolded != nil))
                    }
                }
                .padding(.leading, columnsFolded != nil ? columns.leadingWidth + columns.gap : 0)
                .accessibilityHidden(columnsFolded != nil && !split)
                .accessibilityIdentifier("settingsDetailColumn")
                if columnsFolded != nil {
                    NavigationStack {
                        settingsList.pageTitle("Settings")
                    }
                        .background(GroupedSurface.page)
                        .frame(width: split ? columns.leadingWidth : columns.trailingWidth)
                        .offset(x: split ? 0 : columns.leadingWidth + columns.gap)
                        .animation(reduceMotion ? nil : CommaMotion.release, value: split)
                        .accessibilityIdentifier("settingsMasterColumn")
                }
            }
        }
        .sheet(isPresented: $archivedOpen) {
            ArchivedTasksView(store: store) { task in Task { await store.openTask(id: task.id) } }
                .environment(\.inSheet, true)
        }
        .task(whileShowing: .settings) { await store.loadProfile() }
        .onChange(of: navigation.reselect[.settings]) { _, _ in navigation.settingsPath = [] }
        // The app badge depends on whether message notifications are on.
        .onChange(of: store.taskNotifications?.intent) { _, _ in store.router.onVisibilityChanged?() }
    }

    private var settingsList: some View {
        ScrollViewReader { scroller in
            SettingsPage {
                VStack(spacing: 24) {
                    issues
                    SettingsSection {
                        link(.profile, id: "openProfile") { SettingsAccountRow(store: store) }
                    }
                }
                .id(Self.top)
                workspace
                comma
                preferences
                work
                system
                archived
                shared
                advanced
                accounts
                signOut
                danger
            }
            .onChange(of: navigation.reselect[.settings]) { _, _ in
                withAnimation(CommaMotion.spatialMove) { scroller.scrollTo(Self.top, anchor: .top) }
            }
        }
    }

    /// A device that can't receive pushes, which the avatar's attention dot points to. Failures of Settings' own
    /// actions (switching workspace, signing out) are the app's toast.
    @ViewBuilder private var issues: some View {
        if let failure = store.pushRegistrationError {
            InlineError(message: String(localized: "Notifications can’t reach this iPhone") + "\n" + failure,
                        retry: {
                            store.dismissPushRegistrationError()
                            UIApplication.shared.registerForRemoteNotifications()
                        })
        }
    }

    /// A page to choose from when there is a choice to make, the name alone otherwise.
    @ViewBuilder private var workspace: some View {
        let name = Text(store.workspace?.name ?? String(localized: "Choose a workspace"))
        SettingsSection {
            if store.workspaces.count > 1 {
                link(.workspace, id: "chooseWorkspace") {
                    SettingsRow(Text("Workspace"), icon: "central-buildings", value: name) { SettingsChevron() }
                }
            } else if store.workspace != nil {
                SettingsRow(Text("Workspace"), icon: "central-buildings", value: name)
            }
        }
    }

    private var comma: some View {
        SettingsSection(Text("Comma")) {
            if store.workspace != nil {
                link(.drive, id: "openDrive") {
                    SettingsRow(Text("Drive and System Files"), icon: "central-file-bend") { SettingsChevron() }
                }
                link(.plugins, id: "openPlugins") {
                    SettingsRow(Text("Plugins"), icon: "central-puzzle") { SettingsChevron() }
                }
            }
        }
    }

    private var preferences: some View {
        SettingsSection(Text("settings_group_preferences")) {
            if store.workspace != nil {
                link(.router, id: "openRouterSettings") {
                    SettingsRow(Text("Router settings"), icon: "central-sparkles-two") { SettingsChevron() }
                }
            }
            link(.notifications, id: "openNotificationSettings") {
                let attention = store.taskNotifications?.needsAttention == true
                SettingsRow(Text("Notifications"), icon: "icon-bell",
                            value: attention ? nil : store.taskNotifications.map { Text($0.intent ? "On" : "Off") }) {
                    if attention {
                        CentralIcon("central-exclamation-triangle", size: 20, relativeTo: .body)
                            .foregroundStyle(CommaTheme.errorPrimary)
                            // The glyph is decorative; VoiceOver reads what it means in its place.
                            .accessibilityRepresentation { Text("Needs attention") }
                    }
                    SettingsChevron()
                }
            }
            // iOS keeps the per-app language on Comma's page in the Settings app.
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            } label: {
                SettingsRow(Text("Language"), icon: "icon-globe", value: Text(Self.language)) {
                    CentralIcon("central-arrow-up-right", size: 16, relativeTo: .body)
                        .foregroundStyle(CommaTheme.textQuaternary)
                }
            }
            .buttonStyle(SurfaceRowButtonStyle())
            .accessibilityHint("Opens Comma in the Settings app")
            .accessibilityIdentifier("openLanguageSettings")
            if store.workspace != nil {
                link(.usage, id: "openUsage") {
                    SettingsRow(Text("Usage"), icon: "icon-info") { SettingsChevron() }
                }
            }
        }
    }

    private var work: some View {
        SettingsSection(Text("settings_group_work")) {
            if store.workspace != nil {
                link(.routines, id: "openRoutinesSettings") {
                    SettingsRow(Text("Routines"), icon: "central-sparkles-two") { SettingsChevron() }
                }
                link(.channels, id: "openChannels") {
                    SettingsRow(Text("Channels"), icon: "central-chain-link-4") { SettingsChevron() }
                }
                link(.labels, id: "openTaskLabels") {
                    SettingsRow(Text("Task labels"), icon: "icon-tag") { SettingsChevron() }
                }
                link(.models, id: "openModels") {
                    SettingsRow(Text("Models"), icon: "central-brain") { SettingsChevron() }
                }
            }
        }
    }

    private var system: some View {
        SettingsSection(Text("settings_group_system")) {
            if store.workspace != nil {
                link(.voice, id: "openVoiceSettings") {
                    SettingsRow(Text("Voice settings"), icon: "icon-info") { SettingsChevron() }
                }
            }
            SettingsRow(Text("Version"), icon: "icon-info", value: Self.version.isEmpty ? nil : Text(Self.version))
                .textSelection(.enabled)
        }
    }

    private var shared: some View {
        SettingsSection(Text("settings_group_shared")) {
            if store.workspace != nil {
                link(.shares, id: "openSharedTasks") {
                    SettingsRow(Text("Shared tasks"), icon: "central-chain-link-4") { SettingsChevron() }
                }
                link(.requests, id: "openTaskRequests") {
                    SettingsRow(Text("Task requests"), icon: "central-share-os") { SettingsChevron() }
                }
            }
        }
    }

    private var archived: some View {
        SettingsSection(Text("Archived")) {
            if store.workspace != nil {
                Button { archivedOpen = true } label: {
                    SettingsRow(Text("Archived tasks"), icon: "icon-archive") { SettingsChevron() }
                }
                .buttonStyle(SurfaceRowButtonStyle())
                .accessibilityIdentifier("openArchivedTasks")
            }
        }
    }

    private var advanced: some View {
        SettingsSection(Text("settings_group_advanced"), footer: Text("Open Comma on your Apple Watch and it connects to this iPhone by itself. After connecting, the watch can load tasks and send messages directly.")) {
            if store.workspace != nil {
                link(.routerKeys, id: "openRouterKeys") {
                    SettingsRow(Text("Router API keys"), icon: "icon-info") { SettingsChevron() }
                }
            }
            link(.myDevices, id: "openMyDevices") {
                SettingsRow(Text("My devices"), icon: "central-circle-dashed") { SettingsChevron() }
            }
            if store.workspace != nil {
                link(.compute, id: "openCompute") {
                    SettingsRow(Text("Compute resources"), icon: "icon-devices") { SettingsChevron() }
                }
            }
            link(.devices, id: "openSignedInDevices") {
                SettingsRow(Text("Signed-in devices"), icon: "icon-devices") { SettingsChevron() }
            }
        }
    }

    /// The other accounts signed in on this iPhone (switch to one, or sign it out), and adding another.
    private var accounts: some View {
        SettingsSection(Text("Other accounts")) {
            ForEach(store.otherAccounts) { account in
                Menu {
                    Button("Switch to this account") { run { await store.switchAccount(to: account.id) } }
                    Button("Sign out of this account", role: .destructive) { run { await store.signOutAccount(account.id) } }
                } label: {
                    SettingsRow(Text(verbatim: account.email), icon: "central-people-circle", value: Text("Switch")) { SettingsChevron() }
                }
                .buttonStyle(SurfaceRowButtonStyle())
                .disabled(store.loading)
                .accessibilityIdentifier("otherAccount")
            }
            Button { run { await store.addAccount() } } label: {
                SettingsRow(Text("Add account"), icon: "central-plus-small")
            }
            .buttonStyle(SurfaceRowButtonStyle())
            .disabled(store.loading)
            .accessibilityIdentifier("addAccount")
        }
    }

    /// An account action, its failure said as the app's other Settings failures are.
    private func run(_ action: @escaping () async -> SignInProblem?) {
        Task { if let problem = await action() { store.error = problem.message } }
    }

    private var signOut: some View {
        SettingsSection {
            Button { confirmingSignOut = true } label: {
                SettingsRow(Text("Sign out"), icon: "central-arrow-box-left", role: .destructive)
            }
            .buttonStyle(SurfaceRowButtonStyle())
            .disabled(store.loading)
            .accessibilityIdentifier("signOut")
            .confirmationDialog("Sign out of Comma?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) { Task { await store.logout() } }
            } message: {
                Text("Signing out a device also signs out the Apple Watch connected through it.")
            }
        }
    }

    /// Kept apart, last: what cannot be undone.
    private var danger: some View {
        SettingsSection(Text("Danger zone")) {
            link(.deleteAccount, id: "openAccountDeletion") {
                SettingsRow(Text("Delete account"), icon: "central-trash-can", role: .destructive) { SettingsChevron() }
            }
        }
    }

    private func link<Label: View>(_ route: SettingsRoute, id: String, @ViewBuilder label: () -> Label) -> some View {
        let selected = columnsFolded != nil && navigation.settingsPath.first == route
        return Button { navigation.settingsPath = [route] } label: {
            label().background(selected ? GroupedSurface.ink : .clear)
        }
            .buttonStyle(SurfaceRowButtonStyle())
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier(id)
    }

    @ViewBuilder private func destination(_ route: SettingsRoute) -> some View {
        switch route {
        case .profile: ProfileView(store: store)
        case .workspace: WorkspacePickerView(store: store)
        case .notifications: NotificationSettingsView(store: store)
        case .labels: TaskLabelsView(store: store)
        case .devices: SessionsView(store: store)
        case .myDevices: CommaDevicesView(store: store)
        case .deleteAccount: AccountDeletionView(store: store)
        case .changeEmail: EmailChangeView(store: store)
        case .routines:
            if let workspace = store.workspace {
                PhoneRoutinesSettingsView(model: PhoneRoutinesSettingsModel(store: store, workspace: workspace))
                    .id("routines-\(store.boundaryToken)-\(workspace.id)")
            }
        case .usage:
            if let workspace = store.workspace {
                PhoneUsageView(model: PhoneUsageModel(store: store, workspace: workspace))
                    .id("usage-\(store.boundaryToken)-\(workspace.id)")
            }
        case .drive:
            if let workspace = store.workspace {
                PhoneDriveView(model: PhoneDriveModel(store: store, workspace: workspace))
                    .id("drive-\(store.boundaryToken)-\(workspace.id)")
            }
        case .requests:
            if let workspace = store.workspace {
                PhoneTaskRequestsView(model: PhoneTaskRequestsModel(store: store, workspace: workspace))
                    .id("requests-\(store.boundaryToken)-\(workspace.id)")
            }
        case .shares:
            if let workspace = store.workspace {
                PhoneSharedTasksView(feed: WorkspaceTopic(store: store, workspace: workspace, topic: "taskShares", parameters: ["workspace": workspace.id], workspaceField: true))
                    .id("shares-\(store.boundaryToken)-\(workspace.id)")
            }
        case .voice:
            if let workspace = store.workspace {
                PhoneVoiceSettingsView(model: PhoneVoiceModel(store: store, workspace: workspace))
                    .id("voice-\(store.boundaryToken)-\(workspace.id)")
            }
        case .channels:
            if let workspace = store.workspace {
                PhoneChannelsView(store: store, workspace: workspace)
                    .id("channels-\(store.boundaryToken)-\(workspace.id)")
            }
        case .compute:
            if let workspace = store.workspace {
                PhoneComputeView(feed: WorkspaceTopic(store: store, workspace: workspace, topic: "compute", parameters: ["prefer": workspace.id], workspaceField: true))
                    .id("compute-\(store.boundaryToken)-\(workspace.id)")
            }
        case .routerKeys:
            if let workspace = store.workspace {
                PhoneAPIKeysView(model: PhoneAPIKeysModel(store: store, workspace: workspace, voice: false))
                    .id("routerKeys-\(store.boundaryToken)-\(workspace.id)")
            }
        case .plugins:
            if let workspace = store.workspace {
                PhonePluginsView(model: PhonePluginsModel(store: store, workspace: workspace))
                    .id("plugins-\(store.boundaryToken)-\(workspace.id)")
            }
        case .models:
            if let workspace = store.workspace {
                PhoneModelsView(model: PhoneModelsModel(store: store, workspace: workspace))
                    .id("models-\(store.boundaryToken)-\(workspace.id)")
            }
        case .router:
            if let workspace = store.workspace {
                PhoneRouterSettingsView(model: PhoneRouterSettingsModel(store: store, workspace: workspace))
                    .id("router-\(store.boundaryToken)-\(workspace.id)")
            }
        }
    }

    /// The app's version and build, as iOS shows them: "1.0 (5)".
    private static var version: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? ""
        guard let build = info?["CFBundleVersion"] as? String, !build.isEmpty else { return version }
        return "\(version) (\(build))"
    }

    /// The language Comma is showing, named in that language.
    private static var language: String {
        let code = Bundle.main.preferredLocalizations.first ?? "en"
        return Locale(identifier: code).localizedString(forIdentifier: code) ?? code
    }
}
