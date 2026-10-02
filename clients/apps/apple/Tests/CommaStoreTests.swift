import Foundation
import XCTest
import CommaCore
@testable import Comma
#if canImport(UIKit)
import UIKit
import SwiftUI
#endif

@MainActor
final class CommaStoreTests: XCTestCase {
    /// Old: opening a Task replaced Home, so Home's in-flight page had to be fenced off.
    /// New: Home and the Task sheet own separate panes; each keeps its own history paging.
    func testTaskPaginationIsIndependentOfHomeHistoryInFlight() async throws {
        let harness = try StoreHarness()
        let store = harness.store
        await store.start()
        defer { store.suspend() }
        let home = try XCTUnwrap(store.home)
        XCTAssertTrue(home.hasOlderMessages)
        await harness.transport.pauseNext(method: "GET", path: "/v1/comma/groups/g1/conversations/home/messages", query: "before")
        let older = Task { await home.loadEarlierMessages() }
        await harness.transport.waitForPausedRequest()
        XCTAssertTrue(home.loadingMore)

        await store.openTask(id: "task")
        let task = try XCTUnwrap(store.task)
        XCTAssertEqual(task.conversation?.id, "task")
        XCTAssertFalse(task.loadingMore, "The Task pane must not inherit Home's loading flag")
        XCTAssertTrue(task.hasOlderMessages)
        await harness.transport.releasePaused(historyJSON(first: 1, last: 100, older: false))
        await older.value
        XCTAssertFalse(home.hasOlderMessages)

        await task.loadEarlierMessages()
        XCTAssertFalse(task.hasOlderMessages)
        let requests = await harness.transport.requests()
        XCTAssertTrue(requests.contains { $0.url?.path == "/v1/comma/groups/g1/conversations/task/messages" && $0.hasQuery("before") })
    }

    /// Opening and closing the Task sheet must not reload Home or lose its draft.
    func testOpeningAndClosingTaskKeepsHomeLoaded() async throws {
        let harness = try StoreHarness(withTranscript: true)
        let store = harness.store
        await store.start()
        defer { store.suspend() }
        let home = try XCTUnwrap(store.home)
        home.draftText = "Half-written question"
        let homeLoads = { await harness.transport.requests().filter { $0.url?.path == "/v1/comma/groups/g1/assistant-chat" }.count }
        let loadsBefore = await homeLoads()

        await store.openTask(id: "task")
        XCTAssertEqual(store.task?.conversation?.id, "task")
        XCTAssertTrue(store.home === home)
        XCTAssertEqual(home.conversation?.id, "home")
        XCTAssertEqual(home.messages.count, 2)

        // A Task card for the Task already open asks the sheet to expand without reloading the Task.
        let taskLoads = { await harness.transport.requests().filter { $0.url?.path == "/v1/comma/groups/g1/conversations/task" }.count }
        let reveals = store.taskRevealRequest
        let loadsOfTask = await taskLoads()
        await store.openTask(id: "task")
        XCTAssertEqual(store.taskRevealRequest, reveals + 1)
        let reloadsOfTask = await taskLoads()
        XCTAssertEqual(reloadsOfTask, loadsOfTask)

        store.closeTask()
        XCTAssertNil(store.task)
        XCTAssertTrue(store.home === home)
        XCTAssertFalse(home.closed)
        XCTAssertEqual(home.draftText, "Half-written question")
        let loadsAfter = await homeLoads()
        XCTAssertEqual(loadsAfter, loadsBefore)
    }

    func testFailedLogoutDuringSendPreservesAuthorityAndOneRetryIdentity() async throws {
        let harness = try StoreHarness()
        let store = harness.store
        await store.start()
        defer { store.suspend() }
        let home = try XCTUnwrap(store.home)
        await harness.transport.pauseNext(method: "POST", path: "/v1/comma/groups/g1/conversations/home/messages")
        await harness.transport.failNextLogout()
        home.draftText = "Run this task once"
        let sending = Task { await home.send() }
        await harness.transport.waitForPausedRequest()
        let intent = try XCTUnwrap(home.pendingSends.first)
        XCTAssertTrue(home.sending)

        await store.logout()
        XCTAssertEqual(store.session?.id, "phone-session")
        XCTAssertEqual(try harness.credentials.load(origin: testOrigin)?.session.id, "phone-session")
        XCTAssertFalse(home.sending)
        XCTAssertTrue(home.canSend)
        XCTAssertEqual(home.pendingSends.first?.status, .failed)
        await harness.transport.releasePaused(conversationJSON(id: "home", requestID: intent.id))
        await sending.value

        await home.retry(intent)
        let requests = await harness.transport.requests().filter { $0.httpMethod == "POST" && $0.url?.path == "/v1/comma/groups/g1/conversations/home/messages" }
        XCTAssertEqual(requests.count, 2)
        let identities = try requests.map { try JSONDecoder().decode([String: JSONValue].self, from: XCTUnwrap($0.httpBody))["client_request_id"] }
        XCTAssertEqual(identities, [.string(intent.id), .string(intent.id)])
        XCTAssertTrue(home.pendingSends.isEmpty)

        await store.logout()
        XCTAssertNil(store.session)
        XCTAssertNil(try harness.credentials.load(origin: testOrigin))
        let priorCount = await harness.transport.requests().count
        await home.retry(intent)
        let laterCount = await harness.transport.requests().count
        XCTAssertEqual(laterCount, priorCount, "An old view cannot submit its retry after signout")
    }

    /// Old: nothing showed between sending and the first draft, and a push-enrollment 404 stayed in the chat banner.
    /// New: this client's send shows "Thinking…" until its reply arrives, and push failures stay out of chat.
    func testSendShowsThinkingUntilReplyAndPushFailureStaysOutOfChat() async throws {
        let harness = try StoreHarness()
        let store = harness.store
        await store.start()
        defer { store.suspend() }
        store.reportPushRegistration("This item is no longer available.")
        XCTAssertNil(store.error)
        let home = try XCTUnwrap(store.home)

        home.draftText = "Run this task once"
        await home.send()
        let sent = await harness.transport.requests().last { $0.httpMethod == "POST" && $0.url?.path.hasSuffix("/messages") == true }?.httpBody
        let intent = try XCTUnwrap(sent)
        let requestID = try XCTUnwrap(JSONDecoder().decode([String: JSONValue].self, from: intent)["client_request_id"]?.string)
        XCTAssertEqual(home.replyActivity, "Thinking…")
        XCTAssertEqual(ChatTranscriptModel.rows(messages: home.messages, pending: home.currentPendingSends, draft: nil,
                                                isTask: false, activity: home.replyActivity).last?.activityLabel, "Thinking…")

        await harness.transport.serveHome("""
        {"id":"home","group_id":"g1","title":"home","status":"open","kind":"user_chat","messages":[\
        {"message_id":"accepted","kind":"chat","actor_type":"user","content":[{"type":"text","text":"Run this task once"}],"client_request_id":"\(requestID)"},\
        {"message_id":"reply","kind":"chat","actor_type":"agent","thread_root_message_id":"accepted","content":[{"type":"text","text":"Done."}]}]}
        """)
        await store.refresh()
        XCTAssertNil(home.replyActivity)
        XCTAssertNil(home.error)
    }

    func testLateAppleRevocationCheckCannotClearANewSession() async throws {
        let harness = try StoreHarness()
        let store = harness.store
        await store.start()
        defer { store.suspend() }
        let validation = CredentialValidationGate()
        store.validateSession = { _ in await validation.waitForResult() }
        let resuming = Task { await store.resume() }
        await validation.waitUntilStarted()

        await store.logout()
        let challenge = try await store.requestEmailCode(email: "next@example.com")
        await store.verifyEmail(challengeID: challenge.challengeID, code: "123456")
        XCTAssertEqual(store.session?.id, "next-session")
        await validation.resolve(false)
        await resuming.value
        XCTAssertEqual(store.session?.id, "next-session")
        let current = await store.client.session
        XCTAssertEqual(current?.id, "next-session")
        XCTAssertEqual(try harness.credentials.load(origin: testOrigin)?.session.id, "next-session")

        let formerlyValid = try XCTUnwrap(store.session)
        await store.invalidateLocalSession()
        await store.signedIn(formerlyValid)
        XCTAssertNil(store.session, "A late Watch/Apple completion cannot republish a locally revoked session")
    }

    #if canImport(UIKit)
    /// Edge drags must never enter the status pager or its refreshable task lists. Interior touches
    /// still reach those scroll views, including after switching between the opening and closing edge.
    func testDrawerEdgeTouchesAreIsolatedFromTaskPagingAndRefresh() async throws {
        let harness = try StoreHarness()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let originalWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: EdgeGestureTestSidebar(store: harness.store, closing: true))
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            originalWindow?.makeKeyAndVisible()
        }

        for closing in [true, false] {
            controller.rootView = EdgeGestureTestSidebar(store: harness.store, closing: closing)
            let bounds = controller.view.bounds
            let edge = CGPoint(x: closing ? bounds.maxX - 14 : 14, y: bounds.midY)
            let interior = CGPoint(x: bounds.midX, y: bounds.midY)
            try await waitForUI("Task scrolling should remain available away from the drawer edge", view: controller.view) {
                self.scrollViewReceivingTouch(at: interior, in: controller.view) != nil
            }
            XCTAssertNotNil(controller.view.hitTest(edge, with: nil), "The edge must own even vertical touches")
            XCTAssertNil(scrollViewReceivingTouch(at: edge, in: controller.view),
                         "An edge touch must not enroll a task pager or pull-to-refresh recognizer")
        }
    }

    private func scrollViewReceivingTouch(at point: CGPoint, in view: UIView) -> UIScrollView? {
        var target = view.hitTest(point, with: nil)
        while let current = target {
            if let scroll = current as? UIScrollView { return scroll }
            target = current.superview
        }
        return nil
    }

    func testTypingInEmptyChatPreservesDraft() async throws {
        try await exerciseComposer(withTranscript: false)
    }

    func testTypingWithTranscriptPreservesDraft() async throws {
        try await exerciseComposer(withTranscript: true)
    }

    /// Drive the actual UIKit editor inside the SwiftUI composer, without sending a message to a server.
    private func exerciseComposer(withTranscript: Bool) async throws {
        let harness = try StoreHarness(withTranscript: withTranscript)
        let store = harness.store
        await store.start()
        defer { store.suspend() }
        let home = try XCTUnwrap(store.home)
        XCTAssertTrue(home.canSend)
        XCTAssertEqual(home.messages.count, withTranscript ? 2 : 0)

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let originalWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: HomeShellView(store: store, activity: TaskActivityCoordinator()))
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        flushChatLayout(controller.view)
        defer {
            controller.view.endEditing(true)
            window.isHidden = true
            window.rootViewController = nil
            originalWindow?.makeKeyAndVisible()
        }

        try await waitForUI("The chat composer should mount", view: controller.view) {
            composerTextView(in: controller.view) != nil
        }
        if composerTextView(in: controller.view) == nil {
            print("CHAT INPUT VIEW HIERARCHY:\n\(chatViewHierarchy(controller.view))")
        }
        let editor = try XCTUnwrap(composerTextView(in: controller.view))
        XCTAssertEqual(editor.text, "")
        XCTAssertTrue(editor.becomeFirstResponder())
        try await waitForUI("The composer should accept keyboard input", view: controller.view) { editor.isFirstResponder }

        editor.insertText("Hello")
        flushChatLayout(controller.view)
        try await waitForUI("English typing should update the observable binding", view: controller.view) {
            home.draftText == "Hello"
        }
        XCTAssertEqual(editor.text, home.draftText)
        editor.setMarkedText("，你好", selectedRange: NSRange(location: 3, length: 0))
        flushChatLayout(controller.view)
        editor.unmarkText()
        flushChatLayout(controller.view)
        try await waitForUI("Chinese text should remain in the same binding", view: controller.view) { home.draftText == "Hello，你好" }
        editor.insertText("\n第二行")
        flushChatLayout(controller.view)
        try await waitForUI("The vertical editor should preserve multiple lines", view: controller.view) { home.draftText == "Hello，你好\n第二行" }
        XCTAssertEqual(editor.text, home.draftText)

        // SwiftUI may replace its UIKit editor when the binding clears; continue through the current view.
        home.draftText = ""
        flushChatLayout(controller.view)
        try await waitForUI("Clearing the binding should clear the editor", view: controller.view) {
            composerTextView(in: controller.view)?.text == ""
        }
        let currentEditor = try XCTUnwrap(composerTextView(in: controller.view))
        XCTAssertEqual(currentEditor.text, "")
        XCTAssertTrue(currentEditor.becomeFirstResponder())
        currentEditor.insertText("重新输入")
        flushChatLayout(controller.view)
        try await waitForUI("Typing after an external clear should remain safe", view: controller.view) {
            home.draftText == "重新输入"
        }
        XCTAssertEqual(currentEditor.text, home.draftText)
        let requests = await harness.transport.requests()
        XCTAssertTrue(requests.allSatisfy { $0.url?.host == "comma-store.test" })
        XCTAssertFalse(requests.contains { $0.httpMethod == "POST" && $0.url?.path.hasSuffix("/messages") == true })
    }

    private func waitForUI(_ message: String, view: UIView, condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            flushChatLayout(view)
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        flushChatLayout(view)
        XCTAssertTrue(condition(), message)
    }
    #endif
}

#if canImport(UIKit)
private struct EdgeGestureTestSidebar: View {
    let store: CommaStore
    let closing: Bool

    var body: some View {
        TaskSidebarView(store: store, openSettings: {}, openTask: { _ in }, goHome: {})
            .overlay(alignment: closing ? .trailing : .leading) {
                DrawerEdgeGesture(closing: closing, onChanged: { _ in }, onEnded: { _ in })
                    .frame(width: 28)
                    .ignoresSafeArea(.container, edges: .vertical)
            }
    }
}

@MainActor
private func flushChatLayout(_ view: UIView) {
    view.setNeedsLayout()
    view.layoutIfNeeded()
}

@MainActor
private func chatViewHierarchy(_ root: UIView, depth: Int = 0) -> String {
    let line = String(repeating: " ", count: depth) + "\(type(of: root)) id=\(root.accessibilityIdentifier ?? "nil") frame=\(root.frame)"
    let details: String
    if let editor = root as? UITextView {
        details = " editable=\(editor.isEditable) hidden=\(editor.isHidden) text=\(editor.text ?? "") traits=\(editor.accessibilityTraits.rawValue)"
    } else if let field = root as? UITextField {
        details = " enabled=\(field.isEnabled) hidden=\(field.isHidden) text=\(field.text ?? "") placeholder=\(field.placeholder ?? "nil") traits=\(field.accessibilityTraits.rawValue)"
    } else { details = "" }
    return ([line + details] + root.subviews.map { chatViewHierarchy($0, depth: depth + 1) }).joined(separator: "\n")
}

@MainActor
private func composerTextView(in root: UIView) -> UITextView? {
    let editors = editableChatTextViews(in: root)
    return editors.count == 1 ? editors.first : nil
}

@MainActor
private func editableChatTextViews(in root: UIView) -> [UITextView] {
    let own = (root as? UITextView).flatMap { $0.isEditable && !$0.isHidden ? $0 : nil }
    return (own.map { [$0] } ?? []) + root.subviews.flatMap { editableChatTextViews(in: $0) }
}

#endif

private let testOrigin = "https://comma-store.test"

@MainActor
private struct StoreHarness {
    let credentials: TestCredentials
    let transport: SuspendingTransport
    let store: CommaStore
    init(withTranscript: Bool = false) throws {
        let credentials = TestCredentials()
        let user = CommaUser(id: "phone-user", email: "phone@example.com")
        try credentials.save(StoredCredential(origin: testOrigin, token: "phone-bearer",
            session: CommaSession(id: "phone-session", expiresAt: 9_999_999_999, user: user)))
        let transport = SuspendingTransport(withTranscript: withTranscript)
        let configuration = AppConfiguration(baseURL: URL(string: testOrigin)!, credentialService: "CommaStoreTests")
        let client = try CommaClient(baseURL: configuration.baseURL, credentialStore: credentials, transport: transport)
        self.credentials = credentials; self.transport = transport
        store = CommaStore(configuration: configuration, client: client)
    }
}

private final class TestCredentials: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: StoredCredential] = [:]
    func load(origin: String) throws -> StoredCredential? { lock.withLock { values[origin] } }
    func save(_ credential: StoredCredential) throws { lock.withLock { values[credential.origin] = credential } }
    func delete(origin: String) throws { _ = lock.withLock { values.removeValue(forKey: origin) } }
}

private actor CredentialValidationGate {
    private var result: CheckedContinuation<Bool, Never>?
    private var entered: CheckedContinuation<Void, Never>?
    func waitForResult() async -> Bool {
        await withCheckedContinuation { result = $0; entered?.resume(); entered = nil }
    }
    func waitUntilStarted() async {
        if result != nil { return }
        await withCheckedContinuation { entered = $0 }
    }
    func resolve(_ value: Bool) { result?.resume(returning: value); result = nil }
}

/// Pauses an actual HTTP operation even when its task is cancelled, so Store ownership fences are exercised.
private actor SuspendingTransport: CommaTransport {
    private struct Pause { let method: String; let path: String; let query: String? }
    private var nextPause: Pause?
    private var paused: CheckedContinuation<HTTPResponse, any Error>?
    private var pauseWaiter: CheckedContinuation<Void, Never>?
    private var captured: [URLRequest] = []
    private var logoutFails = false
    private let withTranscript: Bool
    private var homeOverride: String?
    private var taskList = "{\"data\":[],\"has_more\":false,\"next_cursor\":null}"
    private var pins = "{\"data\":[]}"
    private var pinFailure = false
    init(withTranscript: Bool = false) { self.withTranscript = withTranscript }
    func serveHome(_ json: String) { homeOverride = json }
    func serveTasks(_ json: String) { taskList = json }
    func servePins(_ json: String) { pins = json }
    func failPinChanges() { pinFailure = true }
    func pauseNext(method: String, path: String, query: String? = nil) { nextPause = Pause(method: method, path: path, query: query) }
    func failNextLogout() { logoutFails = true }
    func waitForPausedRequest() async {
        if paused != nil { return }
        await withCheckedContinuation { pauseWaiter = $0 }
    }
    func releasePaused(_ json: String) { paused?.resume(returning: http(json)); paused = nil }
    func requests() -> [URLRequest] { captured }
    func data(for request: URLRequest) async throws -> HTTPResponse {
        captured.append(request)
        let path = request.url?.path ?? ""
        if let rule = nextPause, request.httpMethod == rule.method, path == rule.path,
           rule.query == nil || request.hasQuery(rule.query!) {
            nextPause = nil
            return try await withCheckedThrowingContinuation { paused = $0; pauseWaiter?.resume(); pauseWaiter = nil }
        }
        switch path {
        case "/v1/comma/auth/session": return http(sessionJSON(id: "phone-session", user: "phone-user", email: "phone@example.com"))
        case "/v1/comma/auth/logout":
            if logoutFails { logoutFails = false; return http("{\"error\":\"auth_unavailable\"}", status: 503) }
            return http("{\"signed_out\":true}")
        case "/v1/comma/auth/email/login": return http("{\"challenge_id\":\"next-challenge\"}")
        case "/v1/comma/auth/email/verify": return http(sessionJSON(id: "next-session", user: "next-user", email: "next@example.com", token: "next-bearer"))
        case "/v1/comma/workspaces": return http("{\"data\":[{\"id\":\"w1\",\"group_id\":\"g1\",\"name\":\"Workspace\"}]}")
        case "/v1/comma/groups/g1/assistant-chat": return http(conversationJSON(id: "home", withTranscript: withTranscript))
        case "/v1/comma/groups/g1/conversations": return http(taskList)
        case "/v1/comma/groups/g1/conversation-pins": return http(pins)
        case "/v1/comma/workspaces/w1/recommendations":
            return http("{\"state\":\"fresh\",\"settings\":{\"sources\":[{\"appId\":\"github\",\"appName\":\"GitHub\",\"connectionId\":\"gh\",\"enabled\":true}]},\"snapshot\":null}")
        case "/v1/comma/workspaces/w1/recommendations/refresh":
            return http("{\"error\":\"rate_limited\"}", status: 429)
        case "/v1/comma/groups/g1/conversations/task/pin":
            return pinFailure ? http("{\"error\":\"unavailable\"}", status: 503) : http("", status: 204)
        case "/v1/comma/groups/g1/conversations/task/archive":
            return http(taskJSON(title: "task", status: "archived"))
        case "/v1/comma/groups/g1/conversations/task" where request.httpMethod == "PATCH":
            let body = try JSONDecoder().decode([String: JSONValue].self, from: request.httpBody!)
            return http(taskJSON(title: body["title"]?.string ?? "task", status: "in_progress"))
        case "/v1/comma/groups/g1/conversations/home" where homeOverride != nil: return http(homeOverride!)
        case "/v1/comma/groups/g1/conversations/home", "/v1/comma/groups/g1/conversations/task":
            return http(conversationJSON(id: path.hasSuffix("task") ? "task" : "home", withTranscript: withTranscript))
        case "/v1/comma/groups/g1/conversations/home/messages", "/v1/comma/groups/g1/conversations/task/messages":
            if request.httpMethod == "POST" {
                let body = try JSONDecoder().decode([String: JSONValue].self, from: request.httpBody!)
                return http(conversationJSON(id: "home", requestID: body["client_request_id"]?.string))
            }
            return request.hasQuery("before") ? http(historyJSON(first: 1, last: 100, older: false)) : http(historyJSON(first: 101, last: 124, older: true))
        default: throw CommaError.invalidResponse
        }
    }
    func stream(for request: URLRequest) async throws -> HTTPStreamResponse {
        captured.append(request)
        return HTTPStreamResponse(status: 200, url: request.url, headers: ["content-type": "text/event-stream"],
            chunks: AsyncThrowingStream { $0.finish() })
    }
}

private extension URLRequest {
    func hasQuery(_ name: String) -> Bool {
        guard let url else { return false }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == name } == true
    }
}

private func http(_ json: String, status: Int = 200) -> HTTPResponse { HTTPResponse(data: Data(json.utf8), status: status) }
private func sessionJSON(id: String, user: String, email: String, token: String? = nil) -> String {
    let bearer = token.map { ",\"token\":\"\($0)\"" } ?? ""
    return "{\"session_id\":\"\(id)\",\"expires_at\":9999999999,\"user\":{\"id\":\"\(user)\",\"email\":\"\(email)\"}\(bearer)}"
}
private func conversationJSON(id: String, requestID: String? = nil, withTranscript: Bool = false) -> String {
    let initial = withTranscript ? "[{\"message_id\":\"question\",\"kind\":\"message\",\"actor_type\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"Hello Comma\"}]},{\"message_id\":\"answer\",\"kind\":\"message\",\"actor_type\":\"agent\",\"thread_root_message_id\":\"question\",\"content\":[{\"type\":\"text\",\"text\":\"你好，有什么可以帮你？\"}]}]" : "[]"
    let messages = requestID.map { "[{\"message_id\":\"accepted\",\"kind\":\"chat\",\"actor_type\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"Run this task once\"}],\"client_request_id\":\"\($0)\"}]" } ?? initial
    return "{\"id\":\"\(id)\",\"group_id\":\"g1\",\"title\":\"\(id)\",\"status\":\"open\",\"kind\":\"\(id == "task" ? "agent_task" : "user_chat")\",\"messages\":\(messages)}"
}
private func taskJSON(title: String, status: String) -> String {
    "{\"id\":\"task\",\"group_id\":\"g1\",\"title\":\"\(title)\",\"status\":\"\(status)\",\"kind\":\"agent_task\",\"updated_at\":42,\"messages\":[]}"
}
private func historyJSON(first: Int, last: Int, older: Bool) -> String {
    "{\"data\":[],\"covered\":{\"first\":\(first),\"last\":\(last)},\"bounds\":{\"first\":1,\"last\":124},\"has_older\":\(older),\"has_newer\":false}"
}

extension CommaStoreTests {
    func testAuthBoundaryInvalidatesNotificationRouteBeforeAwaitedLogoutResponse() async throws {
        let harness = try StoreHarness()
        let store = harness.store
        await store.start()
        defer { store.suspend() }
        let routeFence = try XCTUnwrap(NotificationNavigationFence(store: store))
        var boundaryCallbacks = 0
        var routeMatchedAtBoundary = true
        store.onAuthBoundaryChanged = {
            boundaryCallbacks += 1
            routeMatchedAtBoundary = routeFence.matches(store: store)
        }
        await harness.transport.pauseNext(method: "POST", path: "/v1/comma/auth/logout")
        let logout = Task { await store.logout() }
        await harness.transport.waitForPausedRequest()
        XCTAssertEqual(boundaryCallbacks, 1)
        XCTAssertFalse(routeMatchedAtBoundary)
        XCTAssertFalse(routeFence.matches(store: store))
        XCTAssertEqual(store.session?.id, "phone-session", "Local authority has not yet received the remote logout acknowledgment")
        await harness.transport.releasePaused("{\"signed_out\":true}")
        await logout.value
        XCTAssertNil(store.session)
    }

    func testScheduledNotificationRouteCannotRebindAfterLocalAuthReset() async throws {
        let harness = try StoreHarness()
        let store = harness.store
        await store.start()
        defer { store.suspend() }
        let routeFence = try XCTUnwrap(NotificationNavigationFence(store: store))
        var invalidatedSynchronously = false
        store.onAuthBoundaryChanged = {
            invalidatedSynchronously = !routeFence.matches(store: store) && store.session != nil
        }
        // Production captures this fence before creating its navigation Task.
        let scheduledRoute = Task {
            guard routeFence.matches(store: store) else { return false }
            await store.openTask(id: "task")
            return routeFence.matches(store: store)
        }
        await store.invalidateLocalSession()
        XCTAssertTrue(invalidatedSynchronously)
        let opened = await scheduledRoute.value
        XCTAssertFalse(opened)
        XCTAssertNil(store.task)
        XCTAssertNil(NotificationNavigationFence(store: store), "Signed-out routing cannot capture private navigation authority")

        // Only an intentional normal login resumes an unbound signed-out route,
        // capturing new authority rather than reusing the old route's fence.
        let challenge = try await store.requestEmailCode(email: "next@example.com")
        let verified = await store.verifyEmail(challengeID: challenge.challengeID, code: "123456")
        XCTAssertTrue(verified)
        let resumedFence = try XCTUnwrap(NotificationNavigationFence(store: store))
        XCTAssertTrue(resumedFence.matches(store: store))
        XCTAssertFalse(routeFence.matches(store: store))
    }
}

extension CommaStoreTests {
    /// New: a rename from the open Task's menu updates both its sheet and its list row without a re-read.
    func testRenamingOpenTaskUpdatesItsSheetAndListRow() async throws {
        let harness = try StoreHarness()
        await harness.transport.serveTasks("{\"data\":[\(taskJSON(title: "task", status: "in_progress"))],\"has_more\":false}")
        let store = harness.store
        await store.start()
        defer { store.suspend() }
        await store.openTask(id: "task")
        let renamed = await store.renameTask(id: "task", title: "Quarterly report")
        XCTAssertTrue(renamed)
        XCTAssertEqual(store.task?.conversation?.title, "Quarterly report")
        XCTAssertEqual(store.tasks.first?.title, "Quarterly report")
    }

    /// New: archiving the open Task closes its sheet and sends the version the list showed.
    func testArchivingOpenTaskClosesItWithItsListedVersion() async throws {
        let harness = try StoreHarness()
        await harness.transport.serveTasks("{\"data\":[\(taskJSON(title: "task", status: "in_progress"))],\"has_more\":false}")
        await harness.transport.servePins("{\"data\":[{\"conversation\":\(taskJSON(title: "task", status: "in_progress")),\"pinned_at\":1}]}")
        let store = harness.store
        await store.start()
        defer { store.suspend() }
        XCTAssertEqual(store.pinnedTaskIDs, ["task"])
        await store.openTask(id: "task")
        let listed = try XCTUnwrap(store.tasks.first)
        let archived = await store.setTaskArchived(listed, archived: true)
        XCTAssertTrue(archived)
        XCTAssertNil(store.task)
        XCTAssertFalse(store.pinnedTaskIDs.contains("task"))
        let requests = await harness.transport.requests()
        let request = try XCTUnwrap(requests.last { $0.url?.path.hasSuffix("/task/archive") == true })
        let body = try JSONDecoder().decode([String: JSONValue].self, from: try XCTUnwrap(request.httpBody))
        XCTAssertEqual(body["expected_updated_at"], .number(42))
    }

    /// New: a refused unpin restores the pin the member saw and reports the failure.
    func testRefusedUnpinRestoresThePin() async throws {
        let harness = try StoreHarness()
        await harness.transport.servePins("{\"data\":[{\"conversation\":\(taskJSON(title: "task", status: "in_progress")),\"pinned_at\":1}]}")
        await harness.transport.failPinChanges()
        let store = harness.store
        await store.start()
        defer { store.suspend() }
        await store.setTaskPinned(id: "task", pinned: false)
        XCTAssertEqual(store.pinnedTaskIDs, ["task"])
        XCTAssertNotNil(store.error)
    }
}

extension CommaStoreTests {
    /// New: a refresh past the hourly budget is the one Routines failure reported to the member; the briefing stays readable.
    func testRateLimitedRoutinesRefreshIsReportedAndKeepsTheFeed() async throws {
        let harness = try StoreHarness()
        let store = harness.store
        await store.start()
        defer { store.suspend() }
        await store.routines.refresh(store: store)
        XCTAssertEqual(store.routines.failure, .rateLimited)
        XCTAssertEqual(store.routines.feed?.canRefresh, true)
        XCTAssertFalse(store.routines.isRefreshing)
    }

    /// New: a member's own task becomes a request for help, keeping proper nouns' case.
    func testMemberTaskPromptBecomesARequestForHelp() {
        XCTAssertEqual(RoutineActions.memberRequest("Decide whether to ship"), "Help me decide whether to ship")
        XCTAssertEqual(RoutineActions.memberRequest("GitHub review for #12"), "Help me GitHub review for #12")
    }
}
