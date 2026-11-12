// The "pasted from" banner iOS shows after a paste from another app (SimulatorStreamSession's "paste"). While it shows,
// it has the keyboard focus and the keys sent go to it, not to the app: what comes after a paste waits until it gives
// the focus back. It shows ~2.54 s from when it comes up, and it comes up late the first time after a boot (its
// process starts then: 0.24–0.35 s, seen 2026-11-07, iOS 27.2), so a fixed wait from the ⌘V lost the keys after it.
// SpringBoard's log says when the banner takes the focus (`deferFromSBWindowScene: adding` for DragUI's druid) and when
// it gives it back (`… invalidate`); a view that drives a simulator follows that log for as long as it lasts.
import Foundation

final class PasteBanner: @unchecked Sendable {
    struct Timing: Sendable {
        /// Keys go this long after the ⌘V when no banner came up (the paste refused, or nothing pasted).
        var unseen: Duration = .seconds(1)
        /// Keys go at the latest this long after the ⌘V.
        var most: Duration = .seconds(5)
        /// After the banner gave the focus back: the app's scene takes it a few ms later.
        var settle: Duration = .milliseconds(50)
        /// Where the log is not followed: a fixed wait from the ⌘V (the banner's time when it comes up at once).
        var fixed: Duration = .milliseconds(2_600)
        /// How long a paste waits for the log to be followed (a device just booted is slow to start it).
        var ready: Duration = .seconds(2)
    }

    /// Why the keys may go.
    enum Outcome: Equatable {
        case back, unseen, most, fixed, ended
    }

    /// What the log had said before a ⌘V.
    struct Mark {
        let taken: Int
        let back: Int
        let live: Bool
        let at: ContinuousClock.Instant
    }

    /// The log stream, restarted on its own after this long (`log stream --timeout`): one left behind by a helper that
    /// did not end it (killed) ends by itself.
    static let restartAfter = "10m"
    static let predicate = "process == \"SpringBoard\" AND category == \"KeyboardFocus\" AND eventMessage CONTAINS \"deferFromSBWindowScene\" AND eventMessage CONTAINS \"com.apple.DragUI.druid\""

    let timing: Timing
    private let lock = NSLock()
    /// The log is followed now: its process said its first line, and has not ended since.
    private var live = false
    private var taken = 0
    private var back = 0
    private var ended = false
    private var process: Process?
    /// Told each line read and each end of the followed process, as they come (for tests: set before `follow`).
    var heardLine: ((String) -> Void)?
    var processEnded: ((Int32) -> Void)?

    init(timing: Timing = Timing()) {
        self.timing = timing
    }

    /// The command that follows a simulator's log.
    static func command(simctl: String, udid: String) -> [String] {
        [simctl, "spawn", udid, "log", "stream", "--timeout", restartAfter, "--style", "compact", "--predicate", predicate]
    }

    // MARK: following the log

    /// Runs `command` and reads its lines until `end`, started again as it ends (at most a few times in a row when it
    /// says nothing: then the log is not followed and a paste waits `timing.fixed`). Nothing here blocks the caller.
    func follow(_ command: [String]) {
        start(command, failures: 0)
    }

    private func start(_ command: [String], failures: Int) {
        guard failures < 3, let executable = command.first else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(command.dropFirst())
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        let said = NSLock()
        var saidAny = false
        var pending = ""
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            pending += String(decoding: data, as: UTF8.self)
            var lines = pending.components(separatedBy: "\n")
            pending = lines.removeLast()
            if !lines.isEmpty {
                said.lock()
                saidAny = true
                said.unlock()
            }
            // (its first line, "Filtering the log data using …", says the stream is on)
            for line in lines {
                self?.read(line)
                self?.heardLine?(line)
            }
        }
        process.terminationHandler = { [weak self] _ in
            out.fileHandleForReading.readabilityHandler = nil
            guard let self else { return }
            self.processEnded?(process.processIdentifier)
            said.lock()
            let wasLive = saidAny
            said.unlock()
            self.lock.lock()
            self.live = false
            if self.process === process { self.process = nil }
            let ended = self.ended
            self.lock.unlock()
            if ended { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + (wasLive ? 0 : 1)) { [weak self] in
                self?.start(command, failures: wasLive ? 0 : failures + 1)
            }
        }
        lock.lock()
        guard !ended else { return lock.unlock() }
        self.process = process
        lock.unlock()
        do {
            try process.run()
        } catch {
            lock.lock()
            if self.process === process { self.process = nil }
            lock.unlock()
            out.fileHandleForReading.readabilityHandler = nil
        }
        // (ended while it started: `end` may have found it not running yet)
        lock.lock()
        let endedNow = ended
        lock.unlock()
        if endedNow, process.isRunning { process.terminate() }
    }

    /// One line of the log.
    func read(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        live = true
        if line.contains("deferFromSBWindowScene: adding") { taken += 1 }
        if line.contains("deferFromSBWindowScene: invalidate") { back += 1 }
    }

    /// The view ended: the log is no longer followed, and a paste waiting goes on at once.
    func end() {
        lock.lock()
        ended = true
        live = false
        let process = process
        self.process = nil
        lock.unlock()
        if let process, process.isRunning { process.terminate() }
    }

    // MARK: waiting

    /// Once the log is followed, at most `timing.ready`.
    func ready() async {
        let start = ContinuousClock.now
        while ContinuousClock.now - start < timing.ready {
            let now = state()
            if now.live || now.ended || Task.isCancelled { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func state() -> (live: Bool, taken: Int, back: Int, ended: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (live, taken, back, ended)
    }

    /// What the log has said so far: taken just before a ⌘V.
    func mark() -> Mark {
        lock.lock()
        defer { lock.unlock() }
        return Mark(taken: taken, back: back, live: live, at: .now)
    }

    /// What the log has said now.
    struct Heard: Equatable {
        var live: Bool
        var taken: Int
        var back: Int
        var ended: Bool = false
    }

    /// Once the keys may go after a ⌘V made just after `mark`: the banner gave the focus back (and `timing.settle`), or
    /// none came up within `timing.unseen`, or `timing.most` passed. Where the log was not followed (or stopped
    /// being), `timing.fixed` from the ⌘V.
    func passed(_ mark: Mark) async -> Outcome {
        while true {
            let now = state()
            let heard = Heard(live: now.live, taken: now.taken, back: now.back, ended: now.ended || Task.isCancelled)
            if let outcome = Self.decide(mark, heard, waited: ContinuousClock.now - mark.at, timing: timing) {
                if outcome == .back { try? await Task.sleep(for: timing.settle) }
                return outcome
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Whether the keys may go `waited` after the ⌘V, as the log has said `heard` since `mark`; nil: not yet.
    static func decide(_ mark: Mark, _ heard: Heard, waited: Duration, timing: Timing) -> Outcome? {
        if heard.ended { return .ended }
        if mark.live, heard.back > mark.back { return .back }
        if !mark.live || !heard.live { return waited >= timing.fixed ? .fixed : nil }
        if heard.taken == mark.taken { return waited >= timing.unseen ? .unseen : nil }
        return waited >= timing.most ? .most : nil
    }
}
