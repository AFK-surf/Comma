import SwiftUI
import UIKit
import CommaCore

#if !GESTURE_FIXTURE
@main
#endif
struct CommaApp: App {
    @UIApplicationDelegateAdaptor(PhoneAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var pendingURL: URL?
    @State private var pendingURLAccountID: String?
    private var store: CommaStore? { appDelegate.store }
    private var activity: TaskActivityCoordinator { appDelegate.activity }

    var body: some Scene {
        WindowGroup {
            Group {
                if let store {
                    if !store.initialized {
                        LaunchLoading()
                    } else if store.session != nil {
                        // Comma opens on the chat. The shell keeps where the member is from then on, so coming back
                        // from the background finds the same page; only a fresh launch or sign-in starts here again.
                        AppShellView(store: store, activity: activity, navigation: AppNavigation(routerOpen: true))
                            .environment(appDelegate.call)
                            .transition(.opacity)
                    } else {
                        PhoneLoginView(store: store).transition(.opacity)
                    }
                } else if let configurationError = appDelegate.configurationError {
                    EmptyState(Text("Unable to start"), icon: "central-exclamation-triangle",
                               description: Text(configurationError))
                } else {
                    LaunchLoading()
                }
            }
            // Signing in or out cross-fades between the login and the app instead of cutting.
            .animation(CommaMotion.stageExit, value: store?.session == nil)
            .task {
                await appDelegate.bootstrap()
                if scenePhase == .active { await appDelegate.startForeground() }
                await consumeLink()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    Task {
                        await appDelegate.startForeground()
                        await consumeLink()
                    }
                }
                else { appDelegate.background() }
            }
            .onChange(of: store?.boundaryToken) { _, _ in
                if store?.session != nil { pendingURL = nil; pendingURLAccountID = nil }
            }
            .onChange(of: store?.session?.id) { _, _ in
                if store?.session == nil || (pendingURLAccountID != nil && pendingURLAccountID != store?.session?.user.id) {
                    pendingURL = nil; pendingURLAccountID = nil
                }
            }
            .onChange(of: store?.workspace?.id) { _, _ in Task { await consumeLink() } }
            .onOpenURL { url in
                pendingURL = url
                pendingURLAccountID = store?.session?.user.id
                Task { await consumeLink() }
            }
        }
    }

    static func projection(_ tasks: [TaskActivityTask], workspace: Workspace) -> TaskActivityProjection {
        TaskActivityProjection(workspaceID: workspace.id, groupID: workspace.groupID, tasks: tasks.map {
            .init(id: $0.id, title: String($0.title.prefix(160)), status: $0.status,
                  updatedAtEpochSeconds: Int($0.updatedAt.map { Date(wireTimestamp: $0).timeIntervalSince1970 } ?? 0))
        })
    }

    private func consumeLink() async {
        guard scenePhase == .active, UIApplication.shared.applicationState == .active,
              let pendingURL, let store, store.session != nil, !store.workspaces.isEmpty else { return }
        self.pendingURL = nil
        pendingURLAccountID = nil
        await open(pendingURL, store: store)
    }

    private func open(_ url: URL, store: CommaStore) async {
        guard UIApplication.shared.applicationState == .active,
              let session = store.session, ["comma", "comma-ios-dev"].contains(url.scheme), url.host == "task",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let taskID = components.queryItems?.first(where: { $0.name == "task" })?.value,
              let workspaceID = components.queryItems?.first(where: { $0.name == "workspace" })?.value,
              let workspace = store.workspaces.first(where: { $0.id == workspaceID }) else { return }
        let boundary = store.boundaryToken
        if store.workspace?.id != workspace.id { await store.chooseWorkspace(workspace) }
        guard UIApplication.shared.applicationState == .active else { store.suspend(); return }
        guard store.isCurrent(boundary), store.session?.id == session.id,
              store.session?.user.id == session.user.id, store.workspace?.id == workspace.id else { return }
        await store.openTask(id: taskID)
        guard UIApplication.shared.applicationState == .active else { store.suspend(); return }
        guard store.isCurrent(boundary), store.session?.id == session.id else { return }
    }
}

/// While Comma opens: the thinking comma alone, in grey, centred on the app's surface.
private struct LaunchLoading: View {
    var body: some View {
        CommaLogoAnimation(ink: CommaTheme.textPlaceholder)
            .frame(width: 44, height: 44)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(CommaTheme.bgPrimary.ignoresSafeArea())
            .accessibilityElement()
            .accessibilityLabel(Text("Loading…"))
    }
}
