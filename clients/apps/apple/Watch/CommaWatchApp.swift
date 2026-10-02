import SwiftUI
import CommaCore

@main
struct CommaWatchApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store: CommaStore?
    @StateObject private var bridge = WatchPairingBridge()
    @State private var requestedTaskID: String?
    @State private var pendingURL: URL?
    @State private var error: String?

    var body: some Scene {
        WindowGroup {
            Group {
                if let store, store.initialized {
                    if store.session != nil { WatchHomeView(store: store, requestedTaskID: $requestedTaskID) }
                    else { WatchConnectView(store: store, bridge: bridge) }
                } else if let error {
                    Text(error).font(.footnote).foregroundStyle(CommaTheme.errorPrimary).padding()
                } else {
                    CommaMark(size: 32).foregroundStyle(.white).opacity(0.9)
                }
            }
            .task { await configure() }
            .onChange(of: scenePhase) { _, phase in
                guard let store else { return }
                if phase == .active {
                    Task { await bridge.applyLatestContext(); await store.resume() }
                } else if phase == .background { store.suspend() }
            }
            .onOpenURL { url in
                pendingURL = url
                Task { await consumeLink() }
            }

        }
    }

    private func consumeLink() async {
        guard let store, !store.workspaces.isEmpty, let url = pendingURL else { return }
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
            bridge.configure(store: value)
            await value.start()
            await bridge.applyLatestContext()
            value.onWorkspaceChanged = { _ in Task { await consumeLink() } }
            await consumeLink()
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
                Text("Connect once with your iPhone to chat and follow tasks from your watch.")
                    .font(.system(size: 14)).foregroundStyle(CommaTheme.textTertiary)
                    .multilineTextAlignment(.center)
                Button {
                    Task { await bridge.pair() }
                } label: {
                    if bridge.pairing { ProgressView() } else { Text("Connect with iPhone") }
                }
                .buttonStyle(.borderedProminent).tint(CommaTheme.brandSolid)
                .disabled(bridge.pairing)
                if let message = bridge.error ?? store.error {
                    Text(message).font(.footnote).foregroundStyle(CommaTheme.errorPrimary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 4)
        }
    }
}

struct WatchHomeView: View {
    @Bindable var store: CommaStore
    @Binding var requestedTaskID: String?
    @State private var path: [WatchRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                NavigationLink(value: WatchRoute.home) {
                    HStack(spacing: 8) {
                        CommaMark(size: 18).foregroundStyle(.white)
                        Text("Home").font(.system(size: 16, weight: .medium))
                    }
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
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await store.refresh() } }
                    Button("Sign out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                        Task { await store.logout() }
                    }.disabled(store.loading)
                }
                if let error = store.error {
                    Text(error).font(.footnote).foregroundStyle(CommaTheme.errorPrimary)
                }
            }
            .navigationTitle("Comma")
            .navigationDestination(for: WatchRoute.self) { route in
                switch route {
                case .home:
                    if let home = store.home { WatchConversationView(pane: home) } else { ProgressView() }
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

private enum WatchRoute: Hashable { case home, task(String) }

struct WatchConversationView: View {
    @Bindable var pane: ConversationPane

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let task = pane.conversation, task.isTask {
                        TaskStatusLabel(status: task.status).padding(.bottom, 8)
                    }
                    if pane.loading && rows.isEmpty { ProgressView().frame(maxWidth: .infinity) }
                    if let error = pane.error {
                        Text(error).font(.footnote).foregroundStyle(CommaTheme.errorPrimary).padding(.bottom, 6)
                    }
                    if pane.hasOlderMessages {
                        Button("Earlier messages") { Task { await pane.loadEarlierMessages() } }
                            .disabled(pane.loadingMore).padding(.bottom, 8)
                    }
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        rowView(row)
                            .padding(.top, index == 0 ? 0 : (row.isUser == rows[index - 1].isUser ? 4 : 12))
                            .id(row.id)
                    }
                    composer.padding(.top, 14)
                    if let task = pane.conversation, task.canAcceptReview {
                        Button("Accept result", systemImage: "checkmark.circle") { Task { await pane.acceptReview() } }
                            .tint(CommaTheme.successPrimary).padding(.top, 6)
                    }
                }
                .padding(.horizontal, 2).padding(.bottom, 8)
                .animation(CommaMotion.sendPosition, value: rows.map(\.id))
            }
            .onChange(of: rows.last?.id) { _, id in
                if let id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
            }
        }
        .navigationTitle(pane.conversation?.isTask == true ? "Task" : "Comma")
    }

    private var rows: [ChatRow] {
        ChatTranscriptModel.rows(messages: pane.messages, pending: pane.currentPendingSends,
                                 draft: pane.assistantDraft, isTask: pane.conversation?.isTask == true,
                                 activity: pane.replyActivity)
    }

    @ViewBuilder private func rowView(_ row: ChatRow) -> some View {
        HStack(spacing: 0) {
            if row.isUser { Spacer(minLength: 16) }
            VStack(alignment: row.isUser ? .trailing : .leading, spacing: 4) {
                if row.isDraft && row.text.isEmpty {
                    ThinkingBubble(label: row.activityLabel ?? String(localized: "Thinking…"), compact: true)
                } else if !row.text.isEmpty {
                    MessageBubbles(text: row.text, isUser: row.isUser, tail: row.bubbleTail, compact: true)
                }
                if let message = row.message { MessageExtras(message: message) }
                if case .pending(_, _, let failed, let attemptID) = row.content, failed {
                    Button("Retry") {
                        if let attempt = pane.pendingSends.first(where: { $0.id == attemptID }) {
                            Task { await pane.retry(attempt) }
                        }
                    }
                    .font(.footnote).foregroundStyle(CommaTheme.errorPrimary)
                }
            }
            if !row.isUser { Spacer(minLength: 16) }
        }
        .transition(row.isUser ? .move(edge: .bottom).combined(with: .opacity) : .opacity)
    }

    private var composer: some View {
        HStack(spacing: 6) {
            TextField("Message", text: $pane.draftText)
                .font(.system(size: 15))
            Button {
                Task { await pane.send() }
            } label: {
                Image(systemName: "arrow.up").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(canSend ? CommaTheme.brandSolid : CommaTheme.textPlaceholder, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel("Send message")
        }
    }

    private var canSend: Bool {
        pane.canSend && !pane.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
