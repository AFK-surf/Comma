import Foundation

/// A call's input, read from JSON and never changed afterwards.
private struct SendableInput: @unchecked Sendable {
    let value: [String: Any]
    init(_ value: [String: Any]) { self.value = value }
}

/// What the iPhone's Sign in with Apple sheet gave: an identity token bound to the attempt's nonce, or why none.
protocol AppleIdentityTokens: Sendable {
    /// Shows the sheet for the server's client and nonce; the identity token once the person chose.
    func request(clientId: String, nonce: String) async throws -> String
}

/**
 * The app as the client core's host: what `packages/core/src/hosts/mobile.ts` asks for, as `CoreHost.kt` is Android's.
 *
 * - Product requests (`fetch`, `stream.*`) go to the Comma API with the bearer of the lease they name, taken from
 *   `custody`'s gate; one made for a lease the gate does not hold is answered 409 without reaching the server. A 401
 *   shuts the gate and tells the core. Redirects are not followed; a 304 (the core's own conditional read) is no
 *   redirect.
 * - Auth requests (`auth.fetch`) carry the credential the core names by reference; a bearer in the answer stays in
 *   `custody`.
 * - The session ports (`session.*`) are `custody`'s and `apple`'s.
 * - The databases (`sql.*`) are SQLite files in `dataDirectory`, used at once on the core's thread.
 */
final class CoreHost: CoreHostOps, @unchecked Sendable {
    private static let withheld: Set<String> = ["authorization", "cookie", "host", "content-length", "connection"]
    private static let authRequestHeaders: Set<String> = ["accept", "content-type"]
    private static let authResponseHeaders: Set<String> = ["content-type", "retry-after"]
    private static let leaseUnavailable = Data(#"{"error":{"code":"session_product_lease_unavailable"}}"#.utf8)

    let custody: SessionCustody
    let downloads: HostDownloads
    private let apple: any AppleIdentityTokens
    private let network: StreamSession
    private let sql: HostSQL
    /// Told of each request that got no answer or a server error (its status), for diagnostics.
    private let networkFailure: @Sendable (Int?) -> Void

    private let lock = NSLock()
    private weak var engine: (any CoreEngine)?
    /// Requests under way, by the core's operation id (what `abort` names).
    private var calls: [UInt64: ResponseStream] = [:]
    private var tasks: [UInt64: Task<Void, Never>] = [:]
    private var open: [Int: ResponseStream] = [:]
    /// Streams the app answered itself: their body, given once, then the end.
    private var ended: [Int: Data] = [:]
    private var nextStream = 1
    /// The lease each download is made for: it stops when that lease is no longer the open one.
    private var downloadLeases: [Int: LeasedBearer] = [:]

    init(custody: SessionCustody, dataDirectory: URL, downloads: HostDownloads, apple: any AppleIdentityTokens,
         configuration: URLSessionConfiguration = .default, networkFailure: @escaping @Sendable (Int?) -> Void = { _ in }) {
        self.custody = custody
        self.downloads = downloads
        self.apple = apple
        self.networkFailure = networkFailure
        self.sql = HostSQL(directory: dataDirectory)
        let configuration = configuration.copy() as! URLSessionConfiguration
        // The server holds an event stream open and sends a heartbeat every 15 s.
        configuration.timeoutIntervalForRequest = 60
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        self.network = StreamSession(configuration: configuration)
    }

    func startConfig() -> [String: Any] {
        ["platform": "ios", "apiOrigin": custody.audience, "resumed": custody.resume()]
    }

    func attached(_ engine: (any CoreEngine)?) {
        let gone: ([ResponseStream], [Task<Void, Never>]) = lock.withLock {
            self.engine = engine
            guard engine == nil else { return ([], []) }
            let streams = Array(calls.values) + Array(open.values)
            let running = Array(tasks.values)
            calls.removeAll(); open.removeAll(); ended.removeAll(); tasks.removeAll(); downloadLeases.removeAll()
            return (streams, running)
        }
        guard engine == nil else { return }
        // The core went: its databases close, its requests end, and what it had not settled is queued.
        for stream in gone.0 { stream.cancel() }
        for task in gone.1 { task.cancel() }
        downloads.closeAll()
        sql.closeAll()
        custody.coreExited()
    }

    /// The server answered 401 to a request the app made itself with `leased`: the gate shuts now, and the core hears
    /// it as a refusal of that lease.
    func unauthorized(_ leased: LeasedBearer) {
        guard custody.revoke(leased) else { return }
        let engine = lock.withLock { self.engine }
        engine?.rejected(lease: CoreClient.text(leased.lease.json), status: 401)
    }

    func callSync(_ op: String, input: [String: Any]) throws -> Any? {
        switch op {
        case "session.gate":
            custody.gate(input["snapshot"] as? [String: Any] ?? [:], lease: SessionLease(input["lease"]))
            return nil
        case "sql.open": return try sql.open(try Self.string(input, "name"))
        case "sql.exec": try sql.exec(try Self.int(input, "id"), try Self.string(input, "sql")); return nil
        case "sql.run": return try sql.run(try Self.int(input, "id"), try Self.string(input, "sql"), input["params"] as? [Any])
        case "sql.all": return try sql.all(try Self.int(input, "id"), try Self.string(input, "sql"), input["params"] as? [Any])
        case "sql.close": sql.close(try Self.int(input, "id")); return nil
        case "sql.delete": try sql.delete(try Self.string(input, "name")); return nil
        default: throw HostFailure(message: "unknown operation: \(op)")
        }
    }

    func call(_ op: String, id: UInt64, input json: [String: Any], bytes: Data?, reply: CoreReply) {
        // Never changed after it was read, so the operation's task may take it.
        let box = SendableInput(json)
        let input = json
        switch op {
        case "abort":
            guard let aborted = (input["id"] as? NSNumber)?.uint64Value else { return }
            let (stream, task) = lock.withLock { (calls.removeValue(forKey: aborted), tasks.removeValue(forKey: aborted)) }
            stream?.cancel()
            task?.cancel()
            custody.dropped(aborted)
        case "fetch": run(id, reply, box) { input in try await self.product(id, input, bytes, reply, stream: false) }
        case "stream.open": run(id, reply, box) { input in try await self.product(id, input, bytes, reply, stream: true) }
        case "stream.read":
            let streamId = (input["id"] as? NSNumber)?.intValue ?? 0
            run(id, reply, box) { input in try await self.read(streamId, reply) }
        case "stream.close":
            let streamId = (input["id"] as? NSNumber)?.intValue ?? 0
            let stream = lock.withLock { () -> ResponseStream? in
                ended[streamId] = nil
                return open.removeValue(forKey: streamId)
            }
            stream?.cancel()
            reply.ok()
        case "auth.fetch": run(id, reply, box) { input in try await self.auth(id, input, bytes, reply) }
        case "download.open": run(id, reply, box) { input in try await self.download(id, input, bytes, reply) }
        case "download.step":
            let download = (input["id"] as? NSNumber)?.intValue ?? 0
            run(id, reply, box) { input in
                let leased = self.lock.withLock { self.downloadLeases[download] }
                do {
                    let step = try await self.downloads.step(download) { leased.map(self.custody.isCurrent) ?? false }
                    if step["sha256"] != nil { self.lock.withLock { self.downloadLeases[download] = nil } }
                    reply.ok(step)
                } catch {
                    self.lock.withLock { self.downloadLeases[download] = nil }
                    throw error
                }
            }
        case "download.close":
            let download = (input["id"] as? NSNumber)?.intValue ?? 0
            lock.withLock { downloadLeases[download] = nil }
            downloads.close(download)
            reply.ok()
        case "download.remove":
            downloads.remove(input["path"] as? String ?? "")
            reply.ok()
        case "download.retain":
            downloads.retain(input["keep"] as? String)
            reply.ok()
        case "session.vault": reply.ok(custody.vault())
        case "session.change":
            run(id, reply, box) { input in
                let value = try self.custody.change(input["change"] as? [String: Any] ?? [:])
                reply.ok(["value": value ?? NSNull()])
            }
        case "session.apple":
            run(id, reply, box) { input in
                let token = try await self.apple.request(clientId: try Self.string(input, "clientId"), nonce: try Self.string(input, "nonce"))
                reply.ok(["identityToken": token])
            }
        default:
            reply.fail("unknown operation: \(op)")
        }
    }

    /// Runs `body` for operation `id`, which `abort` cancels; a failure answers the operation.
    private func run(_ id: UInt64, _ reply: CoreReply, _ input: SendableInput,
                     _ body: @escaping @Sendable (_ input: [String: Any]) async throws -> Void) {
        let task = Task {
            do { try await body(input.value) } catch is CancellationError {
                // Given up by the core: never answered.
            } catch {
                if !Task.isCancelled { reply.fail(Self.describe(error)) }
            }
            _ = self.lock.withLock { self.tasks.removeValue(forKey: id) }
        }
        lock.withLock { tasks[id] = task }
    }

    private static func describe(_ error: any Error) -> String {
        if let failure = error as? HostFailure { return failure.message }
        if error is URLError { return "The request got no answer." }
        return "\(error)"
    }

    private static func string(_ input: [String: Any], _ key: String) throws -> String {
        guard let value = input[key] as? String else { throw HostFailure(message: "\(key) is missing") }
        return value
    }

    private static func int(_ input: [String: Any], _ key: String) throws -> Int {
        guard let value = (input[key] as? NSNumber)?.intValue else { throw HostFailure(message: "\(key) is missing") }
        return value
    }

    private func request(_ input: [String: Any], _ bytes: Data?) throws -> URLRequest {
        let path = try Self.string(input, "path")
        guard path.hasPrefix("/"), let url = URL(string: custody.audience + path),
              let scheme = url.scheme, let host = url.host,
              try SessionCustody.canonicalAudience("\(scheme)://\(host)\(url.port.map { ":\($0)" } ?? "")") == custody.audience else {
            throw HostFailure(message: "The request escaped its audience.")
        }
        let method = (try Self.string(input, "method")).uppercased()
        var request = URLRequest(url: url)
        request.httpMethod = method
        var contentType: String?
        for case let pair as [Any] in input["headers"] as? [Any] ?? [] {
            guard pair.count == 2, let name = (pair[0] as? String)?.lowercased(), let value = pair[1] as? String,
                  !Self.withheld.contains(name) else { continue }
            if name == "content-type" { contentType = value }
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let bytes { request.httpBody = bytes } else if method != "GET" && method != "HEAD" { request.httpBody = Data() }
        if let contentType, request.httpBody != nil { request.setValue(contentType, forHTTPHeaderField: "content-type") }
        return request
    }

    private func track(_ id: UInt64, _ stream: ResponseStream) { lock.withLock { calls[id] = stream } }
    @discardableResult private func untrack(_ id: UInt64) -> Bool { lock.withLock { calls.removeValue(forKey: id) != nil } }

    /// A download's request, as a product request is made: a 200 begins writing to the path the core named.
    private func download(_ id: UInt64, _ input: [String: Any], _ bytes: Data?, _ reply: CoreReply) async throws {
        guard let leased = SessionLease(input["lease"]).flatMap(custody.acquire) else {
            reply.ok(["id": 0, "status": 409, "total": NSNull()])
            return
        }
        var request = try request(input, bytes)
        request.setValue("Bearer \(leased.token)", forHTTPHeaderField: "authorization")
        let stream = network.start(request)
        track(id, stream)
        let head: ResponseHead
        do {
            head = try await stream.response()
        } catch {
            untrack(id)
            if !Task.isCancelled { networkFailure(nil) }
            throw error
        }
        untrack(id)
        if head.status >= 500 { networkFailure(head.status) }
        if head.status == 401 { unauthorized(leased) }
        guard head.status == 200, custody.isCurrent(leased) else {
            stream.cancel()
            reply.ok(["id": 0, "status": head.status == 200 ? 409 : head.status, "total": NSNull()])
            return
        }
        let download: Int
        do {
            download = try downloads.begin(stream, head: head, path: try Self.string(input, "target"))
        } catch {
            stream.cancel()
            throw error
        }
        lock.withLock { downloadLeases[download] = leased }
        reply.ok(["id": download, "status": 200, "total": head.length.map { $0 as Any } ?? NSNull()])
    }

    /// A product request: the lease's bearer added, the answer whole (`fetch`) or opened as a stream.
    private func product(_ id: UInt64, _ input: [String: Any], _ bytes: Data?, _ reply: CoreReply, stream: Bool) async throws {
        guard let leased = SessionLease(input["lease"]).flatMap(custody.acquire) else {
            answer(reply, 409, Self.leaseUnavailable, stream: stream)
            return
        }
        var request = try request(input, bytes)
        request.setValue("Bearer \(leased.token)", forHTTPHeaderField: "authorization")
        // The account's own session endpoints (its list of signed-in devices) take a bearer only when told it is one.
        if (input["path"] as? String ?? "").hasPrefix("/v1/comma/auth/") {
            request.setValue("bearer", forHTTPHeaderField: "x-comma-session-transport")
        }
        let response = network.start(request)
        track(id, response)
        let head: ResponseHead
        do {
            head = try await response.response()
        } catch {
            untrack(id)
            if Task.isCancelled { throw CancellationError() }
            networkFailure(nil)
            if !custody.isCurrent(leased) { answer(reply, 409, Self.leaseUnavailable, stream: stream); return }
            throw HostFailure(message: "The request got no answer.")
        }
        if head.status >= 500 { networkFailure(head.status) }
        if !custody.isCurrent(leased) {
            untrack(id)
            response.cancel()
            answer(reply, 409, Self.leaseUnavailable, stream: stream)
        } else if (300...399).contains(head.status) && head.status != 304 {
            untrack(id)
            response.cancel()
            answer(reply, 502, Data(#"{"error":"upstream_redirect_blocked"}"#.utf8), stream: stream)
        } else if head.status == 401 {
            untrack(id)
            response.cancel()
            // The gate shuts before anything else is told: no later request carries this bearer.
            unauthorized(leased)
            answer(reply, 401, Data(#"{"error":"unauthorized"}"#.utf8), stream: stream)
        } else if stream {
            untrack(id)
            let streamId = lock.withLock { () -> Int in
                defer { nextStream += 1 }
                open[nextStream] = response
                return nextStream
            }
            var json = head.json
            json["id"] = streamId
            reply.ok(json)
        } else {
            let body: Data
            do {
                body = try await response.body()
            } catch {
                untrack(id)
                if Task.isCancelled { throw CancellationError() }
                throw HostFailure(message: "The answer broke off.")
            }
            untrack(id)
            reply.ok(head.json, body)
        }
    }

    /// An answer the app gives itself: for a stream, one that is already at its end.
    private func answer(_ reply: CoreReply, _ status: Int, _ body: Data, stream: Bool) {
        var head: [String: Any] = ["status": status, "headers": [["content-type", "application/json"]]]
        guard stream else {
            reply.ok(head, body)
            return
        }
        let streamId = lock.withLock { () -> Int in
            defer { nextStream += 1 }
            ended[nextStream] = body
            return nextStream
        }
        head["id"] = streamId
        reply.ok(head)
    }

    private func read(_ streamId: Int, _ reply: CoreReply) async throws {
        enum Next { case given(Data), end, stream(ResponseStream) }
        let next: Next = lock.withLock {
            if let body = ended[streamId] {
                if body.isEmpty { ended[streamId] = nil; return .end }
                ended[streamId] = Data()
                return .given(body)
            }
            return open[streamId].map(Next.stream) ?? .end
        }
        switch next {
        case .given(let body): reply.ok(bytes: body)
        case .end: reply.ok(["end": true])
        case .stream(let stream):
            do {
                // What has arrived, at least one byte: an event goes on as soon as the server sends it.
                if let data = try await stream.read() {
                    reply.ok(bytes: data)
                } else {
                    _ = lock.withLock { open.removeValue(forKey: streamId) }
                    reply.ok(["end": true])
                }
            } catch {
                _ = lock.withLock { open.removeValue(forKey: streamId) }
                if Task.isCancelled { throw CancellationError() }
                throw HostFailure(message: "The stream broke off.")
            }
        }
    }

    /// An auth request: the credential it names attached, a bearer in the answer kept in the custody.
    private func auth(_ id: UInt64, _ input: [String: Any], _ bytes: Data?, _ reply: CoreReply) async throws {
        guard (input["path"] as? String ?? "").hasPrefix("/v1/comma/auth/") else {
            throw HostFailure(message: "Only the auth endpoints are made for the session lifecycle.")
        }
        var kept = input
        kept["headers"] = (input["headers"] as? [Any] ?? []).filter { pair in
            guard let name = ((pair as? [Any])?.first as? String)?.lowercased() else { return false }
            return Self.authRequestHeaders.contains(name)
        }
        var request = try request(kept, bytes)
        request.setValue("bearer", forHTTPHeaderField: "x-comma-session-transport")
        if let credential = input["credential"] as? String {
            guard let token = custody.tokenFor(credential) else { throw HostFailure(message: "The credential named is not kept.") }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        }
        let response = network.start(request)
        track(id, response)
        let head: ResponseHead
        let body: Data
        do {
            head = try await response.response()
            body = try await response.body()
        } catch {
            untrack(id)
            if Task.isCancelled { throw CancellationError() }
            networkFailure(nil)
            throw HostFailure(message: "The request got no answer.")
        }
        if head.status >= 500 { networkFailure(head.status) }
        let answered = custody.keepBearer(body, request: id)
        // Given up meanwhile: the core never takes this answer, so what it carried is queued.
        if !untrack(id) { custody.dropped(id) }
        let headers = head.headers.filter { Self.authResponseHeaders.contains($0.0) }.map { [$0.0, $0.1] }
        reply.ok(["status": head.status, "headers": headers], answered)
    }
}
