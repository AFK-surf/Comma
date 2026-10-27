import SwiftUI
import CommaCore

@MainActor @Observable final class Metrics {
    var listLoads = 0
    var windowBottomInset: CGFloat = 0
    /// The last send as the server got it, "text=<text>|skills=<location,…>", then "|reply=<message id>" for a
    /// reply; empty until one arrives.
    var lastSend = ""
    /// Each name the profile was saved with, in the order the server took them.
    var profileSaves: [String] = []
    /// The server answers the reads a `--fail-…` switch refused (`PerfSignal.recover` arrived).
    var recovered = false
    /// Reads of earlier router messages that `--hold-earlier` holds.
    var earlierHeld = 0
    /// The `--perf-stream` reply streamed to its end and the server committed it.
    var replyCommitted = false
}
/// Runs the production shell on the client core the app carries, with a session kept in memory and the fixture
/// server in place of the backend; no backend is contacted.
@main struct ChatGestureFixtureApp: App {
    @State private var store: CommaStore
    @State private var metrics: Metrics
    @State private var call: CallController?
    @StateObject private var activity = TaskActivityCoordinator()
    /// Only for `--perf-probe` launches; see `PerfOptions` for the other perf switches.
    @State private var probe: FramePacingProbe?
    @State private var geometry = ProcessInfo.processInfo.arguments.contains("--transcript-probe") ? TranscriptGeometryProbe() : nil
    @MainActor private static var started = false
    init() {
        let metrics = Metrics()
        let perf = PerfOptions()
        let server = FixtureServer(metrics: metrics, perf: perf)
        FixtureServer.shared = server
        Task { await server.listenForSignals() }
        let custody = try! SessionCustody(record: FixtureCredentials(), apiOrigin: FixtureServer.origin)
        custody.adoptEarlier(StoredBearer(token: "test", audience: custody.audience, sessionId: "s", userId: "u",
                                          email: "test@test.test", expiresAtEpochSeconds: 9_999_999_999))
        // Every launch starts from nothing the core kept: an unread Inbox, whatever an earlier run marked.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fixture-\(UUID().uuidString)", isDirectory: true)
        let downloads = directory.appendingPathComponent("downloads", isDirectory: true)
        try! FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureURLProtocol.self]
        let runtime = try! CoreRuntime.make(custody: custody, dataDirectory: directory.appendingPathComponent("core"),
                                            downloadRoot: downloads, configuration: configuration)
        let config = AppConfiguration(baseURL: URL(string: FixtureServer.origin)!, credentialService: "fixture")
        let store = CommaStore(configuration: config, runtime: runtime)
        // `--router-unread=N` stands in for the server's unread router replies, which the real app's badge sync reads.
        if let unread = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--router-unread=") })
            .flatMap({ Int($0.dropFirst("--router-unread=".count)) }) {
            store.router.reportUnread(unread)
        }
        _store = State(initialValue: store)
        _call = State(initialValue: ProcessInfo.processInfo.arguments.contains("--call-controls")
                      ? CallController(store: store) : nil)
        _metrics = State(initialValue: metrics)
        _probe = State(initialValue: perf.probe ? FramePacingProbe() : nil)
    }
    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.arguments.contains("--call-bubble-probe") {
                CallBubbleProbe(store: store)
            } else if ProcessInfo.processInfo.arguments.contains("--card-motion-probe") {
                CardMotionProbe()
            } else {
                // `--launch-in-chat` opens on the chat as the app does; the other tests start on Home.
                AppShellView(store: store, activity: activity, navigation: AppNavigation(
                    routerOpen: ProcessInfo.processInfo.arguments.contains("--launch-in-chat")))
                    .environment(call)
                    .overlay(alignment: .top) {
                        HStack {
                            Text("\(metrics.listLoads)").accessibilityIdentifier("listLoads")
                            Text("\(metrics.windowBottomInset)").accessibilityIdentifier("windowBottomInset")
                            // The router reply the member counts as seen, which the badge acknowledges.
                            Text(verbatim: store.router.displayedReplyID ?? "none").accessibilityIdentifier("displayedReply")
                            Text(verbatim: metrics.lastSend.isEmpty ? "none" : metrics.lastSend).lineLimit(1)
                                .accessibilityIdentifier("lastSend")
                            Text(verbatim: metrics.profileSaves.joined(separator: "|")).lineLimit(1)
                                .accessibilityIdentifier("profileSaves")
                            Text(verbatim: metrics.recovered ? "recovered" : "failing").accessibilityIdentifier("serverRecovered")
                            Text("\(metrics.earlierHeld)").accessibilityIdentifier("earlierHeld")
                            Text(verbatim: metrics.replyCommitted ? "committed" : "none").accessibilityIdentifier("replyCommitted")
                            if let geometry {
                                Text(verbatim: geometry.summary).accessibilityIdentifier("transcriptGeometry")
                            }
                            if let probe {
                                Text("\(probe.completed)").accessibilityIdentifier("framePacing").accessibilityValue(probe.summary)
                            }
                        }
                        .allowsHitTesting(false)
                        // Screenshots leave the counters out; the UI tests read them.
                        .opacity(ProcessInfo.processInfo.arguments.contains("--hide-metrics") ? 0 : 1)
                    }
                    .task {
                        // Once per launch, as the app starts at bootstrap: after a `--login` sign-in the shell
                        // appears again and must not reload what signing in already loaded.
                        if !Self.started { Self.started = true; await store.start() }
                        metrics.windowBottomInset = UIApplication.shared.connectedScenes
                            .compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
                            .first(where: \.isKeyWindow)?.safeAreaInsets.bottom ?? 0
                    }
            }
        }
    }
}
/// The credential store's record, in memory.
final class FixtureCredentials: CredentialRecord, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    func read() throws -> Data? { lock.withLock { data } }
    func write(_ data: Data) throws { lock.withLock { self.data = data } }
    func delete() throws { lock.withLock { data = nil } }
}
