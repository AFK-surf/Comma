import Foundation

public enum CommaError: Error, Equatable, Sendable, LocalizedError {
    case invalidOrigin, originMismatch, notSignedIn, staleSession, cancelled
    case invalidInput(String), invalidResponse, responseTooLarge, transport
    case credentialStorage(Int32)
    case http(status: Int, code: String, retryAfter: Double?)

    public var errorDescription: String? {
        switch self {
        case .notSignedIn: "Sign in to Comma to continue."
        case .staleSession: "The account changed. Try again in the current account."
        case .cancelled: "The request was cancelled."
        case .invalidOrigin, .originMismatch: "The server address is invalid or changed."
        case .invalidInput(let detail): detail
        case .invalidResponse: "The server returned an invalid response."
        case .responseTooLarge: "The response exceeds the supported size."
        case .transport: "Cannot reach the server. Try again."
        case .credentialStorage: "Secure session storage is unavailable."
        case .http(let status, let code, _):
            switch (status, code) {
            case (_, "push_unavailable"): "Live updates are unavailable on this server."
            case (401, "invalid_verification_code"): "The verification code is invalid or expired."
            case (401, _): "Your session expired. Sign in again."
            case (403, _): "You do not have access to this item."
            case (404, _): "This item is no longer available."
            case (409, _): "This item changed. Refresh and try again."
            case (429, _): "Too many requests. Try again shortly."
            default: "The server could not complete the request."
            }
        }
    }
}

public struct HTTPResponse: Sendable {
    public let data: Data
    public let status: Int
    public let url: URL?
    public let headers: [String: String]
    public init(data: Data, status: Int, url: URL? = nil, headers: [String: String] = [:]) {
        self.data = data; self.status = status; self.url = url; self.headers = headers
    }
}

public struct HTTPStreamResponse: Sendable {
    public let status: Int
    public let url: URL?
    public let headers: [String: String]
    public let chunks: AsyncThrowingStream<Data, any Error>
    private let cancellation: @Sendable () -> Void
    public init(status: Int, url: URL? = nil, headers: [String: String] = [:], chunks: AsyncThrowingStream<Data, any Error>,
                cancel: @escaping @Sendable () -> Void = {}) {
        self.status = status; self.url = url; self.headers = headers; self.chunks = chunks
        self.cancellation = cancel
    }
    public func cancel() { cancellation() }
}

public protocol CommaTransport: Sendable {
    func data(for request: URLRequest) async throws -> HTTPResponse
    func stream(for request: URLRequest) async throws -> HTTPStreamResponse
}

/// A finite SSE connection owns its cancellation. Closing an old handle never cancels a newer connection.
public struct ConversationEventConnection: AsyncSequence, Sendable {
    public typealias Element = ConversationEvent
    private let events: AsyncThrowingStream<ConversationEvent, any Error>
    private let cancellation: @Sendable () -> Void
    init(events: AsyncThrowingStream<ConversationEvent, any Error>, cancel: @escaping @Sendable () -> Void) {
        self.events = events; cancellation = cancel
    }
    public func makeAsyncIterator() -> AsyncThrowingStream<ConversationEvent, any Error>.Iterator { events.makeAsyncIterator() }
    public func cancel() { cancellation() }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

/// Official URLSession transport. A bearer request never follows an HTTP redirect.
public final class URLSessionTransport: CommaTransport, Sendable {
    private let session: URLSession
    private let delegate = NoRedirects()
    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForResource = 60
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    public func data(for request: URLRequest) async throws -> HTTPResponse {
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw CommaError.invalidResponse }
        guard http.expectedContentLength <= 12_000_000 else { throw CommaError.responseTooLarge }
        var data = Data()
        for try await byte in bytes {
            if data.count >= 12_000_000 { throw CommaError.responseTooLarge }
            data.append(byte)
        }
        return HTTPResponse(data: data, status: http.statusCode, url: http.url, headers: Self.headers(http))
    }

    public func stream(for request: URLRequest) async throws -> HTTPStreamResponse {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { bytes.task.cancel(); throw CommaError.invalidResponse }
        let (chunks, continuation) = AsyncThrowingStream<Data, any Error>.makeStream(bufferingPolicy: .bufferingOldest(256))
        let reader = Task {
            defer { bytes.task.cancel() }
            do {
                func deliver(_ chunk: Data) throws -> Bool {
                    switch continuation.yield(chunk) {
                    case .dropped: throw CommaError.responseTooLarge
                    case .terminated: return false
                    case .enqueued: return true
                    @unknown default: return false
                    }
                }
                // Foundation's lines sequence skips blank lines, which are SSE event boundaries.
                // Keep raw LF/CRLF and UTF-8 bytes; yield complete bounded lines rather than each byte.
                var line = Data()
                for try await byte in bytes {
                    try Task.checkCancellation()
                    line.append(byte)
                    if byte == 10 {
                        let terminatorCount = line.dropLast().last == 13 ? 2 : 1
                        guard line.count - terminatorCount <= 1_048_576 else { throw CommaError.responseTooLarge }
                        guard try deliver(line) else { return }
                        line.removeAll(keepingCapacity: true)
                    } else {
                        // A trailing CR may still be part of a CRLF terminator.
                        guard line.count <= 1_048_576 + (byte == 13 ? 1 : 0) else { throw CommaError.responseTooLarge }
                    }
                }
                if !line.isEmpty, try !deliver(line) { return }
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
        let cancel: @Sendable () -> Void = { bytes.task.cancel(); reader.cancel() }
        continuation.onTermination = { @Sendable _ in cancel() }
        return HTTPStreamResponse(status: http.statusCode, url: http.url, headers: Self.headers(http), chunks: chunks, cancel: cancel)
    }

    private static func headers(_ response: HTTPURLResponse) -> [String: String] {
        var values: [String: String] = [:]
        for (key, value) in response.allHeaderFields { values[String(describing: key).lowercased()] = String(describing: value) }
        return values
    }
}

public struct SSEFrame: Equatable, Sendable {
    public let event: String
    public let data: Data
}

/// URLSession supplies the byte stream, but Foundation has no SSE/EventSource decoder.
/// This isolated framing adapter covers the finite Comma stream without another networking stack.
/// No last-event-ID or replay promise. Each connection starts from its server snapshot.
public struct SSEParser: Sendable {
    private var bytes = Data()
    private var dataLines: [Data] = []
    private var event = "message"
    private var frameBytes = 0
    public init() {}

    public mutating func append(_ chunk: Data) throws -> [SSEFrame] {
        bytes.append(chunk)
        guard bytes.count + frameBytes <= 2_097_152 else { throw CommaError.responseTooLarge }
        var frames: [SSEFrame] = []
        while let boundary = bytes.firstIndex(of: 10) {
            var line = Data(bytes[..<boundary])
            bytes.removeSubrange(...boundary)
            if line.last == 13 { line.removeLast() }
            if let frame = try process(line) { frames.append(frame) }
        }
        return frames
    }

    public mutating func finish() throws -> [SSEFrame] {
        // SSE only dispatches at a blank-line boundary. A truncated tail has no event authority.
        bytes.removeAll(); dataLines.removeAll(); frameBytes = 0; event = "message"
        return []
    }

    private mutating func process(_ line: Data) throws -> SSEFrame? {
        if line.isEmpty {
            defer { dataLines.removeAll(); event = "message"; frameBytes = 0 }
            guard !dataLines.isEmpty else { return nil }
            return SSEFrame(event: event, data: dataLines.reduce(into: Data()) { result, line in
                if !result.isEmpty { result.append(10) }; result.append(line)
            })
        }
        guard let text = String(data: line, encoding: .utf8) else { throw CommaError.invalidResponse }
        if text.hasPrefix(":") { return nil }
        let split = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        var value = split.count > 1 ? String(split[1]) : ""
        if value.hasPrefix(" ") { value.removeFirst() }
        if split[0] == "event" { event = value }
        if split[0] == "data" {
            frameBytes += value.utf8.count
            guard frameBytes <= 2_097_152 else { throw CommaError.responseTooLarge }
            dataLines.append(Data(value.utf8))
        }
        return nil
    }
}
