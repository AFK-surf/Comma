import Foundation
import Darwin

/// A lazily started guest service. Calls are serialized by HIDInjector's actor;
/// replies acknowledge dispatch, so a failed command never switches capture.
final class DuoHIDBridge {
    private let udid: String
    private let executable: String
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?

    init(udid: String, executable: String) {
        self.udid = udid
        self.executable = executable
    }

    deinit { stop() }

    private func stop() {
        try? input?.close()
        try? output?.close()
        if let process, process.isRunning { process.terminate() }
        process = nil
        input = nil
        output = nil
    }

    func send(_ command: String) -> Bool {
        do {
            if process?.isRunning != true {
                stop()
                guard FileManager.default.isExecutableFile(atPath: executable) else { return false }
                let child = Process()
                let stdin = Pipe(), stdout = Pipe()
                // (CoreSimulator's own: Xcode's is a script that may first wait on `xcodebuild -runFirstLaunch`)
                child.executableURL = URL(fileURLWithPath: "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl")
                child.arguments = ["spawn", udid, executable]
                child.standardInput = stdin
                child.standardOutput = stdout
                child.standardError = FileHandle.standardError
                try child.run()
                process = child
                input = stdin.fileHandleForWriting
                output = stdout.fileHandleForReading
                // Its start (simctl spawn, the guest's HID services) waited for apart from any command's answer: on a busy
                // Mac it took 1-27 s, and counted in a command's 3 s every command failed, each killing the guest that was
                // still starting (the Duo side test, 2026-11-03).
                guard try line(within: 60) == "READY" else { stop(); return false }
            }
            guard let input else { return false }
            try input.write(contentsOf: Data((command + "\n").utf8))
            // As long as its start: a sweep is 0.8 s of the guest's own, and took 2.7 s on a busy Mac. A guest not answering in
            // 3 s was killed, the hinge left partway and the pose lost (still.fail #3907).
            let answer = try line(within: 60)
            if answer == "OK" { return true }
            print("[hid] Duo guest said \(answer ?? "nothing") to \(command)")
        } catch {
            print("[hid] Duo guest command failed: \(error)")
        }
        stop()
        return false
    }

    /// The guest's next line, or nil when none came whole within the seconds given.
    private func line(within seconds: TimeInterval) throws -> String? {
        guard let output else { return nil }
        let deadline = Date().addingTimeInterval(seconds)
        var reply = Data()
        while Date() < deadline && reply.count < 64 {
            var descriptor = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let remaining = max(1, Int32(deadline.timeIntervalSinceNow * 1000))
            guard poll(&descriptor, 1, remaining) > 0,
                  let byte = try output.read(upToCount: 1), !byte.isEmpty else { return nil }
            if byte[0] == 10 { return String(data: reply, encoding: .utf8) }
            reply.append(byte)
        }
        return nil
    }
}
