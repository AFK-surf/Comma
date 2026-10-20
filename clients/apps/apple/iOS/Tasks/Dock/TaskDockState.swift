import SwiftUI
import Observation
import CommaCore

/// The dock's state shared with its SwiftUI content. Owned by the dock controller, so its drag, collapse
/// and grabber follow it without a SwiftUI round trip, and the hosted views never need replacing.
@MainActor @Observable
final class TaskDockState {
    var detailsOpen = false {
        didSet { if detailsOpen != oldValue { onDetailsChange?(detailsOpen) } }
    }
    /// The header title is held down: the closed card shows its pressed surface.
    var titlePressed = false
    /// What sits under the transcript: the Home indicator, or the keyboard while it is up.
    var bottomInset: CGFloat = 0
    /// What sits at either side of the transcript: in landscape, the sensor housing on one side and its mirror on
    /// the other, so nothing (the composer's + least of all) lies under the Dynamic Island.
    var sideInset: CGFloat = 0
    /// The sheet rests minimized, so its cover hides the transcript and the transcript's loops can rest.
    var covered = false {
        didSet { if covered != oldValue { onCoveredChange?(covered) } }
    }
    @ObservationIgnored var onDetailsChange: ((Bool) -> Void)?
    @ObservationIgnored var onCoveredChange: ((Bool) -> Void)?
    /// Top of the resting title capsule, from the sheet's top edge; the grabber centres above it.
    @ObservationIgnored var capsuleTop: CGFloat = 12 {
        didSet { if capsuleTop != oldValue { onCapsuleTopChange?() } }
    }
    @ObservationIgnored var onCapsuleTopChange: (() -> Void)?
}

/// What the header asks of the dock controller.
struct TaskDockActions {
    /// Raises a minimized sheet, or minimizes a raised one.
    var toggle: () -> Void = {}
    /// The title: opens or closes the details while raised, raises the sheet while minimized.
    var titleTapped: () -> Void = {}
    var close: () -> Void = {}
    /// Slides the sheet away as `close` does, then archives the Task.
    var archive: (TaskSummary) -> Void = { _ in }
}

/// A button whose own press state drives the details card rather than the label alone.
struct PressReportingButtonStyle: ButtonStyle {
    let onPress: (Bool) -> Void
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.onChange(of: configuration.isPressed) { _, pressed in onPress(pressed) }
    }
}

/// The title's press response, shared by the title and the surface behind it so both grow together:
/// at once on touch-down, and back without a bounce on release (a tap carries no momentum).
enum TaskTitlePress {
    static let scale: CGFloat = 1.04
    static func animation(_ pressed: Bool) -> Animation {
        pressed ? .easeOut(duration: 0.08) : CommaMotion.release
    }
}

/// The coordinate space of the details card, which the header's title reports its frame in.
let taskDetailsCardSpace = "taskDetailsCard"

/// The header title's frame, where the closed card starts its growth.
struct TaskTitleFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}
