import Darwin
import XCTest
@testable import CommaComputerUseDaemon

/// A connector that cannot reach its daemon starts another one on the same socket path. The replaced daemon must see
/// that and end, and must not remove the socket of the daemon that replaced it.
final class SocketOwnershipTests: XCTestCase {
    func testAReplacedDaemonLearnsItLostItsSocketAndLeavesTheNewOne() throws {
        let directory = "/tmp/cu-own-\(getpid())-\(#line)"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = "\(directory)/cu.sock"

        let old = CommaComputerUseSocketServer(socketPath: path, authToken: "old", ownershipInterval: .seconds(3600))
        var oldLost = 0
        old.onSocketLost = { oldLost += 1 }
        try old.start()
        old.checkOwnership()
        XCTAssertEqual(oldLost, 0, "a daemon that still owns its socket keeps running")

        let replacement = CommaComputerUseSocketServer(socketPath: path, authToken: "new", ownershipInterval: .seconds(3600))
        var replacementLost = 0
        replacement.onSocketLost = { replacementLost += 1 }
        try replacement.start()

        old.checkOwnership()
        old.checkOwnership()
        replacement.checkOwnership()
        XCTAssertEqual(oldLost, 1, "the replaced daemon learns it once")
        XCTAssertEqual(replacementLost, 0)

        old.stop()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "the replaced daemon leaves the new socket")
        replacement.checkOwnership()
        XCTAssertEqual(replacementLost, 0)

        replacement.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testARemovedSocketPathEndsTheDaemon() throws {
        let directory = "/tmp/cu-own-\(getpid())-\(#line)"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = "\(directory)/cu.sock"
        let server = CommaComputerUseSocketServer(socketPath: path, authToken: "t", ownershipInterval: .seconds(3600))
        var lost = 0
        server.onSocketLost = { lost += 1 }
        try server.start()
        defer { server.stop() }

        unlink(path)
        server.checkOwnership()
        XCTAssertEqual(lost, 1)
    }

    func testOwnershipTimerFiresOffMainThreadWhenSocketIsReplaced() throws {
        let directory = "/tmp/cu-own-\(getpid())-\(#line)"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = "\(directory)/cu.sock"

        let old = CommaComputerUseSocketServer(socketPath: path, authToken: "old", ownershipInterval: .milliseconds(20))
        let lost = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var lostCount = 0
        var firedOnMainThread = false
        old.onSocketLost = {
            lock.lock()
            lostCount += 1
            firedOnMainThread = firedOnMainThread || Thread.isMainThread
            lock.unlock()
            lost.signal()
        }
        try old.start()

        let replacement = CommaComputerUseSocketServer(socketPath: path, authToken: "new", ownershipInterval: .seconds(3600))
        try replacement.start()

        lost.wait()
        old.checkOwnership()
        lock.lock()
        XCTAssertEqual(lostCount, 1)
        XCTAssertFalse(firedOnMainThread)
        lock.unlock()

        old.stop()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "the replaced daemon leaves the new socket")
        replacement.stop()
    }

    func testHelloAndShutdownDoNotWaitOnABusyMainActorHandler() throws {
        XCTAssertTrue(Thread.isMainThread, "XCTest holds the main thread for the whole test")
        let directory = "/tmp/cu-own-\(getpid())-\(#line)"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = "\(directory)/cu.sock"

        let server = CommaComputerUseSocketServer(socketPath: path, authToken: "secret", ownershipInterval: .seconds(3600))
        let shutdownCalled = DispatchSemaphore(value: 0)
        server.onShutdownRequested = { shutdownCalled.signal() }
        server.onRequest = { _ in
            .success(text: "main-actor")
        }
        try server.start()
        defer { server.stop() }

        let helloReply = try Self.sendLine("{\"control\":\"hello\",\"auth_token\":\"secret\"}\n", to: path)
        XCTAssertTrue(helloReply.contains("\"ok\":true"), helloReply)
        XCTAssertTrue(helloReply.contains("comma-computer-use-daemon"), helloReply)

        let badReply = try Self.sendLine("{\"control\":\"hello\",\"auth_token\":\"wrong\"}\n", to: path)
        XCTAssertTrue(badReply.contains("\"ok\":false"), badReply)

        let shutdownReply = try Self.sendLine("{\"control\":\"shutdown\",\"auth_token\":\"secret\"}\n", to: path)
        XCTAssertTrue(shutdownReply.contains("\"ok\":true"), shutdownReply)
        shutdownCalled.wait()
    }

    private static func sendLine(_ line: String, to socketPath: String) throws -> String {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = socketPath.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            let raw = UnsafeMutableRawPointer(ptr)
            bytes.withUnsafeBufferPointer { buf in
                raw.copyMemory(from: buf.baseAddress!, byteCount: buf.count)
            }
        }
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }

        let out = Array(line.utf8)
        _ = out.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, out.count) }

        var reply = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = Darwin.read(fd, &buf, buf.count)
            if n <= 0 { break }
            reply.append(contentsOf: buf[0 ..< n])
            if reply.contains(0x0A) { break }
        }
        return String(data: reply, encoding: .utf8) ?? ""
    }
}
