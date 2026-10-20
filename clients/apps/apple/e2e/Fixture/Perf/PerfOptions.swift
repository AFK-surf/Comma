import Foundation

/// The perf scenarios' fixture switches, read from launch arguments. Without them the fixture behaves as before:
/// 30 short router messages, event streams that finish at once and no frame probe.
struct PerfOptions: Sendable {
    /// `--perf-long-chat`: the router chat holds `PerfChat`'s 150 Markdown messages instead of 30 lines.
    var longChat = false
    /// `--perf-hold-stream`: event streams stay open after their snapshot, as a live server's do, instead of
    /// finishing at once and making every pane reconnect each 250 ms.
    var holdStream = false
    /// `--perf-stream`: after its snapshot the router stream waits for `PerfSignal.stream`, then drafts a reply.
    var stream = false
    /// `--perf-latency=<ms>`: the delay before each response and each stream.
    var latency: Duration = .zero
    /// `--perf-probe`: `FramePacingProbe` listens for the tests' begin and end signals.
    var probe = false

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        longChat = arguments.contains("--perf-long-chat")
        holdStream = arguments.contains("--perf-hold-stream")
        stream = arguments.contains("--perf-stream")
        probe = arguments.contains("--perf-probe")
        let prefix = "--perf-latency="
        if let argument = arguments.first(where: { $0.hasPrefix(prefix) }), let ms = Int(argument.dropFirst(prefix.count)) {
            latency = .milliseconds(ms)
        }
    }
}
