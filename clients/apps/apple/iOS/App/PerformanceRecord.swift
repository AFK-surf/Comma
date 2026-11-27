import Foundation
import Network
import Observation
import os
import UIKit

/// Aggregates messages crossing the Hermes <-> Swift bridge while performance recording is on.
final class CoreBridgePerfCounters: @unchecked Sendable {
    static let shared = CoreBridgePerfCounters()

    private struct InBucket {
        var count: Int = 0
        var bytes: Int = 0
        var ms: Double = 0
    }

    private let lock = OSAllocatedUnfairLock()
    private var incoming: [String: InBucket] = [:]
    private var outgoing: [String: Int] = [:]

    func recordOut(_ name: String) {
        lock.withLock {
            outgoing[name, default: 0] += 1
        }
    }

    func recordIn(_ name: String, bytes: Int, ms: Double) {
        lock.withLock {
            var bucket = incoming[name] ?? InBucket()
            bucket.count += 1
            bucket.bytes += bytes
            bucket.ms += ms
            incoming[name] = bucket
        }
    }

    func reset() {
        lock.withLock {
            incoming.removeAll()
            outgoing.removeAll()
        }
    }

    /// Formats the 6 heaviest incoming and 6 most frequent outgoing bridge messages since the previous call, then clears.
    func takeSummary() -> String {
        let (ins, outs) = lock.withLock { () -> ([(String, InBucket)], [(String, Int)]) in
            guard !incoming.isEmpty || !outgoing.isEmpty else { return ([], []) }
            let capturedIn = Array(incoming)
            let capturedOut = Array(outgoing)
            incoming.removeAll()
            outgoing.removeAll()
            return (capturedIn, capturedOut)
        }
        guard !ins.isEmpty || !outs.isEmpty else { return "" }

        let topIn = ins.sorted { $0.1.ms > $1.1.ms }.prefix(6)
        let topOut = outs.sorted { $0.1 > $1.1 }.prefix(6)

        var parts: [String] = []
        if !topIn.isEmpty {
            let items = topIn.map { name, bucket in
                let msText = String(format: "%.1f", bucket.ms)
                let kbText = String(format: "%.1f", Double(bucket.bytes) / 1024.0)
                return "\(msText)ms/\(bucket.count)/\(kbText)KB \(name)"
            }
            parts.append("in (ms/count/KB): " + items.joined(separator: " | "))
        }
        if !topOut.isEmpty {
            let items = topOut.map { "\($0.1) \($0.0)" }
            parts.append("out (count): " + items.joined(separator: " | "))
        }
        return parts.joined(separator: " || ")
    }
}

/// Pure accumulator for main-runloop awake turns (separated from `CFRunLoopObserver` for deterministic unit tests).
struct MainRunLoopAccumulator {
    static let slowThresholdMs = 16.0
    static let hitchThresholdMs = 50.0

    private(set) var turns = 0
    private(set) var busyMs = 0.0
    private(set) var maxMs = 0.0
    private(set) var slowCount = 0
    private(set) var hitchCount = 0

    mutating func recordTurn(durationMs: Double) {
        let ms = max(0.0, durationMs)
        turns += 1
        busyMs += ms
        if ms > maxMs { maxMs = ms }
        if ms >= Self.slowThresholdMs { slowCount += 1 }
        if ms >= Self.hitchThresholdMs { hitchCount += 1 }
    }

    mutating func takeSummary(spanMs: Double) -> String? {
        guard turns > 0 else { return nil }
        let denom = max(1.0, spanMs)
        let busyPct = busyMs * 100.0 / denom
        let line = String(format: "turns=%d busy=%.0f%% max=%.0fms slow=%d hitch=%d",
                          turns, busyPct, maxMs, slowCount, hitchCount)
        self = MainRunLoopAccumulator()
        return line
    }
}

/// Passive observer on the main run loop: measures wakeups and main-thread busy time with zero extra display wakeups.
@MainActor
private final class MainRunLoopProbe {
    private var observer: CFRunLoopObserver?
    private var wokeAt: UInt64 = 0
    private var stats = MainRunLoopAccumulator()

    func start() {
        guard observer == nil else { return }
        wokeAt = 0
        stats = MainRunLoopAccumulator()
        let activities: CFRunLoopActivity = [.afterWaiting, .beforeWaiting]
        let created = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, activities.rawValue, true, 0) { [weak self] _, activity in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = DispatchTime.now().uptimeNanoseconds
                if activity.contains(.afterWaiting) {
                    self.wokeAt = now
                } else if activity.contains(.beforeWaiting), self.wokeAt != 0 {
                    let durationMs = Double(now &- self.wokeAt) / 1_000_000.0
                    self.wokeAt = 0
                    self.stats.recordTurn(durationMs: durationMs)
                }
            }
        }
        guard let created else { return }
        CFRunLoopAddObserver(CFRunLoopGetMain(), created, .commonModes)
        observer = created
    }

    func stop() {
        if let observer {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
            CFRunLoopObserverInvalidate(observer)
            self.observer = nil
        }
        wokeAt = 0
        stats = MainRunLoopAccumulator()
    }

    func takeSummary(spanMs: Double) -> String? {
        stats.takeSummary(spanMs: spanMs)
    }
}

/// Serial, rotating log store under `Documents/perf/perf-YYYYMMDD[-N].log`.
final class PerfLogStore: @unchecked Sendable {
    static let defaultMaxFileBytes: Int64 = 5 * 1024 * 1024
    static let defaultMaxFilesKept = 3

    let directory: URL
    let maxFileBytes: Int64
    let maxFilesKept: Int
    private let now: @Sendable () -> Date
    private let queue = DispatchQueue(label: "surf.comma.perf", qos: .utility)

    // Confined to `queue`.
    private var currentFile: URL?
    private var currentFileBytes: Int64 = 0
    private var cachedTotalBytes: Int64 = -1

    init(directory: URL,
         maxFileBytes: Int64 = PerfLogStore.defaultMaxFileBytes,
         maxFilesKept: Int = PerfLogStore.defaultMaxFilesKept,
         now: @escaping @Sendable () -> Date = Date.init) {
        self.directory = directory
        self.maxFileBytes = max(256, maxFileBytes)
        self.maxFilesKept = max(1, maxFilesKept)
        self.now = now
    }

    static func defaultDirectory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return docs.appendingPathComponent("perf", isDirectory: true)
    }

    func totalBytesSync() -> Int64 {
        queue.sync {
            if cachedTotalBytes < 0 {
                recountLocked()
            }
            return cachedTotalBytes
        }
    }

    func append(_ text: String, continuationHeader: (@Sendable () -> String)? = nil,
                onTotalBytes: (@Sendable (Int64) -> Void)? = nil) {
        let stamp = Self.formatTimestamp(now())
        let line = "\(stamp.full) \(text)\n"
        let day = stamp.day
        queue.async { [self] in
            let currentName = currentFile?.lastPathComponent ?? ""
            let sameDay = currentName.hasPrefix("perf-\(day)")
            if currentFile == nil || !sameDay || currentFileBytes >= maxFileBytes {
                pickFileLocked(day: day, continuationHeader: continuationHeader)
            }
            guard let target = currentFile else { return }
            let written = writeBytesLocked(Data(line.utf8), to: target)
            if written > 0 {
                currentFileBytes += written
                cachedTotalBytes = (cachedTotalBytes < 0 ? 0 : cachedTotalBytes) + written
                onTotalBytes?(cachedTotalBytes)
            }
        }
    }

    func exportCombined(to destination: URL) -> URL? {
        queue.sync {
            let files = listFilesLocked().reversed()
            var combined = Data()
            for file in files {
                if let data = try? Data(contentsOf: file) {
                    combined.append(data)
                }
            }
            guard !combined.isEmpty else { return nil }
            do {
                try combined.write(to: destination, options: .atomic)
                return destination
            } catch {
                return nil
            }
        }
    }

    func flushSync() {
        queue.sync {}
    }

    func listFilesForTesting() -> [URL] {
        queue.sync { listFilesLocked() }
    }

    // MARK: - Queue-confined helpers

    private func listFilesLocked() -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let all = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        let logs = all.filter {
            let name = $0.lastPathComponent
            return name.hasPrefix("perf-") && $0.pathExtension == "log"
        }
        return logs.sorted { lhs, rhs in
            let d1 = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let d2 = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if d1 != d2 { return d1 > d2 }
            return Self.sortRank(lhs.lastPathComponent) > Self.sortRank(rhs.lastPathComponent)
        }
    }

    /// Orders `perf-YYYYMMDD-2.log` after `perf-YYYYMMDD.log` when two files share the same modification timestamp.
    private static func sortRank(_ filename: String) -> (String, Int) {
        let stem = filename.hasSuffix(".log") ? String(filename.dropLast(4)) : filename
        let parts = stem.split(separator: "-")
        guard parts.count >= 2 else { return (stem, 0) }
        let day = String(parts[1])
        let seq = parts.count >= 3 ? (Int(parts[2]) ?? 1) : 1
        return (day, seq)
    }

    private func recountLocked() {
        var total: Int64 = 0
        for url in listFilesLocked() {
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        cachedTotalBytes = total
    }

    private func pickFileLocked(day: String, continuationHeader: (@Sendable () -> String)?) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var picked = directory.appendingPathComponent("perf-\(day).log")
        var bytes: Int64 = 0
        for index in 1..<1000 {
            let candidate = directory.appendingPathComponent(index == 1 ? "perf-\(day).log" : "perf-\(day)-\(index).log")
            let size = (try? fm.attributesOfItem(atPath: candidate.path)[.size] as? NSNumber)?.int64Value ?? 0
            picked = candidate
            bytes = size
            if size < maxFileBytes { break }
        }
        let rotated = currentFile != nil
        let fresh = !fm.fileExists(atPath: picked.path)
        currentFile = picked
        currentFileBytes = bytes
        if fresh {
            fm.createFile(atPath: picked.path, contents: nil)
            if rotated, let headerText = continuationHeader?(), !headerText.isEmpty {
                let stamp = Self.formatTimestamp(now())
                let headerLine = "\(stamp.full) \(headerText)\n"
                currentFileBytes = writeBytesLocked(Data(headerLine.utf8), to: picked)
            }
            let files = listFilesLocked()
            if files.count > maxFilesKept {
                for obsolete in files[maxFilesKept...] where obsolete.path != picked.path {
                    try? fm.removeItem(at: obsolete)
                }
            }
        }
        recountLocked()
    }

    private func writeBytesLocked(_ data: Data, to url: URL) -> Int64 {
        guard !data.isEmpty else { return 0 }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            return (try? data.write(to: url, options: .atomic)) != nil ? Int64(data.count) : 0
        }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            return Int64(data.count)
        } catch {
            return 0
        }
    }

    private static func formatTimestamp(_ date: Date) -> (full: String, day: String) {
        let interval = date.timeIntervalSince1970
        var secs = time_t(interval)
        let millis = Int((interval - floor(interval)) * 1000.0)
        var tmValue = tm()
        localtime_r(&secs, &tmValue)
        var fullBuf = [CChar](repeating: 0, count: 40)
        var dayBuf = [CChar](repeating: 0, count: 16)
        strftime(&fullBuf, fullBuf.count, "%Y-%m-%d %H:%M:%S", &tmValue)
        strftime(&dayBuf, dayBuf.count, "%Y%m%d", &tmValue)
        let fullPrefix = String(cString: fullBuf)
        let day = String(cString: dayBuf)
        return (String(format: "%@.%03d", fullPrefix, max(0, min(999, millis))), day)
    }
}

/// On-device performance recording (Settings › Diagnostics › Performance recording).
/// When off, nothing runs: no timer, no runloop observer, no network path monitor, no core JS task timing.
@MainActor @Observable
final class PerformanceRecord {
    static let shared = PerformanceRecord()
    static let defaultsKey = "comma.perf-record"
    static let storageLocationLabel = "Documents/perf"
    static let tickIntervalSeconds: TimeInterval = 5.0

    /// Development and TestFlight builds expose performance recording; App Store builds hide and disable it.
    static var isAvailable: Bool { BackendEnvironment.switchAvailable }

    private static let hotThreadThresholdPercent = 80.0
    private static let hotThreadSamplesPerTick = 3
    private static let hotThreadMaxTicks = 12

    nonisolated private static let fastActiveLock = OSAllocatedUnfairLock(initialState: false)
    nonisolated private static let sharedSinkLock = OSAllocatedUnfairLock<(@Sendable (String) -> Void)?>(initialState: nil)

    nonisolated static var isRecordingFast: Bool {
        fastActiveLock.withLock { $0 }
    }

    nonisolated static func noteShared(_ text: String) {
        guard !text.isEmpty, isRecordingFast else { return }
        let sink = sharedSinkLock.withLock { $0 }
        sink?(text)
    }

    private(set) var isEnabled = false
    private(set) var recordedBytes: Int64 = 0

    /// Supplies a compact one-line description of the current screen/tab for each 5 s tick.
    @ObservationIgnored var pageSummaryProvider: (@MainActor () -> String?)?

    @ObservationIgnored private let logStore: PerfLogStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let available: Bool
    @ObservationIgnored private let useSharedEngineHooks: Bool
    @ObservationIgnored private let bridgeCounters: CoreBridgePerfCounters
    @ObservationIgnored private let threadTracker = CommaPerfThreadTracker()
    @ObservationIgnored private let runLoopProbe = MainRunLoopProbe()
    @ObservationIgnored private let stackQueue = DispatchQueue(label: "surf.comma.perf.stacks", qos: .utility)
    @ObservationIgnored private let consoleProbe: Bool
    @ObservationIgnored private let logger = Logger(subsystem: "surf.comma.ios", category: "perf")

    @ObservationIgnored private var observerTokens: [NSObjectProtocol] = []
    @ObservationIgnored private var tickTimer: Timer?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var lastCPU = 0.0
    @ObservationIgnored private var lastTickUptimeMs = 0.0
    @ObservationIgnored private var lastPower = CommaPerfPowerSnap()
    @ObservationIgnored private let identityLock = OSAllocatedUnfairLock(initialState: "")
    @ObservationIgnored private var hotThreadID: UInt64 = 0
    @ObservationIgnored private var hotTicks = 0
    @ObservationIgnored private let latestBytesLock = OSAllocatedUnfairLock(initialState: (telling: false, total: Int64(0)))
    @ObservationIgnored private let localEnabled = OSAllocatedUnfairLock(initialState: false)

    init(directory: URL = PerfLogStore.defaultDirectory(),
         defaults: UserDefaults = .standard,
         maxFileBytes: Int64 = PerfLogStore.defaultMaxFileBytes,
         maxFilesKept: Int = PerfLogStore.defaultMaxFilesKept,
         available: Bool = PerformanceRecord.isAvailable,
         useSharedEngineHooks: Bool = true,
         bridgeCounters: CoreBridgePerfCounters = .shared,
         now: @escaping @Sendable () -> Date = Date.init) {
        self.logStore = PerfLogStore(directory: directory, maxFileBytes: maxFileBytes, maxFilesKept: maxFilesKept, now: now)
        self.defaults = defaults
        self.available = available
        self.useSharedEngineHooks = useSharedEngineHooks
        self.bridgeCounters = bridgeCounters
        let env = ProcessInfo.processInfo.environment["COMMA_PERF_PROBE"]
        let args = ProcessInfo.processInfo.arguments
        self.consoleProbe = available && useSharedEngineHooks && (env == "1" || args.contains("-CommaPerfProbe"))
        self.recordedBytes = available ? logStore.totalBytesSync() : 0
    }

    func startIfNeeded() {
        guard available else { return }
        if defaults.bool(forKey: Self.defaultsKey) {
            begin(reason: "launch")
        } else {
            updateTimer()
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard available || !enabled else { return }
        guard enabled != isEnabled else { return }
        defaults.set(enabled, forKey: Self.defaultsKey)
        if enabled {
            begin(reason: "turned on")
        } else {
            note("perf: off")
            isEnabled = false
            localEnabled.withLock { $0 = false }
            if useSharedEngineHooks {
                Self.fastActiveLock.withLock { $0 = false }
                Self.sharedSinkLock.withLock { $0 = nil }
                CommaEngine.setPerfTimingEnabled(false)
            }
            bridgeCounters.reset()
            UIDevice.current.isBatteryMonitoringEnabled = false
            runLoopProbe.stop()
            stopNetworkMonitor()
            removeSystemObservers()
            hotThreadID = 0
            hotTicks = 0
            threadTracker.reset()
            updateTimer()
        }
    }

    nonisolated func note(_ text: String) {
        guard !text.isEmpty, localEnabled.withLock({ $0 }) else { return }
        let header = continuationHeaderBuilder()
        logStore.append(text, continuationHeader: header) { [weak self] total in
            self?.scheduleBytesUpdate(total)
        }
    }

    /// Concatenates the kept log files oldest-first into a temporary `comma-perf.log` ready to share.
    func exportFileURL() -> URL? {
        guard available else { return nil }
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("comma-perf.log")
        return logStore.exportCombined(to: target)
    }

    func flushForTesting() {
        logStore.flushSync()
        recordedBytes = logStore.totalBytesSync()
    }

    /// Executes one 5 s sampling tick immediately (also called by the repeating timer).
    func sampleTickNow() {
        let cpu = CommaPerfProcessCPUMs()
        let nowMs = Self.monotonicMs()
        let spanMs = max(1.0, nowMs - lastTickUptimeMs)
        let cpuShare = (cpu >= 0 && lastCPU >= 0) ? max(0.0, (cpu - lastCPU) * 100.0 / spanMs) : 0.0
        let thermal = ProcessInfo.processInfo.thermalState.rawValue
        let threads = threadTracker.sampleOverSpanMs(spanMs)
        let prevPower = lastPower
        let curPower = CommaPerfReadPower()
        lastPower = curPower
        lastCPU = cpu
        lastTickUptimeMs = nowMs

        if consoleProbe {
            logger.info("PROBE ios: cpu=\(Int(round(cpuShare)))% thermal=\(thermal) threads:\(threads.summary, privacy: .public)")
        }

        guard isEnabled else { return }

        let memMB = CommaPerfMemoryBytes() / 1_048_576.0
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled ? 1 : 0
        note(String(format: "ios: cpu=%.0f%% thermal=%ld mem=%.0fMB %@ lowpower=%d",
                    cpuShare, thermal, memMB, Self.batterySummary(), lowPower))
        note("threads:\(threads.summary)")

        if curPower.valid && prevPower.valid {
            let userPct = max(0.0, (curPower.userMs - prevPower.userMs) * 100.0 / spanMs)
            let sysPct = max(0.0, (curPower.sysMs - prevPower.sysMs) * 100.0 / spanMs)
            var powerLine = String(format: "power: user=%.0f%% sys=%.0f%%", userPct, sysPct)
            if curPower.hasPowerInfo && prevPower.hasPowerInfo {
                let idle = Self.u64Delta(curPower.idleWakeups, prevPower.idleWakeups)
                let intr = Self.u64Delta(curPower.intrWakeups, prevPower.intrWakeups)
                let bin1 = Self.u64Delta(curPower.timerBin1, prevPower.timerBin1)
                let bin2 = Self.u64Delta(curPower.timerBin2, prevPower.timerBin2)
                powerLine += " wkups=\(idle)/\(intr) timers=\(bin1)/\(bin2)"
            }
            if curPower.hasPowerV2 && prevPower.hasPowerV2 {
                let gpuMs = Double(Self.u64Delta(curPower.gpuNs, prevPower.gpuNs)) / 1_000_000.0
                if gpuMs >= 0.05 {
                    powerLine += String(format: " gpu=%.1fms", gpuMs)
                }
                if curPower.hasEnergy && prevPower.hasEnergy {
                    let energyMj = Double(Self.u64Delta(curPower.energyNj, prevPower.energyNj)) / 1_000_000.0
                    if energyMj >= 0.05 {
                        powerLine += String(format: " energy=%.1fmJ", energyMj)
                    }
                }
            }
            note(powerLine)
        }

        if let mainLine = runLoopProbe.takeSummary(spanMs: spanMs) {
            note("main: \(mainLine)")
        }

        if useSharedEngineHooks {
            let jsSummary = CommaEngine.takePerfSummary(forSpanMs: spanMs)
            if !jsSummary.isEmpty {
                note("core js: \(jsSummary)")
            }
        }

        let bridgeSummary = bridgeCounters.takeSummary()
        if !bridgeSummary.isEmpty {
            note("core: \(bridgeSummary)")
        }

        if let page = pageSummaryProvider?(), !page.isEmpty {
            note("page: \(page)")
        }

        watchHotThread(threads)
    }

    // MARK: - Lifecycle

    private func begin(reason: String) {
        isEnabled = true
        localEnabled.withLock { $0 = true }
        if useSharedEngineHooks {
            Self.sharedSinkLock.withLock { $0 = { [weak self] line in self?.note(line) } }
            Self.fastActiveLock.withLock { $0 = true }
            CommaEngine.setPerfTimingEnabled(true)
        }
        bridgeCounters.reset()

        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let info = Bundle.main.infoDictionary
        let shortVersion = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let ident = "device=\(CommaPerfMachineIdentifier()) \(device.systemName) \(device.systemVersion) app=\(shortVersion) (\(build))"
        identityLock.withLock { $0 = ident }

        let thermal = ProcessInfo.processInfo.thermalState.rawValue
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled ? 1 : 0
        note("perf: on (\(reason)) \(ident) thermal=\(thermal) lowpower=\(lowPower) \(Self.batterySummary())")

        installSystemObservers()
        runLoopProbe.start()
        startNetworkMonitor()
        updateTimer()
    }

    private func updateTimer() {
        let want = isEnabled || consoleProbe
        if want && tickTimer == nil {
            lastCPU = CommaPerfProcessCPUMs()
            lastTickUptimeMs = Self.monotonicMs()
            lastPower = CommaPerfReadPower()
            _ = threadTracker.sampleOverSpanMs(1.0)
            if isEnabled {
                if useSharedEngineHooks {
                    _ = CommaEngine.takePerfSummary(forSpanMs: 1.0)
                }
                _ = bridgeCounters.takeSummary()
            }
            let timer = Timer(timeInterval: Self.tickIntervalSeconds, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sampleTickNow() }
            }
            timer.tolerance = 0.5
            RunLoop.main.add(timer, forMode: .common)
            tickTimer = timer
        } else if !want, let timer = tickTimer {
            timer.invalidate()
            tickTimer = nil
        }
    }

    private func watchHotThread(_ sample: CommaPerfThreadSample) {
        guard sample.hottestPercent >= Self.hotThreadThresholdPercent, sample.hottestThreadID != 0 else {
            hotThreadID = 0
            hotTicks = 0
            return
        }
        if sample.hottestThreadID == hotThreadID {
            hotTicks += 1
        } else {
            hotThreadID = sample.hottestThreadID
            hotTicks = 1
        }
        guard hotTicks >= 2, hotTicks <= Self.hotThreadMaxTicks + 1 else { return }
        if hotTicks == 2 {
            let pct = Int(round(sample.hottestPercent))
            note("hot stacks: \(sample.hottestName)=\(pct)% tid=\(sample.hottestThreadID) for 10s, binary \(CommaPerfBinaryUUID())")
        }
        let targetID = sample.hottestThreadID
        let firstIndex = (hotTicks - 2) * Self.hotThreadSamplesPerTick
        stackQueue.async { [weak self] in
            for offset in 0..<Self.hotThreadSamplesPerTick {
                if let line = CommaPerfSampleThreadStack(targetID, Int32(firstIndex + offset)) {
                    self?.note(line)
                }
            }
        }
    }

    private func installSystemObservers() {
        guard observerTokens.isEmpty else { return }
        let center = NotificationCenter.default

        observerTokens.append(center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isEnabled else { return }
                self.note("thermal: \(ProcessInfo.processInfo.thermalState.rawValue)")
            }
        })
        observerTokens.append(center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isEnabled else { return }
                self.note(ProcessInfo.processInfo.isLowPowerModeEnabled ? "lowpower: on" : "lowpower: off")
            }
        })
        observerTokens.append(center.addObserver(forName: UIDevice.batteryStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isEnabled else { return }
                self.note("power: \(Self.batterySummary())")
            }
        })
        observerTokens.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isEnabled else { return }
                self.note("app: background")
            }
        })
        observerTokens.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isEnabled else { return }
                self.note("app: foreground")
            }
        })
        observerTokens.append(center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isEnabled else { return }
                self.note("memory: warning")
            }
        })
    }

    private func removeSystemObservers() {
        let center = NotificationCenter.default
        for token in observerTokens {
            center.removeObserver(token)
        }
        observerTokens.removeAll()
    }

    private func startNetworkMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let status: String = switch path.status {
            case .satisfied: "satisfied"
            case .unsatisfied: "unsatisfied"
            case .requiresConnection: "requiresConnection"
            @unknown default: "unknown"
            }
            let ifaces = path.availableInterfaces.map { iface -> String in
                let kind: String = switch iface.type {
                case .wifi: "wifi"
                case .cellular: "cell"
                case .wiredEthernet: "wired"
                case .loopback: "loopback"
                case .other: "other"
                @unknown default: "?"
                }
                return "\(iface.name)/\(kind)"
            }.joined(separator: ",")
            let line = "net: path \(status) ifaces=\(ifaces) expensive=\(path.isExpensive ? 1 : 0) constrained=\(path.isConstrained ? 1 : 0) ipv4=\(path.supportsIPv4 ? 1 : 0) ipv6=\(path.supportsIPv6 ? 1 : 0)"
            self.note(line)
        }
        monitor.start(queue: DispatchQueue(label: "surf.comma.perf.net", qos: .utility))
        pathMonitor = monitor
    }

    private func stopNetworkMonitor() {
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    private nonisolated func continuationHeaderBuilder() -> (@Sendable () -> String)? {
        let ident = identityLock.withLock { $0 }
        guard !ident.isEmpty else { return nil }
        return {
            let thermal = ProcessInfo.processInfo.thermalState.rawValue
            let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled ? 1 : 0
            return "perf: continued \(ident) thermal=\(thermal) lowpower=\(lowPower)"
        }
    }

    private nonisolated func scheduleBytesUpdate(_ total: Int64) {
        let shouldDispatch = latestBytesLock.withLock { state -> Bool in
            state.total = total
            if state.telling { return false }
            state.telling = true
            return true
        }
        guard shouldDispatch else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let latest = self.latestBytesLock.withLock { state -> Int64 in
                state.telling = false
                return state.total
            }
            MainActor.assumeIsolated {
                self.recordedBytes = latest
            }
        }
    }

    private static func batterySummary() -> String {
        let device = UIDevice.current
        let state: String = switch device.batteryState {
        case .charging: "charging"
        case .full: "full"
        case .unplugged: "unplugged"
        case .unknown: "unknown"
        @unknown default: "unknown"
        }
        let level = device.batteryLevel < 0 ? -1.0 : Double(device.batteryLevel) * 100.0
        return String(format: "battery=%@/%.0f%%", state, level)
    }

    private static func monotonicMs() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000.0
    }

    private static func u64Delta(_ cur: UInt64, _ prev: UInt64) -> UInt64 {
        cur >= prev ? cur - prev : 0
    }

    static func formattedByteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }
}
