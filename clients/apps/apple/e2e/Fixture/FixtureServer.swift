import Foundation
import CommaCore
import notify

/// What the fixture answers a request with: a status and JSON, or an event stream that stays open.
enum FixtureResponse: Sendable {
    case json(Int, Data)
    case stream(AsyncThrowingStream<Data, any Error>)
    /// The connection fails, as an unreachable server's does.
    case unreachable

    static func ok(_ json: String) -> FixtureResponse { .json(200, Data(json.utf8)) }
}

/// The fixture's Comma API: answers the client core's requests from `FixtureData`, in the app's process (through
/// `FixtureURLProtocol`). Unknown routes fail, as an unavailable server would. `PerfOptions` can lengthen the router
/// chat, stream a reply and add latency.
actor FixtureServer {
    static let origin = "https://chat-gesture.test"
    /// The one server of the launch, which `FixtureURLProtocol` hands every request to.
    nonisolated(unsafe) static var shared: FixtureServer?

    let metrics: Metrics
    let perf: PerfOptions
    /// The router chat's messages as JSON, oldest first. A `--perf-stream` reply joins them once it completes.
    private var router: [String]
    private let replyGate: PerfReplyGate?
    /// The member's name as the server holds it. With `--hold-first-profile-save` the first save answers only once
    /// the test posts `PerfSignal.releaseSave`, so the test decides what happens while it is under way.
    private var profileName = "Alex Rivera"
    private var holdingProfileSave = ProcessInfo.processInfo.arguments.contains("--hold-first-profile-save")
    private var heldProfileSave: CheckedContinuation<Void, Never>?
    private var profileSaveReleased = false

    /// An upload answers after 0.8 s, so its tile shows it uploading; `--upload-fail-once` refuses the first.
    private var uploads = 0
    private let uploadFailsOnce = ProcessInfo.processInfo.arguments.contains("--upload-fail-once")
    /// `--fail-task-list` refuses every read of the task list, which Home and the Inbox say they could not load, until
    /// the test posts `PerfSignal.recover`. The client core reads again by itself meanwhile; only the signal ends it.
    private var taskListFails = ProcessInfo.processInfo.arguments.contains("--fail-task-list")
    /// `--fail-task-actions` refuses changes to a Task (archive, rename, status), which report as the app's toast.
    private let taskActionsFail = ProcessInfo.processInfo.arguments.contains("--fail-task-actions")
    /// `--fail-workspaces-once` refuses the first read of the Workspaces, so the app starts with no Workspace.
    private var workspacesFailOnce = ProcessInfo.processInfo.arguments.contains("--fail-workspaces-once")
    /// `--models` answers the read of the Workspace's models (`FixtureData.modelCatalog`).
    private let models = ProcessInfo.processInfo.arguments.contains("--models")
    /// `--fail-task-open` refuses every read of a Task, which then never loaded, until `PerfSignal.recover`.
    private var taskOpenFails = ProcessInfo.processInfo.arguments.contains("--fail-task-open")

    init(metrics: Metrics, perf: PerfOptions = PerfOptions()) {
        self.metrics = metrics
        self.perf = perf
        router = perf.longChat ? PerfChat.messages() : FixtureData.routerMessages
        replyGate = perf.stream ? PerfReplyGate.listening() : nil
    }

    /// Listens for `PerfSignal.recover`, after which the failing reads answer, and `PerfSignal.releaseSave`.
    func listenForSignals() {
        var token: Int32 = 0
        notify_register_dispatch(PerfSignal.recover.name, &token, .global()) { [weak self] _ in
            Task { await self?.recover() }
        }
        var release: Int32 = 0
        notify_register_dispatch(PerfSignal.releaseSave.name, &release, .global()) { [weak self] _ in
            Task { await self?.releaseProfileSave() }
        }
    }

    private func releaseProfileSave() {
        profileSaveReleased = true
        heldProfileSave?.resume()
        heldProfileSave = nil
    }

    private func recover() async {
        taskListFails = false
        taskOpenFails = false
        await MainActor.run { metrics.recovered = true }
    }

    func answer(_ request: URLRequest, body: Data?) async -> FixtureResponse {
        try? await delay()
        if request.url!.path.hasSuffix("/events") { return .stream(stream(for: request)) }
        do {
            return try await route(request, body: body)
        } catch FixtureFailure.unreachable {
            return .unreachable
        } catch FixtureFailure.conflict {
            return .json(409, Data(#"{"error":"conflict"}"#.utf8))
        } catch FixtureFailure.notFound {
            return .json(404, Data(#"{"error":"not_found"}"#.utf8))
        } catch {
            return .json(500, Data(#"{"error":"server_error"}"#.utf8))
        }
    }

    private func route(_ request: URLRequest, body: Data?) async throws -> FixtureResponse {
        let url = request.url!
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { query.first(where: { $0.name == name })?.value }
        let path = url.path.replacingOccurrences(of: "/v1/comma/", with: "")
        let parts = path.split(separator: "/").map(String.init)
        let json: String
        switch (request.httpMethod ?? "GET", path) {
        // A send, to the router chat or a Task: first, as the router's message history shares its path.
        case ("POST", _) where parts.count == 5 && parts[2] == "conversations" && parts[4] == "messages":
            json = try await accept(body, in: parts[3])
        case (_, "auth/session"):
            json = #"{"session_id":"s","expires_at":9999999999,"user":{"id":"u","email":"test@test.test"}}"#
        case ("POST", "me/bootstrap"):
            json = #"{"status":"ready","workspace":{"id":"w","group_id":"g","name":"Test workspace"}}"#
        case (_, "workspaces"):
            if workspacesFailOnce {
                workspacesFailOnce = false
                throw FixtureFailure.server
            }
            json = #"{"data":[{"id":"w","group_id":"g","name":"Test workspace"}]}"#
        case ("POST", "groups/g/files"):
            json = try await upload(body)
        case ("PATCH", "me/profile"):
            json = try await saveProfile(body)
        case (_, "me/profile"):
            json = profile
        case (_, "workspaces/w/skills"):
            json = FixtureData.skills
        // `--models`: the Settings page's read of the models, which the router's @ menu lists; without it the read
        // fails and the menu lists none.
        case ("GET", "model-catalog") where models:
            json = FixtureData.modelCatalog
        case ("GET", "workspaces/w/subscription-accounts") where models:
            json = FixtureData.modelProfiles
        case ("GET", "workspaces/w/agent-models") where models:
            json = FixtureData.agentModels
        case (_, "workspaces/w/recommendations"):
            json = FixtureData.recommendations
        case (_, "groups/g/task-activity"):
            json = #"{"data":[]}"#
        case (_, "groups/g/task-labels"):
            json = #"{"labels":[{"id":"l1","name":"Launch","color":"blue"},{"id":"l2","name":"Research","color":"green"}],"proposals":[],"colors":["blue","green"],"approval_policy":"ask"}"#
        case (_, "groups/g/conversation-pins"):
            json = #"{"data":[]}"#
        case (_, "groups/g/conversations") where value("archive") == "only":
            json = FixtureData.archivedPage(cursor: value("cursor"))
        case (_, "groups/g/conversations"):
            if taskListFails { throw FixtureFailure.server }
            await MainActor.run { metrics.listLoads += 1 }
            json = FixtureData.taskPage()
        case (_, "groups/g/assistant-chat"), (_, "groups/g/conversations/home"):
            json = FixtureData.routerConversation(router.suffix(value("message_limit").flatMap(Int.init) ?? router.count))
        case (_, "groups/g/conversations/home/messages"):
            json = FixtureData.messagePage(router, limit: value("limit").flatMap(Int.init) ?? 100,
                                           before: value("before").flatMap(Int.init))
        case ("POST", _) where parts.count == 5 && parts[2] == "conversations" && parts[4] == "accept":
            FixtureData.accepted.insert(parts[3])
            guard let task = FixtureData.task(id: parts[3]) else { throw FixtureFailure.notFound }
            json = task
        case ("GET", _) where parts.count == 4 && parts[2] == "conversations":
            if taskOpenFails { throw FixtureFailure.server }
            guard let task = FixtureData.task(id: parts[3]) else { throw FixtureFailure.notFound }
            json = String(task.dropLast()) + #","messages":["# + FixtureData.taskMessages(id: parts[3]).joined(separator: ",") + "]}"
        case ("GET", _) where parts.count == 5 && parts[2] == "conversations" && parts[4] == "messages":
            json = #"{"data":[],"covered":null,"bounds":null,"has_older":false,"has_newer":false}"#
        case (let method, _) where taskActionsFail && ["POST", "PATCH"].contains(method)
                                    && path.hasPrefix("groups/g/conversations/"):
            throw FixtureFailure.conflict
        default:
            if let answer = FixtureTaskActions.answer(request.httpMethod ?? "GET", path, value, body: body) {
                return answer
            }
            print("FixtureServer: no route for \(request.httpMethod ?? "GET") \(path)")
            throw FixtureFailure.notFound
        }
        return .ok(json)
    }

    /// Every stream stays open, as a live server's does between events. The router's opens with its snapshot when
    /// a perf switch asks for it, and `--perf-stream` then drafts a reply.
    private func stream(for request: URLRequest) -> AsyncThrowingStream<Data, any Error> {
        guard request.url!.path.hasSuffix("/conversations/home/events"), perf.holdStream || perf.stream else {
            return PerfStream.held([])
        }
        let limit = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "message_limit" })?.value.flatMap(Int.init) ?? 24
        let snapshot = PerfStream.snapshot(router.suffix(limit))
        guard let replyGate else { return PerfStream.held([snapshot]) }
        return PerfStream.reply(after: snapshot, gate: replyGate) { await self.commitReply() }
    }

    private func commitReply() { router.append(PerfChat.streamedMessage()) }

    /// Notes a send's text and tagged skills for the tests (`lastSend`) and answers as the server does: with the
    /// conversation, the member's message in it under the send's request id.
    private func accept(_ body: Data?, in conversation: String) async throws -> String {
        let fields = try JSONDecoder().decode([String: JSONValue].self, from: body ?? Data())
        let text = fields["message"]?.object?["text"]?.string ?? ""
        let requestID = fields["client_request_id"]?.string ?? ""
        let skills = fields["skills"]?.array?.compactMap { $0.object?["location"]?.string } ?? []
        let reply = fields["reply_to_message_id"]?.string.map { "|reply=\($0)" } ?? ""
        let sent = "text=\(text)|skills=\(skills.joined(separator: ","))" + reply
        await MainActor.run { metrics.lastSend = sent }
        let message = FixtureData.sentMessage(text: text, requestID: requestID)
        guard conversation != "home" else {
            router.append(message)
            return FixtureData.routerConversation(router.suffix(24))
        }
        guard let task = FixtureData.task(id: conversation) else { throw FixtureFailure.notFound }
        return String(task.dropLast()) + #","messages":[\#(message)]}"#
    }

    private var profile: String {
        let name = String(decoding: try! JSONEncoder().encode(profileName), as: UTF8.self)
        return #"{"id":"u","email":"test@test.test","name":\#(name)}"#
    }

    /// Takes the name the client sends (the first one once released, when held) and answers with the profile as it
    /// now stands.
    private func saveProfile(_ body: Data?) async throws -> String {
        guard let body, let name = (try JSONSerialization.jsonObject(with: body) as? [String: Any])?["name"] as? String
        else { throw FixtureFailure.notFound }
        if holdingProfileSave {
            holdingProfileSave = false
            if !profileSaveReleased { await withCheckedContinuation { heldProfileSave = $0 } }
        }
        profileName = name
        await MainActor.run { metrics.profileSaves.append(name) }
        return profile
    }

    /// Keeps nothing; answers with the file's name, as the server's workspace file.
    private func upload(_ body: Data?) async throws -> String {
        uploads += 1
        let number = uploads
        try await Task.sleep(for: .milliseconds(800))
        if uploadFailsOnce, number == 1 { throw FixtureFailure.notFound }
        let text = String(decoding: body ?? Data(), as: UTF8.self)
        let name = text.range(of: #"filename="([^"]+)""#, options: .regularExpression)
            .map { String(text[$0].dropFirst(10).dropLast()) } ?? "file"
        return #"{"path":"/uploads/\#(number)","name":"\#(name)","size":\#(body?.count ?? 0)}"#
    }

    private func delay() async throws {
        if perf.latency > .zero { try await Task.sleep(for: perf.latency) }
    }
}

/// `server` is the server failing a request (500), which the client core does not retry by itself.
enum FixtureFailure: Error { case unreachable, conflict, notFound, server }

/// Hands each request of the app's URL loading to `FixtureServer.shared`.
final class FixtureURLProtocol: URLProtocol, @unchecked Sendable {
    private var serving: Task<Void, Never>?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = self.request
        let body = Self.body(of: request)
        nonisolated(unsafe) let this = self
        serving = Task {
            guard let server = FixtureServer.shared else { return }
            let answer = await server.answer(request, body: body)
            guard !Task.isCancelled, let client = this.client else { return }
            switch answer {
            case .unreachable:
                client.urlProtocol(this, didFailWithError: URLError(.cannotConnectToHost))
            case .json(let status, let data):
                client.urlProtocol(this, didReceive: Self.response(request, status, "application/json"), cacheStoragePolicy: .notAllowed)
                client.urlProtocol(this, didLoad: data)
                client.urlProtocolDidFinishLoading(this)
            case .stream(let chunks):
                client.urlProtocol(this, didReceive: Self.response(request, 200, "text/event-stream"), cacheStoragePolicy: .notAllowed)
                do {
                    for try await chunk in chunks { client.urlProtocol(this, didLoad: chunk) }
                    client.urlProtocolDidFinishLoading(this)
                } catch {
                    client.urlProtocol(this, didFailWithError: error)
                }
            }
        }
    }

    override func stopLoading() { serving?.cancel() }

    private static func response(_ request: URLRequest, _ status: Int, _ type: String) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type])!
    }

    /// A request's body: URL loading moves a body given with the request into a stream.
    private static func body(of request: URLRequest) -> Data? {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

