import Foundation

public enum VoiceTransportFailureStage: String, Sendable {
    case httpOpen = "http_open"
    case httpUpload = "http_upload"
    case httpDownlink = "http_downlink"
    case httpIdle = "http_downlink_idle"
    case httpDecode = "http_decode"
}

public enum VoiceSocketEvent: Sendable, Equatable {
    case opened(subprotocol: String?)
    case text(String)
    case binary(Data)
    /// `code` is nil when the platform reports no close code.
    case closed(code: Int?, reason: String)
    /// `status` is the HTTP status of a refused upgrade, when there was one; `code` the platform's error code
    /// (`URLError`), for local diagnostics.
    case failed(status: Int?, code: Int? = nil, stage: VoiceTransportFailureStage? = nil)
}

/// One `comma.voice.v1` connection. At most one terminal event (`closed` or `failed`) is delivered.
public protocol VoiceSocket: AnyObject, Sendable {
    /// False once the socket is closing or closed.
    func send(text: String) -> Bool
    func send(audio: Data) -> Bool
    /// Bytes handed to the socket and not yet written to the network.
    var queuedBytes: Int { get }
    /// Skip the next microphone frame while congested; control messages must still be sent.
    var isAudioBackpressured: Bool { get }
    /// A normal (1000) close.
    func close()
    /// Immediate teardown; no further events.
    func cancel()
}

public extension VoiceSocket {
    var isAudioBackpressured: Bool { queuedBytes > VoiceSession.maxQueuedUplinkBytes }
}

public protocol VoiceTransport: Sendable {
    /// Throws `VoiceFailure` unless the voice service is ready and the Group has no call.
    func readiness(_ endpoint: VoiceEndpoint) async throws
    func connect(_ endpoint: VoiceEndpoint, events: @escaping @Sendable (VoiceSocketEvent) -> Void) -> any VoiceSocket
}

/// Foundation's WebSocket client: it reports a refused upgrade's HTTP status, which tells an expired
/// key (401) from other refusals. Custom close codes may arrive without their number; the server's
/// `error` and `session.ended` messages, and the close reason, carry the cause instead.
public struct URLSessionVoiceTransport: VoiceTransport {
    public init() {}

    public func readiness(_ endpoint: VoiceEndpoint) async throws {
        var request = URLRequest(url: endpoint.readinessURL, timeoutInterval: 10)
        request.setValue("Bearer " + endpoint.bearer, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let delegate = VoiceNoRedirects()
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw VoiceFailure(.interrupted, networkCode: (error as? URLError)?.code.rawValue) }
        guard let http = response as? HTTPURLResponse else { throw VoiceFailure(.interrupted) }
        let json = data.count <= VoiceProtocol.maxFrameBytes ? (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] : nil
        guard (200..<300).contains(http.statusCode) else {
            let result = VoiceProtocol.result(code: http.statusCode, reason: json?["error"] as? String)
            throw VoiceFailure(result == .ended ? .unavailable : result)
        }
        guard let json else { throw VoiceFailure(.unavailable) }
        guard json["ready"] as? Bool == true else { throw VoiceFailure(VoiceProtocol.result(code: 503, reason: json["reason"] as? String)) }
        if json["busy"] as? Bool == true { throw VoiceFailure(.busy) }
    }

    public func connect(_ endpoint: VoiceEndpoint, events: @escaping @Sendable (VoiceSocketEvent) -> Void) -> any VoiceSocket {
        let socket = URLSessionVoiceSocket(events: events)
        socket.start(endpoint)
        return socket
    }
}

private final class VoiceNoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

final class URLSessionVoiceSocket: NSObject, VoiceSocket, URLSessionWebSocketDelegate, @unchecked Sendable {
    private static let pingInterval: TimeInterval = 15
    /// The upgrade must finish within this; afterwards only pongs bound the connection.
    private static let handshakeTimeout: TimeInterval = 10
    /// Foundation applies a task's request timeout to idle reads too: a quiet agent sends no frames for many
    /// seconds, so the platform timeout is effectively off and the handshake deadline and pongs replace it.
    private static let idleTimeout: TimeInterval = 24 * 60 * 60
    private let lock = NSLock()
    private let events: @Sendable (VoiceSocketEvent) -> Void
    private let delegateQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var queued = 0
    private var closing = false
    private var finished = false
    private var awaitingPong = false
    private var opened = false
    private var ping: DispatchSourceTimer?

    init(events: @escaping @Sendable (VoiceSocketEvent) -> Void) { self.events = events }

    func start(_ endpoint: VoiceEndpoint) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.idleTimeout
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
        var request = URLRequest(url: endpoint.sessionsURL, timeoutInterval: Self.idleTimeout)
        request.setValue("Bearer " + endpoint.bearer, forHTTPHeaderField: "Authorization")
        request.setValue(VoiceProtocol.subprotocol, forHTTPHeaderField: "Sec-WebSocket-Protocol")
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = VoiceProtocol.maxFrameBytes
        lock.withLock { self.session = session; self.task = task }
        task.resume()
        receive(task)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.handshakeTimeout) { [weak self, weak task] in
            guard let self, self.lock.withLock({ !self.opened && !self.finished }) else { return }
            self.finish(.failed(status: nil, code: URLError.timedOut.rawValue))
            task?.cancel()
        }
    }

    var queuedBytes: Int { lock.withLock { queued } }

    func send(text: String) -> Bool { send(.string(text), bytes: text.utf8.count) }
    func send(audio: Data) -> Bool { send(.data(audio), bytes: audio.count) }

    private func send(_ message: URLSessionWebSocketTask.Message, bytes: Int) -> Bool {
        let open: URLSessionWebSocketTask? = lock.withLock {
            guard !finished, !closing, let task = self.task else { return nil }
            queued += bytes
            return task
        }
        guard let task = open else { return false }
        task.send(message) { [weak self] error in
            guard let self else { return }
            self.lock.withLock { self.queued -= bytes }
            if let error { self.finish(.failed(status: nil, code: (error as NSError).code)) }
        }
        return true
    }

    func close() {
        let task: URLSessionWebSocketTask? = lock.withLock {
            guard !finished, !closing else { return nil }
            closing = true
            return self.task
        }
        task?.cancel(with: .normalClosure, reason: nil)
    }

    func cancel() {
        let (task, session, ping): (URLSessionWebSocketTask?, URLSession?, DispatchSourceTimer?) = lock.withLock {
            finished = true
            defer { self.task = nil; self.session = nil; self.ping = nil }
            return (self.task, self.session, self.ping)
        }
        ping?.cancel()
        task?.cancel()
        session?.invalidateAndCancel()
    }

    private func receive(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.string(let text)):
                if self.deliver(.text(text)) { self.receive(task) }
            case .success(.data(let data)):
                if self.deliver(.binary(data)) { self.receive(task) }
            case .success:
                self.receive(task)
            case .failure(let error):
                if task.closeCode != .invalid {
                    self.finish(.closed(code: task.closeCode.rawValue, reason: Self.reason(task.closeReason)))
                } else {
                    self.finish(.failed(status: (task.response as? HTTPURLResponse)?.statusCode, code: (error as NSError).code))
                }
            }
        }
    }

    /// False once finished, so a late message after the terminal event is dropped.
    private func deliver(_ event: VoiceSocketEvent) -> Bool {
        guard lock.withLock({ !finished }) else { return false }
        events(event)
        return true
    }

    private func finish(_ event: VoiceSocketEvent) {
        let resources: (session: URLSession?, ping: DispatchSourceTimer?)? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            defer { self.task = nil; self.session = nil; self.ping = nil }
            return (self.session, self.ping)
        }
        guard let resources else { return }
        resources.ping?.cancel()
        events(event)
        resources.session?.invalidateAndCancel()
    }

    private static func reason(_ data: Data?) -> String {
        guard let data, data.count <= 123 else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private func startPing(_ task: URLSessionWebSocketTask) {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + Self.pingInterval, repeating: Self.pingInterval)
        timer.setEventHandler { [weak self, weak task] in
            guard let self, let task else { return }
            // No pong within one interval: the link is dead even if TCP has not noticed.
            let missed = self.lock.withLock { () -> Bool in
                if self.awaitingPong { return true }
                self.awaitingPong = true
                return false
            }
            if missed { self.finish(.failed(status: nil, code: URLError.timedOut.rawValue)); task.cancel(); return }
            task.sendPing { [weak self] error in
                guard let self else { return }
                if error == nil { self.lock.withLock { self.awaitingPong = false } }
            }
        }
        let keep = lock.withLock { () -> Bool in
            guard !finished else { return false }
            ping = timer
            return true
        }
        if keep { timer.resume() }
    }

    // MARK: URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol subprotocol: String?) {
        lock.withLock { opened = true }
        guard deliver(.opened(subprotocol: subprotocol)) else { return }
        startPing(webSocketTask)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        finish(.closed(code: closeCode == .invalid ? nil : closeCode.rawValue, reason: Self.reason(reason)))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let socket = task as? URLSessionWebSocketTask else { return }
        if socket.closeCode != .invalid {
            finish(.closed(code: socket.closeCode.rawValue, reason: Self.reason(socket.closeReason)))
        } else {
            finish(.failed(status: (task.response as? HTTPURLResponse)?.statusCode, code: (error as NSError?)?.code))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
