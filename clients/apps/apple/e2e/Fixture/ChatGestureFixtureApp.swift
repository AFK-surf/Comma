import SwiftUI
import CommaCore

@MainActor @Observable final class Metrics {
    var listLoads = 0
    var windowBottomInset: CGFloat = 0
}
/// Runs the production shell with memory credentials and a controlled transport; no backend is contacted.
@main struct ChatGestureFixtureApp: App {
    @State private var store: CommaStore
    @State private var metrics: Metrics
    @StateObject private var activity = TaskActivityCoordinator()
    init() {
        let metrics = Metrics()
        let origin = "https://chat-gesture.test"
        let credentials = FixtureCredentials()
        try! credentials.save(StoredCredential(origin: origin, token: "test", session: CommaSession(id: "s", expiresAt: 9_999_999_999, user: CommaUser(id: "u", email: "test@test.test"))))
        let config = AppConfiguration(baseURL: URL(string: origin)!, credentialService: "fixture")
        let client = try! CommaClient(baseURL: config.baseURL, credentialStore: credentials, transport: FixtureTransport(metrics: metrics))
        _store = State(initialValue: CommaStore(configuration: config, client: client))
        _metrics = State(initialValue: metrics)
    }
    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.arguments.contains("--card-motion-probe") {
                CardMotionProbe()
            } else {
                HomeShellView(store: store, activity: activity)
                    .overlay(alignment: .top) {
                        HStack {
                            Text("\(metrics.listLoads)").accessibilityIdentifier("listLoads")
                            Text("\(metrics.windowBottomInset)").accessibilityIdentifier("windowBottomInset")
                        }
                        .allowsHitTesting(false)
                    }
                    .task {
                        await store.start()
                        metrics.windowBottomInset = UIApplication.shared.connectedScenes
                            .compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
                            .first(where: \.isKeyWindow)?.safeAreaInsets.bottom ?? 0
                    }
            }
        }
    }
}
final class FixtureCredentials: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var credential: StoredCredential?
    func load(origin: String) throws -> StoredCredential? { lock.withLock { credential } }
    func save(_ value: StoredCredential) throws { lock.withLock { credential = value } }
    func delete(origin: String) throws { lock.withLock { credential = nil } }
}
actor FixtureTransport: CommaTransport {
    let metrics: Metrics
    init(metrics: Metrics) { self.metrics = metrics }
    func data(for request: URLRequest) async throws -> HTTPResponse {
        let json: String
        switch request.url!.path {
        case "/v1/comma/auth/session":
            json = "{\"session_id\":\"s\",\"expires_at\":9999999999,\"user\":{\"id\":\"u\",\"email\":\"test@test.test\"}}"
        case "/v1/comma/workspaces":
            json = "{\"data\":[{\"id\":\"w\",\"group_id\":\"g\",\"name\":\"Test workspace\"}]}"
        case "/v1/comma/groups/g/conversations":
            await MainActor.run { metrics.listLoads += 1 }
            let tasks = (0..<30).map { "{\"id\":\"task\($0)\",\"group_id\":\"g\",\"title\":\"Task \($0)\",\"status\":\"running\",\"kind\":\"agent_task\"}" }.joined(separator: ",")
            json = "{\"data\":[\(tasks)],\"has_more\":false}"
        case "/v1/comma/groups/g/assistant-chat", "/v1/comma/groups/g/conversations/home":
            let messages = fixtureMessages()
            json = "{\"id\":\"home\",\"group_id\":\"g\",\"title\":\"Home\",\"status\":\"open\",\"kind\":\"user_chat\",\"messages\":[\(messages)]}"
        case "/v1/comma/groups/g/conversations/home/messages":
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let limit = query.first(where: { $0.name == "limit" }).flatMap { Int($0.value ?? "") } ?? 100
            let end = min(30, query.first(where: { $0.name == "before" }).flatMap { Int($0.value ?? "") }.map { $0 - 1 } ?? 30)
            let start = max(0, end - limit)
            let covered = start < end ? "{\"first\":\(start + 1),\"last\":\(end)}" : "{\"first\":null,\"last\":null}"
            json = "{\"data\":[\(fixtureMessages(in: start..<end))],\"covered\":\(covered),\"bounds\":{\"first\":1,\"last\":30},\"has_older\":\(start > 0),\"has_newer\":false}"
        case "/v1/comma/groups/g/conversations/task0":
            json = "{\"id\":\"task0\",\"group_id\":\"g\",\"title\":\"Task 0\",\"status\":\"running\",\"kind\":\"agent_task\",\"messages\":[]}"
        case "/v1/comma/groups/g/conversations/task0/messages":
            json = "{\"data\":[],\"covered\":{\"first\":null,\"last\":null},\"bounds\":{\"first\":null,\"last\":null},\"has_older\":false,\"has_newer\":false}"
        default: throw CommaError.invalidResponse
        }
        return HTTPResponse(data: Data(json.utf8), status: 200)
    }
    private func fixtureMessages(in range: Range<Int> = 0..<30) -> String {
        range.map { "{\"message_id\":\"message\($0)\",\"kind\":\"message\",\"actor_type\":\"agent\",\"content\":[{\"type\":\"text\",\"text\":\"History message \($0). This is a reply in the Home conversation.\"}]}" }.joined(separator: ",")
    }
    func stream(for request: URLRequest) async throws -> HTTPStreamResponse {
        HTTPStreamResponse(status: 200, headers: ["content-type":"text/event-stream"], chunks: AsyncThrowingStream { $0.finish() })
    }
}

/// Measures viewport relayouts while the real card host opens and closes over a scrolling transcript.
private struct CardMotionProbe: View {
    @State private var docked = false
    @State private var layouts = 0
    @State private var viewportHeight: CGFloat = 0
    @State private var draft = "Keep this draft"
    private var transcript: some View {
        NavigationStack {
            ScrollView {
                VStack {
                    ForEach(0..<40) { index in
                        Text("History message \(index)").frame(maxWidth: .infinity).frame(height: 60)
                    }
                }
            }
            .defaultScrollAnchor(.bottom)
            .safeAreaInset(edge: .bottom) {
                TextField("Message", text: $draft).padding().accessibilityIdentifier("motionDraft")
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in layouts += 1; viewportHeight = height }
        }
    }
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            HomeCardHost(bottomInset: docked ? 66 : 0, rounded: docked) { transcript }
                .ignoresSafeArea(.container, edges: .vertical)
        }
        .overlay(alignment: .top) {
            HStack {
                Text("\(layouts)").accessibilityIdentifier("cardViewportLayouts")
                Text("\(viewportHeight)").accessibilityIdentifier("cardViewportHeight")
                Button(docked ? "Close task" : "Open task") { docked.toggle() }
                    .accessibilityIdentifier("toggleMotionTask")
            }
        }
    }
}
