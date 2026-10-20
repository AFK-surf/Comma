import Foundation

/// One probe window's numbers. Intervals are the gaps between delivered frames; the refresh interval is the
/// display link's own median frame duration (16.7 ms at 60 Hz, 8.3 ms at 120 Hz).
struct FrameStats {
    let intervals: [Double]
    let refreshIntervals: [Double]
    let duration: Double
    let cpu: CPUTimes

    var refresh: Double { Self.percentile(refreshIntervals, 0.5) ?? 1.0 / 60 }
    /// Frames delivered later than 1.5 refresh intervals after the previous one.
    var hitches: [Double] { intervals.filter { $0 > refresh * 1.5 } }
    /// Each hitch's time past one refresh interval, in milliseconds.
    var hitchTime: Double { hitches.reduce(0) { $0 + ($1 - refresh) } * 1000 }
    /// Refreshes with no new frame from the main thread.
    var droppedFrames: Int { intervals.reduce(0) { $0 + max(0, Int(($1 / refresh).rounded()) - 1) } }

    func json(window: Int) -> String {
        // Decimals serialize as written, where a rounded Double prints 17 digits.
        func round(_ value: Double) -> Decimal { Decimal(string: String(format: "%.2f", value)) ?? 0 }
        func ms(_ seconds: Double?) -> Decimal { round((seconds ?? 0) * 1000) }
        let object: [String: Any] = [
            "window": window,
            "frames": intervals.count,
            "durationS": round(duration),
            "refreshMs": ms(refresh),
            "hitches": hitches.count,
            "hitchMs": round(hitchTime),
            // Apple's hitch time ratio: hitch milliseconds per second of the window.
            "hitchRatio": round(duration > 0 ? hitchTime / duration : 0),
            "droppedFrames": droppedFrames,
            "worstMs": ms(intervals.max()),
            "p50Ms": ms(Self.percentile(intervals, 0.5)),
            "p95Ms": ms(Self.percentile(intervals, 0.95)),
            "p99Ms": ms(Self.percentile(intervals, 0.99)),
            "mainCPUms": round(cpu.main),
            "processCPUms": round(cpu.process),
            "mainCPUPct": round(duration > 0 ? cpu.main / duration / 10 : 0),
        ]
        return String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
    }

    private static func percentile(_ values: [Double], _ fraction: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * fraction).rounded()))]
    }
}
