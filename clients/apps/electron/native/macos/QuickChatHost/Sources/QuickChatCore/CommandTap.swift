import Foundation

/// Recognizes taps of ⌘: either Command key pressed and released within
/// `maximumPress`, with no other key, click, scroll or modifier meanwhile.
/// It fires on the release. A second tap that starts within `maximumGap` of
/// the first one's release, with nothing else between them, is a double tap.
///
/// A global `flagsChanged` monitor sees ⌘ without any permission, but key-down
/// events need Accessibility. A chord such as ⌘C, ⌘Tab or ⌘-scroll therefore
/// shows up only as a change in the session's key-down, mouse-down and scroll
/// counters, which also need no permission; a changed counter makes the press
/// a chord, not a tap.
public struct CommandTap: Sendable {
    /// The session's input counters at a moment.
    public struct Activity: Equatable, Sendable {
        public var keyDowns: UInt32
        public var mouseDowns: UInt32
        public var scrolls: UInt32

        public init(keyDowns: UInt32, mouseDowns: UInt32, scrolls: UInt32) {
            self.keyDowns = keyDowns
            self.mouseDowns = mouseDowns
            self.scrolls = scrolls
        }
    }

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

    private var pressed: (at: TimeInterval, activity: Activity)?
    /// The release of a single tap that a second one can still complete.
    private var released: (at: TimeInterval, activity: Activity)?

    public init() {}

    /// Feeds one modifier change; returns the tap it completes.
    public mutating func handle(_ event: Event, at time: TimeInterval, activity: Activity) -> Tap? {
        switch (pressed, event) {
        case (nil, .commandDown):
            pressed = (time, activity)
            return nil
        case let (press?, .commandUp):
            pressed = nil
            guard time - press.at <= Self.maximumPress, activity == press.activity else {
                released = nil
                return nil
            }
            if let first = released, press.at - first.at <= Self.maximumGap, press.activity == first.activity {
                released = nil
                return .double
            }
            released = (time, activity)
            return .single
        case (nil, .commandUp):
            // macOS repeats some releases; those change nothing.
            return nil
        default:
            // Another modifier, or the other ⌘ while one is held (a chord).
            pressed = nil
            released = nil
            return nil
        }
    }
}
