import Foundation
import UIKit
import CommaCore
import notify

/// What the fixture answers a request with: a status and JSON, or an event stream that stays open.
enum FixtureResponse: Sendable {
    case json(Int, Data)
    case bytes(Data, String)
    case partial(Data, String, offset: Int, total: Int)
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
    /// The reads of earlier router messages `--hold-earlier` holds until `PerfSignal.releaseEarlier`.
    private var heldEarlier: [CheckedContinuation<Void, Never>] = []
    private var earlierReleased = false

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
        router = perf.variedChat ? PerfChat.varied() : perf.longChat ? PerfChat.messages() : FixtureData.routerMessages
        if ProcessInfo.processInfo.arguments.contains("--startup-short-chat") { router = Array(router.prefix(2)) }
        if ChatImageFixture.enabled { router += ChatImageFixture.messages }
        replyGate = perf.stream ? PerfReplyGate.listening() : nil
    }

    /// Listens for `PerfSignal.recover`, after which the failing reads answer, `PerfSignal.releaseSave` and
    /// `PerfSignal.releaseEarlier`.
    func listenForSignals() {
        FixtureRecorder.listen()
        var token: Int32 = 0
        notify_register_dispatch(PerfSignal.recover.name, &token, .global()) { [weak self] _ in
            Task { await self?.recover() }
        }
        var release: Int32 = 0
        notify_register_dispatch(PerfSignal.releaseSave.name, &release, .global()) { [weak self] _ in
            Task { await self?.releaseProfileSave() }
        }
        var earlier: Int32 = 0
        notify_register_dispatch(PerfSignal.releaseEarlier.name, &earlier, .global()) { [weak self] _ in
            Task { await self?.releaseEarlier() }
        }
    }

    private func releaseEarlier() {
        earlierReleased = true
        for read in heldEarlier { read.resume() }
        heldEarlier.removeAll()
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
        if ChatImageFixture.enabled, let response = await MainActor.run(body: {
            ChatImageFixture.response(path, body: body, range: request.value(forHTTPHeaderField: "range"))
        }) { return response }
        if ProcessInfo.processInfo.arguments.contains("--mini-app"), let response = MiniAppFixture.response(path) {
            return response
        }
        let parts = path.split(separator: "/").map(String.init)
        let json: String
        switch (request.httpMethod ?? "GET", path) {
        // A send, to the router chat or a Task: first, as the router's message history shares its path.
        case ("POST", _) where parts.count == 5 && parts[2] == "conversations" && parts[4] == "messages":
            json = try await accept(body, in: parts[3])
        // The composer's dictation: after three seconds, the server's one `transcription` event; `--dictation-fails` makes
        // it the ASR's failure.
        case ("POST", "me/recordings/transcribe"):
            let failed = ProcessInfo.processInfo.arguments.contains("--dictation-fails")
            let result = failed ? #"{"status":"error","reason":"Transcription failed. The audio remains in Drive."}"#
                : #"{"status":"ready","result":{"transcript":"Book the room for Friday","duration_seconds":2,"chunks":[]}}"#
            return .stream(AsyncThrowingStream { continuation in
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    continuation.yield(Data("event: transcription\ndata: \(result)\n\n".utf8))
                    continuation.finish()
                }
            })
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
        case ("GET", "workspaces/w/integrations/voice"):
            json = #"{"lines":[],"numbers":[],"readiness":{"ready":true}}"#
        case ("GET", "workspaces/w/voice-api-keys"):
            json = "[]"
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
            json = FixtureData.routerConversation(router.suffix(routerReadLimit(value("message_limit"))))
        case (_, "groups/g/conversations/home/messages"):
            if perf.holdEarlier, value("before") != nil, !earlierReleased {
                await MainActor.run { metrics.earlierHeld += 1 }
                await withCheckedContinuation { heldEarlier.append($0) }
            }
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
            .first(where: { $0.name == "message_limit" })?.value
        let snapshot = PerfStream.snapshot(router.suffix(routerReadLimit(limit ?? "24")))
        guard let replyGate else { return PerfStream.held([snapshot]) }
        return PerfStream.reply(after: snapshot, gate: replyGate) { await self.commitReply() }
    }

    private func commitReply() async {
        router.append(PerfChat.streamedMessage())
        await MainActor.run { metrics.replyCommitted = true }
    }

    /// How many of the newest router messages a read answers with: those asked for, with `--perf-varied-chat` the
    /// 500 a device keeps, and with `--hold-earlier` at most 24, so earlier ones are left for the server to read.
    private func routerReadLimit(_ asked: String?) -> Int {
        let limit = asked.flatMap(Int.init) ?? router.count
        if perf.holdEarlier { return min(limit, 24) }
        return perf.variedChat ? 500 : limit
    }

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
        guard conversation != "home" else {
            // The varied chat's messages carry their seq, and a send joins them with the next one.
            router.append(FixtureData.sentMessage(text: text, requestID: requestID, seq: perf.variedChat ? router.count + 1 : nil))
            return FixtureData.routerConversation(router.suffix(routerReadLimit("24")))
        }
        guard let task = FixtureData.task(id: conversation) else { throw FixtureFailure.notFound }
        let message = FixtureData.sentMessage(text: text, requestID: requestID)
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
            case .bytes(let data, let mime):
                client.urlProtocol(this, didReceive: Self.response(request, 200, mime), cacheStoragePolicy: .notAllowed)
                client.urlProtocol(this, didLoad: data)
                client.urlProtocolDidFinishLoading(this)
            case .partial(let data, let mime, let offset, let total):
                let response = HTTPURLResponse(url: request.url!, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: [
                    "Content-Type": mime, "Content-Length": String(data.count), "Accept-Ranges": "bytes",
                    "Content-Range": "bytes \(offset)-\(offset + data.count - 1)/\(total)",
                ])!
                client.urlProtocol(this, didReceive: response, cacheStoragePolicy: .notAllowed)
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


/// A local bundle for native fullscreen, keyboard and dismissal checks.
private enum MiniAppFixture {
    static let baseApp = #"{"id":"reading","slug":"reading","workspace_id":"w","name":"Reading tracker","description":"Your cloud reading list","icon_url":null,"repo":{"owner":"test","name":"app"},"visibility":"private","status":"active","live_version":1,"latest_version":1,"author":{"name":"Alex"},"capabilities":["files.pick"],"egress":[],"storage":["user"],"has_backend":false,"secrets":[],"grants":[],"installed":false,"install":null,"created_at":"2026-10-01T00:00:00Z","updated_at":"2026-10-01T00:00:00Z"}"#
    static var app: String {
        guard ProcessInfo.processInfo.arguments.contains("--app-detail"),
              var value = (try? JSONSerialization.jsonObject(with: Data(baseApp.utf8))) as? [String: Any] else { return baseApp }
        value["description"] = String(repeating: "Keep your reading list, record memorable passages, and review your notes in one place. ", count: 6)
        value["icon_url"] = "/v1/comma/apps/reading/icon?v=1"
        value["cover_url"] = "/v1/comma/apps/reading/cover?v=1"
        value["screenshot_urls"] = ["/v1/comma/apps/reading/screenshots/0?v=1", "/v1/comma/apps/reading/screenshots/1?v=1"]
        value["versions"] = [
            ["number": 1, "state": "ready", "live": true, "notes": "Save your reading list and keep notes for each book."],
            ["number": 2, "state": "ready", "live": false, "notes": "Add reading goals", "commit": "abcdef1234"],
        ]
        return String(data: (try? JSONSerialization.data(withJSONObject: value)) ?? Data(baseApp.utf8), encoding: .utf8) ?? baseApp
    }

    static func response(_ path: String) -> FixtureResponse? {
        if ProcessInfo.processInfo.arguments.contains("--app-detail"),
           ["apps/reading/icon", "apps/reading/cover", "apps/reading/screenshots/0", "apps/reading/screenshots/1"].contains(path) {
            // A colored cover makes unintended gaps under the Duo's system rail visible.
            if path.hasSuffix("cover"), let data = UIImage(named: "MiniAppCoverPlaceholder")?.pngData() {
                return .bytes(data, "image/png")
            }
            let file = path.hasSuffix("icon") ? "mini-app-icon" : "mini-app-cover"
            if let url = Bundle.main.url(forResource: file, withExtension: "png"), let data = try? Data(contentsOf: url) {
                return .bytes(data, "image/png")
            }
        }
        switch path {
        case "workspaces/w/apps":
            if ProcessInfo.processInfo.arguments.contains("--mini-app-empty") { return .ok(#"{"data":[]}"#) }
            return .ok("{\"data\":[\(app)]}")
        case "workspaces/w/apps/reading": return .ok(app)
        case "apps/reading/open": return .ok("{\"app\":\(app),\"version\":1,\"digest\":\"fixture\",\"guest\":false,\"viewer\":{\"id\":\"u\",\"name\":\"Alex\",\"avatar_url\":null}}")
        case "workspaces/w/apps/reading/versions/1/bundle": return .json(200, bundle)
        default: return nil
        }
    }
    static var bundle: Data {
        let html = """
        <!doctype html><style>html,body{height:100%}body{box-sizing:border-box;background:#efe5d0;color:#28241f;font:17px -apple-system;padding:24px}input{font:inherit;padding:12px;max-width:90%;border-radius:12px;border:1px solid #8c8069}p{line-height:1.6}</style>
        <h1>Reading tracker</h1><p>Your cloud reading list</p><p>The Little Prince<br>A Brief History of Time</p><input aria-label="Reading notes" placeholder="Reading notes"><p>Reading app ready</p>
        <button id="photos">Choose app photos</button><p id="photo-result">No photos shared</p>
        <script>
        document.getElementById('photos').onclick = async () => {
          document.getElementById('photo-result').textContent = 'Photo request pending';
          try {
            const files = await comma.files.pick({accept:['image/png']});
            document.getElementById('photo-result').textContent = files.length
              ? 'Shared photo: ' + files[0].mime + ', buffer=' + (files[0].data instanceof ArrayBuffer)
              : 'Photo request cancelled';
          } catch (e) { document.getElementById('photo-result').textContent = 'Photo request: ' + e.code; }
        };
        </script>
        """
        let body = Data(html.utf8)
        var header = Data(repeating: 0, count: 512)
        header.replaceSubrange(0 ..< 10, with: "index.html".utf8)
        let size = String(body.count, radix: 8)
        header.replaceSubrange(124 ..< 135, with: (String(repeating: "0", count: 11 - size.count) + size).utf8)
        header[156] = 0x30
        header.replaceSubrange(257 ..< 262, with: "ustar".utf8)
        return header + body + Data(repeating: 0, count: (512 - body.count % 512) % 512 + 1024)
    }
}
