import SwiftUI
import CommaCore
#if os(iOS)
import UIKit
#endif

// MARK: - Task status

extension Conversation {
    /// Only running work reports progress; the status icon already says where other tasks landed.
    var progressLabel: String? {
        guard bucket == .inProgress else { return nil }
        let activity = activityStatus?.replacingOccurrences(of: "_", with: " ").capitalized(with: .current)
        return activity.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "In progress")
    }

    var updatedLabel: String {
        guard let date = updatedDate else { return String(localized: "Updated recently") }
        return String(localized: "Updated \(date.formatted(.dateTime.month(.abbreviated).day()))")
    }

    /// Why the server will not archive the Task now, in the desktop's words; nil while it may.
    var archiveRefusal: LocalizedStringResource? {
        guard let availability = archiveAvailability, !availability.allowed else { return nil }
        switch availability.reason {
        case "not_finished": return "Finish the task before archiving"
        case "schedule_bound": return "Remove the recurring schedule before archiving"
        default: return "Task status is unavailable; refresh to try again"
        }
    }
}

extension View {
    /// An Archive action for `task`, alike in every list, swipe and menu: while the server refuses, it stays in
    /// place but disabled, and VoiceOver reads the reason as its hint.
    func archiveAvailability(of task: Conversation) -> some View {
        let refusal = task.archiveRefusal
        return disabled(refusal != nil).accessibilityHint(refusal.map { Text($0) } ?? Text(verbatim: ""))
    }
}

extension TaskBucket {
    /// The status's name, for `Text` and `String(localized:)` alike.
    var label: LocalizedStringResource {
        switch self {
        case .inProgress: "In progress"
        case .needsReview: "Needs review"
        case .done: "Done"
        case .cancelled: "Cancelled"
        case .archived: "Archived"
        }
    }
}

extension EnvironmentValues {
    /// Ambient loops (status spinners, shimmers, the thinking mark) hold still while their surface is
    /// covered, as a minimized Task's transcript is under its bar.
    @Entry var ambientMotionPaused = false
}

/// Status glyph with the desktop Task board colours. Only running work turns.
struct TaskStatusIcon: View {
    let bucket: TaskBucket
    var size: CGFloat = 18
    /// In-progress turns where it reports a running Task; a control that only names the status stays still.
    var spins = true
    var body: some View {
        Group {
            if bucket == .inProgress, spins {
                SpinningStatusGlyph(name: bucket.iconName, tint: bucket.tint)
            } else {
                Image(bucket.iconName).renderingMode(.template).resizable().interpolation(.high)
                    .foregroundStyle(bucket.tint)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

#if os(iOS)
/// In-progress turns slowly; with Reduce Motion it stays still. The turn runs in the render server, so a
/// screen of running Tasks costs the main thread nothing per frame.
private struct SpinningStatusGlyph: UIViewRepresentable {
    let name: String
    let tint: Color

    func makeUIView(context: Context) -> StatusSpinnerView { StatusSpinnerView() }

    func updateUIView(_ view: StatusSpinnerView, context: Context) {
        if view.name != name {
            view.name = name
            view.glyph.image = UIImage(named: name)?.withRenderingMode(.alwaysTemplate)
        }
        view.glyph.tintColor = UIColor(tint)
        view.running = !context.environment.accessibilityReduceMotion && !context.environment.ambientMotionPaused
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: StatusSpinnerView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 18, height: 18))
    }
}

private final class StatusSpinnerView: RenderLoopView {
    let glyph = UIImageView()
    var name = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        glyph.contentMode = .scaleAspectFit
        addSubview(glyph)
    }

    override var loopLayer: CALayer { glyph.layer }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Bounds and centre, not frame: the layer turns about its centre.
        glyph.bounds = bounds
        glyph.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    override func makeLoop() -> CABasicAnimation? {
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        turn.toValue = 2 * Double.pi
        turn.duration = 2.4
        return turn
    }
}

/// A view whose layer repeats one Core Animation loop in the render server, so the loop costs the main
/// thread nothing per frame, on screen or off. Every loop takes its phase from one shared clock: a restart
/// (back in a window, at a new size, back from the background) carries on where the loop would be, and
/// loops of one kind move together. Spinners, shimmers and the thinking bubble's breath build on it.
class RenderLoopView: UIView {
    private static let key = "loop"
    /// Off (Reduce Motion), the view rests at its model values.
    var running = true {
        didSet { if running != oldValue { restart() } }
    }
    /// The layer the loop animates.
    var loopLayer: CALayer { layer }
    /// The loop's one pass; nil while it cannot run yet (no size).
    func makeLoop() -> CABasicAnimation? { nil }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        NotificationCenter.default.addObserver(self, selector: #selector(restart),
                                               name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        restart()
    }

    @objc func restart() {
        loopLayer.removeAnimation(forKey: Self.key)
        guard running, window != nil, let loop = makeLoop() else { return }
        let cycle = loop.duration * (loop.autoreverses ? 2 : 1)
        loop.repeatCount = .infinity
        loop.isRemovedOnCompletion = false
        loop.timeOffset = CACurrentMediaTime().truncatingRemainder(dividingBy: cycle)
        loopLayer.add(loop, forKey: Self.key)
    }
}
#else
/// In-progress turns slowly; with Reduce Motion it stays still.
private struct SpinningStatusGlyph: View {
    let name: String
    let tint: Color
    @State private var turning = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Image(name).renderingMode(.template).resizable().interpolation(.high)
            .foregroundStyle(tint)
            .rotationEffect(.degrees(turning ? 360 : 0))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) { turning = true }
            }
    }
}
#endif
