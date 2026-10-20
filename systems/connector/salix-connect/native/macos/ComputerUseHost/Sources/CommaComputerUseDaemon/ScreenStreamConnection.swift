import CUStream
import Darwin
import Foundation

/// Serves one screen stream on a daemon socket connection.
///
/// After the request line, both directions carry frames:
/// one type byte, a 4-byte big-endian payload length, then the payload.
/// The connection lifetime is the stream lifetime.
@available(macOS 14.0, *)
final class ScreenStreamConnection: @unchecked Sendable {
    private enum FrameType: UInt8 {
        /// Daemon to client: flags byte, 8-byte big-endian pts in microseconds, Annex-B H.264.
        case video = 1
        /// Either direction: one JSON object.
        case json = 2
    }

    private let socket: Int32
    private let writeLock = NSLock()

    init(socket: Int32) {
        self.socket = socket
    }

    /// Runs the stream until the client closes the connection or capture ends.
    func run(options: ScreenStreamOptions) {
        var noTimeout = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &noTimeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        let session = ScreenStreamSession(options: options)
        session.onVideo = { [weak self] flags, pts, data in
            var header = Data([flags])
            withUnsafeBytes(of: pts.bigEndian) { header.append(contentsOf: $0) }
            self?.write(.video, header + data)
        }
        session.onMeta = { [weak self] meta in
            self?.writeJSON(meta)
            if meta["type"] as? String == "ended" {
                self.map { _ = shutdown($0.socket, SHUT_RDWR) }
            }
        }

        let started = DispatchSemaphore(value: 0)
        let failure = FailureBox()
        Task.detached {
            do {
                try await session.start()
            } catch {
                failure.set("\(error)")
            }
            started.signal()
        }
        started.wait()
        if let message = failure.get() {
            writeJSON(["type": "error", "error": message])
            return
        }
        defer { session.stop() }

        while let (type, payload) = readFrame() {
            guard
                type == FrameType.json.rawValue,
                let message = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
            else { continue }
            switch message["type"] as? String {
            case "keyframe": session.requestKeyframe()
            case "stop": return
            default: session.handleInput(message)
            }
        }
    }

    private func writeJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        write(.json, data)
    }

    private func write(_ type: FrameType, _ payload: Data) {
        var frame = Data([type.rawValue])
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { frame.append(contentsOf: $0) }
        frame.append(payload)
        writeLock.lock()
        defer { writeLock.unlock() }
        frame.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(socket, buffer.baseAddress! + offset, buffer.count - offset)
                if written <= 0 { return }
                offset += written
            }
        }
    }

    private func readFrame() -> (UInt8, Data)? {
        guard let header = readExactly(5) else { return nil }
        let length = header.dropFirst().reduce(0) { ($0 << 8) | Int($1) }
        guard length <= 1 << 20, let payload = readExactly(length) else { return nil }
        return (header[0], payload)
    }

    private func readExactly(_ count: Int) -> Data? {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let received = data.withUnsafeMutableBytes { read(socket, $0.baseAddress! + offset, count - offset) }
            if received <= 0 { return nil }
            offset += received
        }
        return data
    }
}

private final class FailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    func set(_ value: String) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func get() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
