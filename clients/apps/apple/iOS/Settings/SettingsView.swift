import SwiftUI
import UIKit
import CommaCore

/// The Settings tab (the avatar): the account, workspace, notifications and labels, devices, the app itself
/// and sign-out. Tapping the tab again pops to this page, and then scrolls it to the top.
struct SettingsView: View {
    let store: CommaStore
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.openURL) private var openURL
    @State private var path: [Route] = []
    @State private var confirmingSignOut = false

    private enum Route: Hashable { case profile, workspace, notifications, labels, devices, myDevices }
    private static let top = "settings-top"

    var body: some View {
        NavigationStack(path: $path) {
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
                    devices
                    general
                    signOut
                }
                .pageTitle("Settings")
                .navigationDestination(for: Route.self, destination: destination)
                .onChange(of: navigation.reselect[.settings]) { _, _ in
                    if !path.isEmpty { path = []; return }
                    withAnimation(CommaMotion.spatialMove) { scroller.scrollTo(Self.top, anchor: .top) }
                }
            }
            .task(whileShowing: .settings) { await store.loadProfile() }
        }
        // The app badge depends on whether message notifications are on.
        .onChange(of: store.taskNotifications?.intent) { _, _ in store.router.onVisibilityChanged?() }
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
            if store.workspace != nil {
                link(.labels, id: "openTaskLabels") {
                    SettingsRow(Text("Task labels"), icon: "icon-tag") { SettingsChevron() }
                }
            }
        }
    }

    private var devices: some View {
        SettingsSection(Text("Devices"), footer: Text("Open Comma on your Apple Watch and it connects to this iPhone by itself. After connecting, the watch can load tasks and send messages directly.")) {
            link(.myDevices, id: "openMyDevices") {
                SettingsRow(Text("My devices"), icon: "central-circle-dashed") { SettingsChevron() }
            }
            link(.devices, id: "openSignedInDevices") {
                SettingsRow(Text("Signed-in devices"), icon: "icon-devices") { SettingsChevron() }
            }
        }
    }

    private var general: some View {
        SettingsSection(Text("General")) {
            // iOS keeps the per-app language in the Settings app, on Comma's own page.
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
            SettingsRow(Text("Version"), icon: "icon-info", value: Self.version.isEmpty ? nil : Text(Self.version))
                .textSelection(.enabled)
        }
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

    private func link<Label: View>(_ route: Route, id: String, @ViewBuilder label: () -> Label) -> some View {
        NavigationLink(value: route, label: label)
            .buttonStyle(SurfaceRowButtonStyle())
            .accessibilityIdentifier(id)
    }

    @ViewBuilder private func destination(_ route: Route) -> some View {
        switch route {
        case .profile: ProfileView(store: store)
        case .workspace: WorkspacePickerView(store: store)
        case .notifications: NotificationSettingsView(store: store)
        case .labels: TaskLabelsView(store: store)
        case .devices: SessionsView(store: store)
        case .myDevices: CommaDevicesView(store: store)
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
