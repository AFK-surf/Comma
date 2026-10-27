import Foundation
import notify

/// Darwin notifications from `PerfScenarios` to the fixture. The test runner and the app run in the same
/// simulator, so a post reaches the fixture without a touch or a UI query that would land in the measurement.
enum PerfSignal: String, CaseIterable, Sendable {
    /// Starts a measured window in `FramePacingProbe`.
    case begin
    /// Ends it; the probe publishes the window's summary on the fixture's `framePacing` element.
    case end
    /// Starts the drafted reply of a `--perf-stream` launch.
    case stream
    /// Ends the failures `--fail-task-list` and `--fail-task-open` started: the fixture answers those reads again.
    case recover
    /// Lets the profile save `--hold-first-profile-save` holds answer.
    case releaseSave
    /// Lets the reads of earlier router messages `--hold-earlier` holds answer.
    case releaseEarlier

    var name: String { "surf.comma.perf." + rawValue }

    func post() { _ = notify_post(name) }
}
