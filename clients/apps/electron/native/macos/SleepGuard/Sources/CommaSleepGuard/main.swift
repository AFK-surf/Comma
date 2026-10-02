import Foundation
import Security

// Comma's privileged sleep guard. launchd starts it as root on the first XPC
// connection to its Mach service (see the LaunchDaemon plist written by
// scripts/sleep-guard-launchd.ts). It is the only part of Comma that can set
// the kernel's `SleepDisabled` flag, which is the one switch that keeps a
// MacBook awake with the lid closed; power assertions never reach clamshell
// sleep.
//
// Crash safety is the reason this is a daemon and not a sudo rule: the flag
// is held per XPC connection, and when Comma quits or crashes the kernel drops
// that connection and the guard restores sleep by itself.

let environment = ProcessInfo.processInfo.environment
guard
    let serviceName = environment["COMMA_SLEEP_GUARD_SERVICE"],
    let clientIdentifier = environment["COMMA_SLEEP_GUARD_CLIENT"]
else {
    FileHandle.standardError.write(Data("CommaSleepGuard must be started by launchd.\n".utf8))
    exit(64)
}

/// Reads `SleepDisabled` from `pmset -g`; nil when pmset cannot be read.
func readSleepDisabled() -> Bool? {
    guard let output = runPmset(["-g"]).output else { return nil }
    for line in output.split(separator: "\n") {
        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        if fields.count >= 2, fields[0] == "SleepDisabled" {
            return fields[1] == "1"
        }
    }
    // Older releases omit the row while the flag is clear.
    return false
}

/// Runs `pmset -a disablesleep 0|1`; returns an error message on failure.
func writeSleepDisabled(_ disabled: Bool) -> String? {
    let result = runPmset(["-a", "disablesleep", disabled ? "1" : "0"])
    return result.error
}

func runPmset(_ arguments: [String]) -> (output: String?, error: String?) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    process.arguments = arguments
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    do {
        try process.run()
    } catch {
        return (nil, "pmset could not start: \(error.localizedDescription)")
    }
    // Drain both pipes before waiting so a chatty pmset cannot block on a full pipe.
    let output = stdout.fileHandleForReading.readDataToEndOfFile()
    let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let message = String(decoding: errorOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (nil, "pmset exited with \(process.terminationStatus): \(message)")
    }
    return (String(decoding: output, as: UTF8.self), nil)
}

/// Only Comma itself may connect: the same signing team as this daemon, or the
/// bare bundle identifier for an ad-hoc signed development build.
func peerRequirement() -> String {
    var code: SecCode?
    var staticCode: SecStaticCode?
    var information: CFDictionary?
    if SecCodeCopySelf([], &code) == errSecSuccess, let code,
       SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
       SecCodeCopySigningInformation(
           staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information
       ) == errSecSuccess,
       let team = (information as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    {
        return "anchor apple generic and identifier \"\(clientIdentifier)\" and certificate leaf[subject.OU] = \"\(team)\""
    }
    return "identifier \"\(clientIdentifier)\""
}

/// All state lives on one serial queue.
final class SleepGuard: @unchecked Sendable {
    let queue = DispatchQueue(label: "comma.sleep-guard.state")
    private var connections = Set<ObjectIdentifier>()
    private var holders = Set<ObjectIdentifier>()
    /// One marker per guard (per app flavor) while it holds the flag on
    /// Comma's behalf. The flag itself is stored on disk and survives a
    /// reboot, so ownership must too: a guard that was killed, or a Mac that
    /// lost power, while holding finds its marker on the next start and
    /// clears the flag instead of mistaking it for one the user set. Flavors
    /// share the one system flag, so it is cleared only after the last
    /// marker goes.
    private static let markerDirectory = "/var/db/comma-sleep-guard"
    /// Serializes every flavor's read-check-write of the markers and the flag.
    /// Kept outside the marker directory so it never counts as a holder. The
    /// kernel drops an flock when its process dies, so a killed guard cannot
    /// leave it held.
    private static let lockPath = "/var/db/comma-sleep-guard.lock"
    private let marker: String
    private let markerName: String

    init(serviceName: String) {
        markerName = serviceName
        marker = "\(Self.markerDirectory)/\(serviceName)"
    }

    private var ownsFlag: Bool { FileManager.default.fileExists(atPath: marker) }

    private var otherCommaHolds: Bool {
        let markers = try? FileManager.default.contentsOfDirectory(atPath: Self.markerDirectory)
        return (markers ?? []).contains { $0 != markerName }
    }

    /// Runs `body` while holding the cross-flavor lock.
    private func withSharedState(_ body: () -> String?) -> String? {
        let descriptor = open(Self.lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            return "The sleep guard could not open its lock: \(String(cString: strerror(errno)))"
        }
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else {
                return "The sleep guard could not take its lock: \(String(cString: strerror(errno)))"
            }
        }
        return body()
    }

    /// Gives up this guard's hold. Runs at start, after the last holder, and
    /// on SIGTERM.
    @discardableResult
    func restoreIfOwned() -> String? {
        withSharedState {
            guard ownsFlag else { return nil }
            if !otherCommaHolds, let error = writeSleepDisabled(false) {
                // Keep the marker so the next start retries.
                return error
            }
            // Remove the marker only once the flag is clear (or another flavor
            // still holds it): a guard killed before this line finds the
            // marker on its next start and retries.
            try? FileManager.default.removeItem(atPath: marker)
            return nil
        }
    }

    func accept(_ peer: xpc_connection_t) {
        let id = ObjectIdentifier(peer as AnyObject)
        connections.insert(id)
        xpc_connection_set_target_queue(peer, queue)
        xpc_connection_set_event_handler(peer) { [self] event in
            if xpc_get_type(event) == XPC_TYPE_DICTIONARY {
                handle(event, id: id)
                return
            }
            // XPC_ERROR_CONNECTION_INVALID or _INTERRUPTED: Comma quit or crashed.
            guard connections.remove(id) != nil else { return }
            release(id)
            exitWhenIdle()
        }
        xpc_connection_resume(peer)
    }

    /// Exits once no client has connected for a while; launchd starts the
    /// guard again on the next connection. The delay keeps a quick reconnect
    /// clear of launchd's respawn throttle.
    private var termination: DispatchSourceSignal?
    private var listener: xpc_connection_t?

    func listen(serviceName: String, requirement: String) {
        let listener = xpc_connection_create_mach_service(
            serviceName, queue, UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER)
        )
        xpc_connection_set_event_handler(listener) { [self] event in
            guard xpc_get_type(event) == XPC_TYPE_CONNECTION else { return }
            let peer = event as xpc_connection_t
            guard xpc_connection_set_peer_code_signing_requirement(peer, requirement) == 0 else {
                xpc_connection_cancel(peer)
                return
            }
            accept(peer)
        }
        xpc_connection_resume(listener)
        self.listener = listener
    }

    /// launchd sends SIGTERM when the user disables the daemon, the app is
    /// removed, or the Mac shuts down. Installed from this nonisolated type:
    /// a handler written in top-level code is main-actor isolated and traps
    /// when it runs on the state queue.
    func restoreOnTermination() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
        source.setEventHandler { [self] in
            restoreIfOwned()
            exit(0)
        }
        source.resume()
        termination = source
    }

    func exitWhenIdle() {
        guard connections.isEmpty else { return }
        queue.asyncAfter(deadline: .now() + 30) { [self] in
            if connections.isEmpty { exit(0) }
        }
    }

    private func handle(_ message: xpc_object_t, id: ObjectIdentifier) {
        let error = xpc_dictionary_get_bool(message, "disable") ? hold(id) : release(id)
        guard let reply = xpc_dictionary_create_reply(message),
              let peer = xpc_dictionary_get_remote_connection(message)
        else { return }
        xpc_dictionary_set_bool(reply, "ok", error == nil)
        if let error { xpc_dictionary_set_string(reply, "error", error) }
        xpc_connection_send_message(peer, reply)
    }

    private func hold(_ id: ObjectIdentifier) -> String? {
        if holders.contains(id) { return nil }
        if !holders.isEmpty {
            holders.insert(id)
            return nil
        }
        let error = withSharedState {
            // Leave a flag someone else set before Comma did exactly as it was;
            // a flag another Comma flavor holds is shared.
            if ownsFlag { return nil }
            let alreadySet = readSleepDisabled() == true
            if !alreadySet || otherCommaHolds {
                // Mark first: a crash between the two steps must stay recoverable.
                try? FileManager.default.createDirectory(
                    atPath: Self.markerDirectory, withIntermediateDirectories: true
                )
                guard FileManager.default.createFile(atPath: marker, contents: nil) else {
                    return "The sleep guard could not record its state."
                }
            }
            if !alreadySet, let error = writeSleepDisabled(true) {
                try? FileManager.default.removeItem(atPath: marker)
                return error
            }
            return nil
        }
        if error == nil { holders.insert(id) }
        return error
    }

    @discardableResult
    private func release(_ id: ObjectIdentifier) -> String? {
        guard holders.remove(id) != nil, holders.isEmpty else { return nil }
        return restoreIfOwned()
    }
}

let sleepGuard = SleepGuard(serviceName: serviceName)
// launchd also starts the guard at boot (RunAtLoad), so a flag left by a power
// loss is cleared even if Comma never runs again.
sleepGuard.queue.sync {
    sleepGuard.restoreIfOwned()
    sleepGuard.exitWhenIdle()
}
sleepGuard.restoreOnTermination()
sleepGuard.listen(serviceName: serviceName, requirement: peerRequirement())
dispatchMain()
