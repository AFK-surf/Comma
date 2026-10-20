import Foundation
import Observation
import QuartzCore
import notify
import os

/// Fixture-only frame pacing for the perf scenarios (`--perf-probe`). Between the tests' `PerfSignal.begin` and
/// `.end`, a CADisplayLink on the main run loop records when each frame was delivered. A frame that arrives more
/// than 1.5 refresh intervals after the one before is a hitch, and the time past one interval is its hitch time.
/// On end the window's summary (JSON, `FrameStats`) goes to the file at PERF_PROBE_FILE, which the tests read
/// without a UI query, and becomes the value of the fixture's `framePacing` element, whose label counts the windows
/// measured so far. Nothing runs outside a window.
@MainActor @Observable final class FramePacingProbe {
    private(set) var completed = 0
    private(set) var summary = ""

    @ObservationIgnored private var link: CADisplayLink?
    @ObservationIgnored private var last: CFTimeInterval?
    @ObservationIgnored private var intervals: [Double] = []
    @ObservationIgnored private var refreshIntervals: [Double] = []
    @ObservationIgnored private var start: (time: CFTimeInterval, cpu: CPUTimes)?
    @ObservationIgnored private var interval: OSSignpostIntervalState?
    /// The window shows as one "window" interval in Instruments' Points of Interest, to line traces up with it.
    @ObservationIgnored private let signposter = OSSignposter(subsystem: "surf.comma.perf", category: .pointsOfInterest)
    @ObservationIgnored private let mainThread = mach_thread_self()

    init() {
        for signal in [PerfSignal.begin, .end] {
            var token: Int32 = 0
            notify_register_dispatch(signal.name, &token, .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if signal == .begin { self?.begin() } else { self?.end() }
                }
            }
        }
    }

    private func begin() {
        link?.invalidate()
        intervals.removeAll(keepingCapacity: true); refreshIntervals.removeAll(keepingCapacity: true); last = nil
        let link = CADisplayLink(target: DisplayLinkTarget { [weak self] in self?.record($0) }, selector: #selector(DisplayLinkTarget.step))
        link.add(to: .main, forMode: .common)
        self.link = link
        interval = signposter.beginInterval("window")
        start = (CACurrentMediaTime(), CPUTimes(mainThread: mainThread))
    }

    private func record(_ link: CADisplayLink) {
        if let last { intervals.append(link.timestamp - last) }
        last = link.timestamp
        refreshIntervals.append(link.targetTimestamp - link.timestamp)
    }

    private func end() {
        guard let link, let start else { return }
        link.invalidate()
        self.link = nil; self.start = nil
        if let interval { signposter.endInterval("window", interval) }
        let stats = FrameStats(intervals: intervals, refreshIntervals: refreshIntervals,
                               duration: CACurrentMediaTime() - start.time,
                               cpu: CPUTimes(mainThread: mainThread) - start.cpu)
        completed += 1
        summary = stats.json(window: completed)
        if let path = ProcessInfo.processInfo.environment["PERF_PROBE_FILE"] {
            try? Data(summary.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}

/// CADisplayLink retains its target; this one holds the probe weakly through its closure.
@MainActor private final class DisplayLinkTarget: NSObject {
    let tick: (CADisplayLink) -> Void
    init(_ tick: @escaping (CADisplayLink) -> Void) { self.tick = tick }
    @objc func step(_ link: CADisplayLink) { tick(link) }
}

/// CPU time used so far by the main thread and by the whole process, in milliseconds.
struct CPUTimes {
    var main: Double
    var process: Double

    init(main: Double, process: Double) { self.main = main; self.process = process }

    init(mainThread: thread_act_t) {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(mainThread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        func ms(_ value: time_value_t) -> Double { Double(value.seconds) * 1000 + Double(value.microseconds) / 1000 }
        func ms(_ value: timeval) -> Double { Double(value.tv_sec) * 1000 + Double(value.tv_usec) / 1000 }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        main = result == KERN_SUCCESS ? ms(info.user_time) + ms(info.system_time) : 0
        process = ms(usage.ru_utime) + ms(usage.ru_stime)
    }

    static func - (left: CPUTimes, right: CPUTimes) -> CPUTimes {
        CPUTimes(main: left.main - right.main, process: left.process - right.process)
    }
}
