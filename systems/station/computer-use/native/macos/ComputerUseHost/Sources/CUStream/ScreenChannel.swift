// A screen view's connection: messages of a kind byte, the payload's length (4 bytes, big-endian), the payload. Ported
// from still.fail (github.com/AFK-surf/still.fail, afk/main b928883a23) station/native/helper/Sources/StillfailHelper/
// Channel.swift: `write`, `send`, `sendJSON`, `read`, `message`. Its JSON lines are not ported: the daemon reads the
// request line itself (CommaComputerUseSocketServer.swift).
import Foundation

public final class ScreenChannel: @unchecked Sendable {
    public let fd: Int32
    private let lock = NSLock()
    public private(set) var broken = false

    public init(fd: Int32) {
        self.fd = fd
    }

    /// All of `data`, or the channel is broken (whoever read it is gone).
    public func write(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        if broken { return }
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var at = 0
            while at < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + at, raw.count - at)
                if n < 0 {
                    if errno == EINTR { continue }
                    broken = true
                    return
                }
                at += n
            }
        }
    }

    public func send(_ kind: UInt8, _ payload: Data) {
        var head = Data([kind])
        var n = UInt32(payload.count).bigEndian
        head.append(Data(bytes: &n, count: 4))
        write(head + payload)
    }

    public func sendJSON(_ kind: UInt8, _ value: [String: Any]) {
        send(kind, (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data("{}".utf8))
    }

    /// Exactly `n` bytes, or nil at the end.
    public func read(_ n: Int) -> Data? {
        var data = Data(count: n)
        var at = 0
        while at < n {
            let got = data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in Darwin.read(fd, raw.baseAddress! + at, n - at) }
            if got < 0 && errno == EINTR { continue }
            if got <= 0 { return nil }
            at += got
        }
        return data
    }

    /// The next message: its kind and payload; nil at the end or for one past `limit`.
    public func message(limit: Int = 1 << 20) -> (UInt8, Data)? {
        guard let head = read(5) else { return nil }
        let length = Int(head[1]) << 24 | Int(head[2]) << 16 | Int(head[3]) << 8 | Int(head[4])
        guard length <= limit else { return nil }
        if length == 0 { return (head[0], Data()) }
        guard let payload = read(length) else { return nil }
        return (head[0], payload)
    }
}
