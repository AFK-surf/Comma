import Foundation

/// Recognizes taps of ⌘: either Command key pressed and released within
/// `maximumPress`, with no other key, click, scroll or modifier meanwhile.
/// It fires on the release. A second tap that starts within `maximumGap` of
/// the first one's release, with nothing else from the first press on, is a
/// double tap.
///
/// A global `flagsChanged` monitor sees ⌘ without any permission, but key-down
/// events need Accessibility. A chord such as ⌘C, ⌘Tab or ⌘-scroll therefore
/// shows up only as the time of the latest key-down, click or scroll, which
/// also needs no permission. Input at or after a press makes it a chord, not
/// a tap. The time is compared with the events' own timestamps, so a monitor
/// that runs late (after the C of a quick ⌘C already went down) still sees
/// the chord.
public struct CommandTap: Sendable {
    public enum Event: Sendable {
        /// ⌘ went down with no other modifier held.
        case commandDown
        /// ⌘ came up with no other modifier held.
        case commandUp
        /// Any other modifier changed, or one is held.
        case otherModifier
    }

    public enum Tap: Equatable, Sendable {
        case single
        /// The second tap of a pair; its first tap was reported as `single`.
        case double
    }

    public static let maximumPress: TimeInterval = 0.4
    public static let maximumGap: TimeInterval = 0.4

    private var pressed: TimeInterval?
    /// A single tap that a second one can still complete.
    private var first: (pressed: TimeInterval, released: TimeInterval)?

    public init() {}

    /// Feeds one modifier change at `time`; `lastInput` is when the latest
    /// key-down, click or scroll happened, on the same clock. Returns the tap
    /// it completes.
    public mutating func handle(_ event: Event, at time: TimeInterval, lastInput: TimeInterval) -> Tap? {
        switch (pressed, event) {
        case (nil, .commandDown):
            pressed = time
            return nil
        case let (press?, .commandUp):
            pressed = nil
            guard time - press <= Self.maximumPress, lastInput < press else {
                first = nil
                return nil
            }
            if let first, press - first.released <= Self.maximumGap, lastInput < first.pressed {
                self.first = nil
                return .double
            }
            first = (press, time)
            return .single
        case (nil, .commandUp):
            // macOS repeats some releases; those change nothing.
            return nil
        default:
            // Another modifier, or the other ⌘ while one is held (a chord).
            pressed = nil
            first = nil
            return nil
        }
    }
}
