import Foundation

/// HTTPS streaming downlink and bounded uploads to the authenticated voice backend.
public struct HTTPVoiceTransport: VoiceTransport {
    public init() {}

    public func readiness(_ endpoint: VoiceEndpoint) async throws {
        try await URLSessionVoiceTransport().readiness(endpoint)
    }

    public func connect(_ endpoint: VoiceEndpoint, events: @escaping @Sendable (VoiceSocketEvent) -> Void) -> any VoiceSocket {
        let socket = HTTPVoiceSocket(endpoint: endpoint, events: events)
        socket.start()
        return socket
    }
}

/// One byte of type and four bytes of big-endian length. TCP/HTTP chunks are not message boundaries.
struct HTTPVoiceFraming {
    private var pending = Data()

    static func encode(_ kind: UInt8, _ data: Data) -> Data {
        var size = UInt32(data.count).bigEndian
        var result = Data([kind])
        withUnsafeBytes(of: &size) { result.append(contentsOf: $0) }
        result.append(data)
        return result
    }

    mutating func receive(_ data: Data, frame: (UInt8, Data) throws -> Void) throws {
        // Limit parser storage even when Foundation coalesces many frames into one callback.
        var remaining = data[...]
        while !remaining.isEmpty {
            let count = min(remaining.count, VoiceProtocol.maxFrameBytes)
            pending.append(contentsOf: remaining.prefix(count))
            remaining = remaining.dropFirst(count)
            while pending.count >= 5 {
                let header = Array(pending.prefix(5))
                let size = header[1...4].reduce(0) { ($0 << 8) | Int($1) }
                guard (1...5).contains(header[0]), size <= VoiceProtocol.maxFrameBytes else { throw VoiceFailure(.interrupted) }
                guard pending.count >= size + 5 else { break }
                let payload = Data(pending.dropFirst(5).prefix(size))
                pending = Data(pending.dropFirst(size + 5))
                try frame(header[0], payload)
            }
        }
    }
}

private final class HTTPVoiceSocket: NSObject, VoiceSocket, URLSessionDataDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "surf.comma.voice.http")
    private let streamURL: URL
    private let endpoint: VoiceEndpoint
    private let events: @Sendable (VoiceSocketEvent) -> Void
    private var session: URLSession?
    private var stream: URLSessionDataTask?
    private var upload: URLSessionDataTask?
    private var inputURL: URL?
    private var parser = HTTPVoiceFraming()
    private var outgoing = Data()
    private var inFlightBytes = 0
    private var sequence = 0
    private var finished = false
    private var receivedAt = DispatchTime.now().uptimeNanoseconds
    private var timer: DispatchSourceTimer?
    private var ownerNode: String?

    init(endpoint: VoiceEndpoint, events: @escaping @Sendable (VoiceSocketEvent) -> Void) {
        self.endpoint = endpoint
        self.events = events
        self.streamURL = endpoint.readinessURL.appendingPathComponent("http")
    }

    func start() {
        queue.async { [self] in
            guard !finished else { return }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 45
            configuration.timeoutIntervalForResource = 4 * 60 * 60 + 60
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            self.session = session
            var request = request(streamURL, method: "POST")
            request.httpBody = Data()
            let task = session.dataTask(with: request)
            stream = task
            task.resume()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
            timer.setEventHandler { [weak self] in
                guard let self, !self.finished else { return }
                let limit: UInt64 = self.inputURL == nil ? 10_000_000_000 : 45_000_000_000
                if DispatchTime.now().uptimeNanoseconds - self.receivedAt > limit {
                    self.fail(stage: self.inputURL == nil ? .httpOpen : .httpIdle, code: URLError.timedOut.rawValue)
                } else { self.flush() }
            }
            self.timer = timer
            timer.resume()
        }
    }

    var queuedBytes: Int { queue.sync { outgoing.count + inFlightBytes } }
    var isAudioBackpressured: Bool {
        queue.sync {
            // Reserve room for playback receipts and hang-up. A closed transport must still reject send.
            !finished && outgoing.count + inFlightBytes + VoiceProtocol.frameBytes + 5 > 28 * 1024
        }
    }
    func send(text: String) -> Bool { enqueue(1, Data(text.utf8), immediate: true) }
    func send(audio: Data) -> Bool { enqueue(2, audio, immediate: false) }

    private func enqueue(_ kind: UInt8, _ data: Data, immediate: Bool) -> Bool {
        queue.sync {
            guard !finished, inputURL != nil, data.count <= VoiceProtocol.maxFrameBytes else { return false }
            let frame = HTTPVoiceFraming.encode(kind, data)
            // At most 32 KB, including one outstanding POST. The pacer skips new audio before this bound.
            guard outgoing.count + inFlightBytes + frame.count <= 32 * 1024 else { return false }
            outgoing.append(frame)
            if immediate { flush() }
            return true
        }
    }

    private func request(_ url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer " + endpoint.bearer, forHTTPHeaderField: "Authorization")
        request.setValue("application/x-comma-voice", forHTTPHeaderField: "Content-Type")
        if let ownerNode { request.setValue(ownerNode, forHTTPHeaderField: "X-Voice-Node") }
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    private func flush() {
        guard !finished, upload == nil, !outgoing.isEmpty, let inputURL, let session else { return }
        var request = request(inputURL, method: "POST")
        request.timeoutInterval = 5
        request.setValue(String(sequence), forHTTPHeaderField: "X-Voice-Sequence")
        request.httpBody = outgoing
        inFlightBytes = outgoing.count
        outgoing.removeAll(keepingCapacity: true)
        let task = session.dataTask(with: request) { [weak self] _, response, error in
            guard let self else { return }
            self.queue.async {
                guard !self.finished else { return }
                self.upload = nil
                self.inFlightBytes = 0
                guard error == nil, (response as? HTTPURLResponse)?.statusCode == 204 else {
                    self.fail(stage: .httpUpload, status: (response as? HTTPURLResponse)?.statusCode, code: (error as NSError?)?.code)
                    return
                }
                self.sequence += 1
                // Catch up only one bounded batch at a time; never retry a POST with an unknown outcome.
                if self.outgoing.count >= 5 * (VoiceProtocol.frameBytes + 5) { self.flush() }
            }
        }
        upload = task
        task.resume()
    }

    func close() { cancel() }
    func cancel() { queue.async { [self] in finish() } }

    private func fail(stage: VoiceTransportFailureStage, status: Int? = nil, code: Int? = nil) {
        guard !finished else { return }
        events(.failed(status: status, code: code, stage: stage))
        finish()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        timer?.cancel(); timer = nil
        stream?.cancel(); stream = nil
        upload?.cancel(); upload = nil
        outgoing.removeAll(); inFlightBytes = 0
        // DELETE ends the carrier promptly even when a proxy buffers stream cancellation.
        if let inputURL, let session {
            var request = request(inputURL, method: "DELETE")
            request.timeoutInterval = 3
            session.dataTask(with: request).resume()
        }
        session?.finishTasksAndInvalidate(); session = nil
    }

    private func receive(_ kind: UInt8, _ data: Data) throws {
        guard !finished else { return }
        switch kind {
        case 3:
            struct Ready: Decodable { let handle: String; let node: String }
            let ready = try JSONDecoder().decode(Ready.self, from: data)
            guard inputURL == nil, ready.handle.utf8.count == 32,
                  ready.handle.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  !ready.node.isEmpty, ready.node.utf8.count <= 255,
                  ready.node.utf8.allSatisfy({ (33...126).contains($0) }) else {
                throw VoiceFailure(.interrupted)
            }
            ownerNode = ready.node
            inputURL = streamURL.appendingPathComponent(ready.handle)
            events(.opened(subprotocol: VoiceProtocol.subprotocol))
        case 1:
            guard inputURL != nil, let text = String(data: data, encoding: .utf8) else { throw VoiceFailure(.interrupted) }
            events(.text(text))
        case 2:
            guard inputURL != nil, VoiceProtocol.validAudio(data.count) else { throw VoiceFailure(.interrupted) }
            events(.binary(data))
        case 4:
            struct End: Decodable { let code: Int; let reason: String }
            let end = try JSONDecoder().decode(End.self, from: data)
            events(.closed(code: end.code, reason: end.reason))
            finish()
        case 5: break
        default: throw VoiceFailure(.interrupted)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        queue.async { [self] in
            guard !finished else { completionHandler(.cancel); return }
            let response = response as? HTTPURLResponse
            guard response?.statusCode == 200, response?.mimeType == "application/x-comma-voice" else {
                completionHandler(.cancel)
                fail(stage: .httpOpen, status: response?.statusCode)
                return
            }
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        queue.async { [self] in
            guard !finished else { return }
            receivedAt = DispatchTime.now().uptimeNanoseconds
            do {
                // Avoid overlapping access to self.parser while receive may finish the connection.
                var parser = self.parser
                try parser.receive(data) { try receive($0, $1) }
                self.parser = parser
            } catch { fail(stage: .httpDecode, code: URLError.cannotParseResponse.rawValue) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        queue.async { [self] in
            guard task === stream, !finished else { return }
            fail(stage: inputURL == nil ? .httpOpen : .httpDownlink,
                 code: (error as NSError?)?.code ?? URLError.networkConnectionLost.rawValue)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
