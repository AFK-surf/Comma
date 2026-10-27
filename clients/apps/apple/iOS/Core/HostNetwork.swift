import CryptoKit
import Foundation

/// A response's status and headers (names in lower case), as the core reads them.
struct ResponseHead: Sendable {
    let status: Int
    let headers: [(String, String)]
    /// The body's declared length, when the server said it.
    let length: Int64?

    var json: [String: Any] { ["status": status, "headers": headers.map { [$0.0, $0.1] }] }
}

/**
 * One response read as it arrives: its head once it came, then its body in the chunks the network gave. A response
 * nobody reads holds the network back once it has kept 1 MB. Redirects are not followed: a 3xx is the answer.
 */
final class ResponseStream: @unchecked Sendable {
    private static let held = 1 << 20

    fileprivate let task: URLSessionDataTask
    private let lock = NSLock()
    private var head: Result<ResponseHead, any Error>?
    private var headWaiters: [CheckedContinuation<ResponseHead, any Error>] = []
    private var chunks: [Data] = []
    private var buffered = 0
    private var ended: (any Error)??
    private var reader: CheckedContinuation<Data?, any Error>?
    private var suspended = false

    fileprivate init(task: URLSessionDataTask) { self.task = task }

    /// The response's head, once it came.
    func response() async throws -> ResponseHead {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let head {
                lock.unlock()
                continuation.resume(with: head)
            } else {
                headWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    /// What has arrived, at least one byte; nil at the body's end.
    func read() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if !chunks.isEmpty {
                let data = chunks.count == 1 ? chunks[0] : chunks.reduce(into: Data()) { $0.append($1) }
                chunks.removeAll()
                buffered = 0
                let resume = suspended
                suspended = false
                lock.unlock()
                if resume { task.resume() }
                continuation.resume(returning: data)
            } else if let ended {
                lock.unlock()
                if let error = ended { continuation.resume(throwing: error) } else { continuation.resume(returning: nil) }
            } else {
                reader = continuation
                lock.unlock()
            }
        }
    }

    /// The whole body.
    func body() async throws -> Data {
        var out = Data()
        while let chunk = try await read() { out.append(chunk) }
        return out
    }

    func cancel() { task.cancel() }

    fileprivate func received(_ response: URLResponse) {
        let http = response as? HTTPURLResponse
        let headers = (http?.allHeaderFields ?? [:]).compactMap { key, value -> (String, String)? in
            guard let name = key as? String else { return nil }
            return (name.lowercased(), "\(value)")
        }
        let value = ResponseHead(status: http?.statusCode ?? 0, headers: headers,
                                 length: response.expectedContentLength >= 0 ? response.expectedContentLength : nil)
        settleHead(.success(value))
    }

    private func settleHead(_ result: Result<ResponseHead, any Error>) {
        lock.lock()
        guard head == nil else { lock.unlock(); return }
        head = result
        let waiters = headWaiters
        headWaiters.removeAll()
        lock.unlock()
        for waiter in waiters { waiter.resume(with: result) }
    }

    fileprivate func received(_ data: Data) {
        lock.lock()
        if let reader {
            self.reader = nil
            lock.unlock()
            reader.resume(returning: data)
            return
        }
        chunks.append(data)
        buffered += data.count
        let hold = buffered >= Self.held && !suspended
        if hold { suspended = true }
        lock.unlock()
        if hold { task.suspend() }
    }

    fileprivate func finished(_ error: (any Error)?) {
        settleHead(.failure(error ?? URLError(.badServerResponse)))
        lock.lock()
        ended = .some(error)
        let reader = self.reader
        self.reader = nil
        lock.unlock()
        if let reader {
            if let error { reader.resume(throwing: error) } else { reader.resume(returning: nil) }
        }
    }
}

/// The session every request of the core goes out on, which tells each `ResponseStream` what arrives for it.
final class StreamSession: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var streams: [Int: ResponseStream] = [:]
    private var session: URLSession!

    init(configuration: URLSessionConfiguration) {
        super.init()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "comma-core-network"
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    /// Starts `request`, its body the file `upload` when given (sent from disk as it is read); its answer is read
    /// from the stream.
    func start(_ request: URLRequest, upload: URL? = nil) -> ResponseStream {
        let task = upload.map { session.uploadTask(with: request, fromFile: $0) } ?? session.dataTask(with: request)
        let stream = ResponseStream(task: task)
        lock.withLock { streams[task.taskIdentifier] = stream }
        task.resume()
        return stream
    }

    private func stream(_ task: URLSessionTask) -> ResponseStream? { lock.withLock { streams[task.taskIdentifier] } }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        stream(dataTask)?.received(response)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        stream(dataTask)?.received(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let stream = lock.withLock { streams.removeValue(forKey: task.taskIdentifier) }
        stream?.finished(error)
    }
}

/**
 * The client core's downloads (`DownloadPorts` in the core's phone host), as `HostDownloads.kt` is Android's: files of
 * any size written from the network straight to `root`, or from the parts the core reads itself (a file of a Task a
 * station hosts), each under the path the core names. A file takes its place only once its body is whole; until then
 * it is a partial file beside it, removed when the download is given up. The core decides what is downloaded, kept and
 * removed; this class moves the bytes.
 */
final class HostDownloads: @unchecked Sendable {
    /** A file being written: from a `stream`, or from the core's parts when it has none. */
    private final class Download {
        let stream: ResponseStream?
        let target: URL
        let partial: URL
        let out: FileHandle
        let declared: Int64?
        var digest = SHA256()
        var received: Int64 = 0
        init(stream: ResponseStream?, target: URL, partial: URL, out: FileHandle, declared: Int64?) {
            self.stream = stream; self.target = target; self.partial = partial; self.out = out; self.declared = declared
        }
    }

    private static let chunk = 64 * 1024

    let root: URL
    private let lock = NSLock()
    private var open: [Int: Download] = [:]
    private var next = 1

    init(root: URL) { self.root = root }

    /// The file at `path` under `root`; nil for a path that leaves it.
    func file(_ path: String) -> URL? {
        let file = root.appendingPathComponent(path).standardizedFileURL
        let base = root.standardizedFileURL.path + "/"
        return file.path.hasPrefix(base) ? file : nil
    }

    /// A 200 answer begins writing to `path`: its id.
    func begin(_ stream: ResponseStream, head: ResponseHead, path: String) throws -> Int {
        try start(stream, declared: head.length, path: path)
    }

    /// Begins writing a file the core reads itself a part at a time to `path`: its id.
    func create(_ path: String) throws -> Int {
        try start(nil, declared: nil, path: path)
    }

    /// Writes the core's next part of the file `id`: how much is written so far.
    func append(_ id: Int, _ bytes: Data) throws -> [String: Any] {
        guard let download = lock.withLock({ open[id] }) else { throw HostFailure(message: "No such download.") }
        do {
            try download.out.write(contentsOf: bytes)
            download.digest.update(data: bytes)
            download.received += Int64(bytes.count)
            return ["received": download.received]
        } catch {
            close(id)
            throw error
        }
    }

    /// The core's file `id` is whole: in place, with its size and SHA-256.
    func finish(_ id: Int) throws -> [String: Any] {
        guard let download = lock.withLock({ open[id] }) else { throw HostFailure(message: "No such download.") }
        return try finish(id, download)
    }

    private func start(_ stream: ResponseStream?, declared: Int64?, path: String) throws -> Int {
        guard let target = file(path) else { throw HostFailure(message: "The path leaves the download directory.") }
        let directory = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = lock.withLock { () -> Int in
            defer { next += 1 }
            return next
        }
        let partial = directory.appendingPathComponent(".\(target.lastPathComponent).partial-\(id)")
        guard FileManager.default.createFile(atPath: partial.path, contents: nil) else {
            throw HostFailure(message: "Cannot make the download's file.")
        }
        let out = try FileHandle(forWritingTo: partial)
        lock.withLock { open[id] = Download(stream: stream, target: target, partial: partial, out: out, declared: declared) }
        return id
    }

    /**
     * Writes what arrives, at least 64 KB unless the body ends: how much is written, or once the body is whole the file
     * in place with its size and SHA-256.
     */
    func step(_ id: Int, current: () -> Bool) async throws -> [String: Any] {
        guard let download = lock.withLock({ open[id] }) else { throw HostFailure(message: "No such download.") }
        do {
            var read = 0
            while read < Self.chunk {
                guard current() else { throw HostFailure(message: "The session ended.") }
                guard let stream = download.stream else { throw HostFailure(message: "The download has no answer.") }
                guard let data = try await stream.read() else { return try finish(id, download) }
                try download.out.write(contentsOf: data)
                download.digest.update(data: data)
                download.received += Int64(data.count)
                read += data.count
            }
            return ["received": download.received]
        } catch {
            close(id)
            throw error
        }
    }

    private func finish(_ id: Int, _ download: Download) throws -> [String: Any] {
        lock.withLock { open[id] = nil }
        try? download.out.close()
        let fileManager = FileManager.default
        if let declared = download.declared, declared != download.received {
            try? fileManager.removeItem(at: download.partial)
            throw HostFailure(message: "The answer broke off.")
        }
        do {
            if fileManager.fileExists(atPath: download.target.path) { try fileManager.removeItem(at: download.target) }
            try fileManager.moveItem(at: download.partial, to: download.target)
        } catch {
            try? fileManager.removeItem(at: download.partial)
            throw HostFailure(message: "Cannot put the download in place.")
        }
        let hash = download.digest.finalize().map { String(format: "%02x", $0) }.joined()
        return ["size": download.received, "sha256": hash]
    }

    /// Gives a download up: nothing of it stays.
    func close(_ id: Int) {
        guard let download = lock.withLock({ open.removeValue(forKey: id) }) else { return }
        try? download.out.close()
        download.stream?.cancel()
        try? FileManager.default.removeItem(at: download.partial)
    }

    func closeAll() {
        for id in lock.withLock({ Array(open.keys) }) { close(id) }
    }

    func remove(_ path: String) {
        guard let file = file(path) else { return }
        try? FileManager.default.removeItem(at: file)
    }

    /// Removes every top-level directory but `keep`; everything when it is nil.
    func retain(_ keep: String?) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for name in names where name != keep {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(name))
        }
    }
}
