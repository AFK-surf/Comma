import Foundation
import Synchronization

/**
 * A Comma API inside the test process. It answers the requests made through `configuration` by method and path (JSON,
 * or a file's bytes when the answer is `Data`) and keeps each request. Every server has a host of its own, so the servers of different tests never see each other's
 * requests. A request with no answer gets a 404.
 */
final class FakeServer: @unchecked Sendable {
    struct Request: @unchecked Sendable {
        let method: String
        let path: String
        let authorization: String?
        let body: [String: Any]
        let raw: Data
    }

    typealias Answer = @Sendable (Request) -> (status: Int, json: Any)

    let origin: String
    private let lock = NSLock()
    private var answers: [String: Answer] = [:]
    private var seen: [Request] = []
    private var waiting: [(key: String, continuation: CheckedContinuation<Request, Never>)] = []

    init() {
        origin = "https://\(UUID().uuidString.lowercased()).comma.test"
        FakeServerProtocol.servers.withLock { $0[URL(string: origin)!.host!] = self }
    }

    deinit {
        let host = URL(string: origin)!.host!
        FakeServerProtocol.servers.withLock { _ = $0.removeValue(forKey: host) }
    }

    /// URL loading that reaches this server (and the other fake servers alive).
    var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeServerProtocol.self]
        return configuration
    }

    func on(_ method: String, _ path: String, _ answer: @escaping Answer) {
        lock.withLock { answers[method + " " + path] = answer }
    }

    func on(_ method: String, _ path: String, status: Int = 200, json: Any) {
        nonisolated(unsafe) let json = json
        on(method, path) { _ in (status, json) }
    }

    /// The requests made so far for `method` and `path`, oldest first.
    func requests(_ method: String, _ path: String) -> [Request] {
        lock.withLock { seen.filter { $0.method == method && $0.path == path } }
    }

    /// The first request for `method` and `path`: one already made, else the next.
    func first(_ method: String, _ path: String) async -> Request {
        await withCheckedContinuation { continuation in
            lock.withLock {
                if let made = seen.first(where: { $0.method == method && $0.path == path }) {
                    continuation.resume(returning: made)
                } else {
                    waiting.append((method + " " + path, continuation))
                }
            }
        }
    }

    fileprivate func answer(_ request: Request) -> (status: Int, json: Any) {
        let key = request.method + " " + request.path
        let (answer, ready) = lock.withLock { () -> (Answer?, [CheckedContinuation<Request, Never>]) in
            seen.append(request)
            let ready = waiting.filter { $0.key == key }.map(\.continuation)
            waiting.removeAll { $0.key == key }
            return (answers[key], ready)
        }
        for continuation in ready { continuation.resume(returning: request) }
        return answer?(request) ?? (404, ["error": "not_found"])
    }
}

/// Hands each request to the fake server named by its host.
final class FakeServerProtocol: URLProtocol, @unchecked Sendable {
    static let servers = Mutex<[String: FakeServer]>([:])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host,
              let server = Self.servers.withLock({ $0[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let raw = Self.body(of: request) ?? Data()
        let body = (try? JSONSerialization.jsonObject(with: raw) as? [String: Any]) ?? [:]
        let answer = server.answer(FakeServer.Request(method: request.httpMethod ?? "GET", path: url.path,
                                                      authorization: request.value(forHTTPHeaderField: "Authorization"),
                                                      body: body, raw: raw))
        // An answer of bytes (a file) goes as it is; any other answer as JSON.
        let bytes = answer.json as? Data
        let data = bytes ?? (try? JSONSerialization.data(withJSONObject: answer.json, options: .fragmentsAllowed)) ?? Data()
        let headers = bytes == nil
            ? ["Content-Type": "application/json"]
            : ["Content-Type": "application/octet-stream", "Content-Length": String(data.count)]
        let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1",
                                       headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

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
