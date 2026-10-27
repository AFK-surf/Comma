import Observation
import QuartzCore
import UIKit

/// Fixture-only (`--transcript-probe`): reads each chat transcript's scroll view on every frame and
/// counts what the reader would see go wrong. A jump is a frame in which the content height changes by more than
/// `jumpLimit`, as a lazy stack's estimate of the rows it has not built does when it swings. A drift is a frame in
/// which the content height changes under the reader's finger or momentum, as a lazy stack's does when it builds rows it
/// had estimated; measured rows keep it as it is. A blank frame is one in
/// which no scroll is under way and the visible area lies past the end of the content, so the screen shows none of it.
/// A content size that is itself a stale estimate hides a blank screen from the probe; the tests also check that the
/// rows they expect are on screen. A growth is a frame in which the content grows by more than `jumpLimit` while the
/// reader is away from its end; it is held when the offset grows by as much in the same frame, late when it does in
/// one of the next three, and unheld when it does not, as when rows join above the reader without holding their place.
/// The counts since launch are the value of the fixture's `transcriptGeometry` element, a few times a second.
@MainActor @Observable final class TranscriptGeometryProbe {
    private(set) var summary = "frames=0|jumps=0|maxJump=0|drift=0|blank=0|maxPast=0|growths=0|late=0|unheld=0"

    @ObservationIgnored private var link: CADisplayLink?
    @ObservationIgnored private var heights: [ObjectIdentifier: CGFloat] = [:]
    @ObservationIgnored private var offsets: [ObjectIdentifier: CGFloat] = [:]
    @ObservationIgnored private var frames = 0
    @ObservationIgnored private var jumps = 0
    @ObservationIgnored private var blank = 0
    @ObservationIgnored private var maxJump: CGFloat = 0
    @ObservationIgnored private var maxPast: CGFloat = 0
    @ObservationIgnored private var drift = 0
    @ObservationIgnored private var growths = 0
    @ObservationIgnored private var late = 0
    @ObservationIgnored private var unheld = 0
    /// A growth away from the end not yet matched by the offset: the height it added, the offset before it, and the
    /// frames since.
    @ObservationIgnored private var pending: [ObjectIdentifier: (growth: CGFloat, offset: CGFloat, frames: Int)] = [:]
    @ObservationIgnored private var published: CFTimeInterval = 0
    /// The transcripts found by the last walk of the windows, which runs twice a second rather than every frame.
    @ObservationIgnored private var found: [Weak] = []
    @ObservationIgnored private var walked: CFTimeInterval = 0

    /// A send's row, a reply's growth or a resize changes the height by far less.
    static let jumpLimit: CGFloat = 1_500

    init() {
        let link = CADisplayLink(target: ProbeLinkTarget { [weak self] in self?.sample($0) }, selector: #selector(ProbeLinkTarget.step))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func sample(_ link: CADisplayLink) {
        if link.timestamp - walked > 0.5 {
            walked = link.timestamp
            let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
            found = windows.flatMap { Self.transcripts(in: $0) }.map(Weak.init)
        }
        for scrollView in found.compactMap(\.view) where scrollView.window != nil {
            frames += 1
            let id = ObjectIdentifier(scrollView)
            let height = scrollView.contentSize.height
            let offset = scrollView.contentOffset.y
            if let wait = pending[id] {
                if abs(offset - wait.offset - wait.growth) < 50 {
                    if wait.frames > 0 { late += 1 }
                    pending[id] = nil
                } else if wait.frames >= 3 {
                    unheld += 1
                    pending[id] = nil
                } else {
                    pending[id] = (wait.growth, wait.offset, wait.frames + 1)
                }
            }
            let scrolling = scrollView.isDragging || scrollView.isDecelerating || scrollView.isTracking
            // The first layout of a transcript fills it from nothing, which is no jump.
            if let before = heights[id], before > 0 {
                let change = abs(height - before)
                if change > 0.5, scrolling { drift += 1 }
                maxJump = max(maxJump, change)
                if change > Self.jumpLimit { jumps += 1 }
                let awayFromEnd = before - (offsets[id] ?? 0) - scrollView.bounds.height > scrollView.bounds.height * 2
                if height - before > Self.jumpLimit, awayFromEnd {
                    growths += 1
                    if abs(offset - (offsets[id] ?? 0) - (height - before)) >= 50 {
                        pending[id] = (height - before, offsets[id] ?? 0, 0)
                    }
                }
            }
            offsets[id] = offset
            heights[id] = height
            // How far the visible area's top is past the content's end, insets counted.
            let past = scrollView.contentOffset.y + scrollView.adjustedContentInset.top - height
            if !scrolling, height > 0, past > 0 {
                blank += 1
                maxPast = max(maxPast, past)
            }
        }
        guard link.timestamp - published > 0.25 else { return }
        published = link.timestamp
        summary = "frames=\(frames)|jumps=\(jumps)|maxJump=\(Int(maxJump))|drift=\(drift)|blank=\(blank)|maxPast=\(Int(maxPast))"
            + "|growths=\(growths)|late=\(late)|unheld=\(unheld)"
    }

    private static func transcripts(in view: UIView) -> [UIScrollView] {
        // A transcript is the scroll view that dismisses the keyboard as soon as it is dragged
        // (`scrollDismissesKeyboard(.immediately)`); no other one is on screen in the tests that read the probe.
        if let scrollView = view as? UIScrollView, scrollView.keyboardDismissMode == .onDragWithAccessory, scrollView.window != nil {
            return [scrollView]
        }
        return view.subviews.flatMap { transcripts(in: $0) }
    }
}

private struct Weak {
    weak var view: UIScrollView?
    init(_ view: UIScrollView) { self.view = view }
}

/// CADisplayLink retains its target; this one holds the probe weakly through its closure.
@MainActor private final class ProbeLinkTarget: NSObject {
    let tick: (CADisplayLink) -> Void
    init(_ tick: @escaping (CADisplayLink) -> Void) { self.tick = tick }
    @objc func step(_ link: CADisplayLink) { tick(link) }
}
