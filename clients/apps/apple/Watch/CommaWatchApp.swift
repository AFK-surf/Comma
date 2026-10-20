import SwiftUI
import CommaCore

@main
struct CommaWatchApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store: CommaStore?
    @State private var call: WatchCallController?
    @StateObject private var bridge = WatchPairingBridge()
    @State private var requestedTaskID: String?
    @State private var pendingURL: URL?
    @State private var observedWorkspaceID: String?
    /// Mirrors `scenePhase` for async work: `configure()` and the store callbacks run on the copy of this App
    /// captured at launch, whose Environment values never update, while State reads the current value.
    @State private var active = false
    @State private var error: String?

    var body: some Scene {
        WindowGroup {
            Group {
                if let store, store.initialized {
                    if store.session != nil { WatchHomeView(store: store, requestedTaskID: $requestedTaskID, call: call) }
                    else { WatchConnectView(store: store, bridge: bridge) }
                } else if let error {
                    Text(error).font(.footnote).foregroundStyle(CommaTheme.errorPrimary).padding()
                } else {
                    CommaMark(size: 32).foregroundStyle(.white).opacity(0.9)
                }
            }
            .sheet(isPresented: Binding(get: { call?.presented ?? false }, set: { call?.presented = $0 })) {
                if let call { WatchCallView(call: call) }
            }
            .task { await configure() }
            .onChange(of: scenePhase, initial: true) { _, phase in
                active = phase == .active
                guard let store else { return }
                if phase == .active {
                    Task {
                        await bridge.applyLatestContext()
                        await consumeLink()
                        await store.resume()
                        await consumeLink()
                    }
                } else if phase == .background { store.suspend() }
            }
            .onOpenURL { url in
                pendingURL = url
                if isCallLink(url) { call?.presentPendingCall() }
                Task { await consumeLink() }
            }

        }
    }

    private func isCallLink(_ url: URL?) -> Bool {
        url?.scheme == "comma" && url?.host == "call"
    }

    private func consumeLink() async {
        guard active, let store, store.session != nil, store.workspace != nil, let url = pendingURL else { return }
        if isCallLink(url) {
            pendingURL = nil
            await call?.startPendingCall()
            return
        }
        pendingURL = nil
        guard url.scheme == "comma", url.host == "task",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let id = components.queryItems?.first(where: { $0.name == "task" })?.value,
              let workspaceID = components.queryItems?.first(where: { $0.name == "workspace" })?.value,
              let workspace = store.workspaces.first(where: { $0.id == workspaceID }) else { return }
        if store.workspace?.id != workspace.id { await store.chooseWorkspace(workspace) }
        guard store.workspace?.id == workspace.id else { return }
        requestedTaskID = id
    }

    private func configure() async {
        guard store == nil else { return }
        do {
            let configuration = try AppConfiguration.current()
            let value = CommaStore(configuration: configuration, client: try configuration.makeClient())
            store = value
            let voice = WatchCallController(store: value)
            call = voice
            if isCallLink(pendingURL) { voice.presentPendingCall() }
            value.beforeLogout = { await voice.signOut() }
            value.onAuthBoundaryChanged = {
                if value.session != nil { voice.invalidate(); pendingURL = nil }
                observedWorkspaceID = nil
            }
            value.onSessionChanged = { session in
                if session == nil, !voice.waitingForContext { voice.sessionEnded() }
            }
            value.onWorkspaceChanged = { workspace in
                if let previous = observedWorkspaceID, previous != workspace.id { voice.invalidate() }
                observedWorkspaceID = workspace.id
                Task { await consumeLink() }
            }
            bridge.configure(store: value)
            await value.start()
            await bridge.applyLatestContext()
            await consumeLink()
            if voice.waitingForContext, value.session == nil || value.workspace == nil {
                pendingURL = nil
                voice.invalidate()
            }
        } catch { self.error = error.localizedDescription }
    }
}

struct WatchConnectView: View {
    @Bindable var store: CommaStore
    @ObservedObject var bridge: WatchPairingBridge

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                CommaMark(size: 36).foregroundStyle(.white)
                Text("Comma").font(.system(size: 20, weight: .semibold))
                if let message = bridge.error ?? store.error {
                    Text(message).font(.footnote).foregroundStyle(CommaTheme.errorPrimary)
                        .multilineTextAlignment(.center)
                    Button("Try Again") { Task { await bridge.pair() } }
                        .buttonStyle(.borderedProminent).tint(CommaTheme.brandSolid)
                        .disabled(bridge.pairing)
                } else if bridge.pairedBefore, !bridge.pairing {
                    // This watch was signed out on its own, perhaps revoked: connecting again is the reader's choice.
                    Text("Connect once with your iPhone to chat and follow tasks from your watch.")
                        .font(.system(size: 14)).foregroundStyle(CommaTheme.textTertiary)
                        .multilineTextAlignment(.center)
                    Button("Connect with iPhone") { Task { await bridge.pair() } }
                        .buttonStyle(.borderedProminent).tint(CommaTheme.brandSolid)
                } else {
                    // Signing in follows the iPhone; there is nothing to press while it connects.
                    ProgressView()
                    Text(bridge.pairing ? "Connecting to your iPhone…" : "Waiting for your iPhone…")
                        .font(.system(size: 14)).foregroundStyle(CommaTheme.textTertiary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 4)
        }
        .task { await bridge.pair(automatic: true) }
    }
}

struct WatchHomeView: View {
    @Bindable var store: CommaStore
    @Binding var requestedTaskID: String?
    var call: WatchCallController?
    @State private var path: [WatchRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                NavigationLink(value: WatchRoute.router) {
                    HStack(spacing: 8) {
                        CommaMark(size: 18).foregroundStyle(.white)
                        Text("Home").font(.system(size: 16, weight: .medium))
                    }
                }
                if let call {
                    Button { Task { await call.start() } } label: {
                        HStack(spacing: 8) {
                            CallSymbol("phone", size: 18)
                            Text("Voice call").font(.system(size: 16, weight: .medium))
                        }
                    }
                    .accessibilityIdentifier("startCall")
                }
                if store.workspaces.count > 1 {
                    Picker("Workspace", selection: Binding(get: { store.workspace?.id ?? "" }, set: { id in
                        if let workspace = store.workspaces.first(where: { $0.id == id }) {
                            Task { await store.chooseWorkspace(workspace) }
                        }
                    })) { ForEach(store.workspaces) { Text($0.name).tag($0.id) } }
                }
                Section {
                    ForEach(store.tasks) { task in
                        NavigationLink(value: WatchRoute.task(task.id)) { TaskRow(task: task) }
                    }
                    if store.hasMoreTasks {
                        Button("Load more") { Task { await store.loadMoreTasks() } }.disabled(store.loadingMore)
                    }
                    if store.tasks.isEmpty && !store.loading {
                        Text("No tasks yet").font(.system(size: 14)).foregroundStyle(CommaTheme.textQuaternary)
                    }
                } header: { Text("Tasks") }
                Section {
                    Button { Task { await store.refresh() } } label: {
                        Label { Text("Refresh") } icon: { CentralIcon("central-arrow-rotate-clockwise", relativeTo: .body) }
                    }
                    Button(role: .destructive) { Task { await store.logout() } } label: {
                        Label { Text("Sign out") } icon: { CentralIcon("central-arrow-box-left", relativeTo: .body) }
                    }
                    .disabled(store.loading)
                }
                if let error = store.error {
                    Text(error).font(.footnote).foregroundStyle(CommaTheme.errorPrimary)
                }
            }
            .navigationTitle("Comma")
            .navigationDestination(for: WatchRoute.self) { route in
                switch route {
                case .router:
                    if let pane = store.router.pane { WatchConversationView(pane: pane) } else { ProgressView() }
                case .task(let id):
                    Group {
                        if let task = store.task, task.taskID == id { WatchConversationView(pane: task) } else { ProgressView() }
                    }
                    .task { await store.openTask(id: id) }
                    .onDisappear { if store.task?.taskID == id { store.closeTask() } }
                }
            }
        }
        .onAppear { consumeTask() }
        .onChange(of: requestedTaskID) { _, _ in consumeTask() }
    }

    private func consumeTask() {
        guard let id = requestedTaskID else { return }
        requestedTaskID = nil
        path = [.task(id)]
    }
}

private enum WatchRoute: Hashable { case router, task(String) }
