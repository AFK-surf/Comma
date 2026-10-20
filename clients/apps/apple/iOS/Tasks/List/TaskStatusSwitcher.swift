import SwiftUI
import CommaCore

/// The floating status switcher above the tab bar: In progress, Needs review, Done and Cancelled in one
/// glass capsule. The chosen status shows its name on a grey pill and the others share the remaining width as glyphs,
/// so all four fit on a phone. A filter that is not exactly one of these statuses highlights none.
/// A touch chooses the status under the finger at once. Once the finger moves along the switcher it scrubs
/// (`ScrubHold`): it passes from status to status at one steady pace, choosing each it is past halfway to, and
/// `scrub` hears where it is, in statuses, so the list can move with it; it hears nil once the finger lets go.
/// Dragging well away stops following and keeps the status last chosen.
struct TaskStatusSwitcher: View {
    let selection: TaskBucket?
    let select: (TaskBucket) -> Void
    var scrub: (CGFloat?) -> Void = { _ in }
    /// Each segment's frame in the switcher, for finding the one under the finger.
    @State private var frames: [TaskBucket: CGRect] = [:]
    /// Counts the switcher's own choices, for a tick on each; a status chosen elsewhere (the filter sheet) plays none.
    @State private var choices = 0
    /// The finger scrubbing, once it has moved along the switcher.
    @State private var hold: ScrubHold?
    /// Whether a finger is on the switcher; it lets go of the scrub however the touch ends, lifted or cancelled.
    @GestureState private var touching = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Fixed at every text size, like the tab bar under it.
    static let height: CGFloat = 48
    private static let inset: CGFloat = 4
    private nonisolated static let space = "statusSwitcher"
    private static let order = TaskBucket.homeStatuses
    /// How far past halfway to a status the finger goes before it is chosen, in statuses, so a finger resting on
    /// the way between two does not flicker between them.
    private static let hysteresis: CGFloat = 0.08

    private var settle: Animation { CommaMotion.settle(reduced: reduceMotion) }
    private var glyphOnly: Bool { typeSize.isAccessibilitySize }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Self.order, id: \.self) { segment($0) }
        }
        .padding(Self.inset)
        .frame(height: Self.height)
        .coordinateSpace(.named(Self.space))
        // The chosen status's pill, on its segment's bounds in the same layout pass, so it glides with the
        // segments as they trade width.
        .backgroundPreferenceValue(SegmentBounds.self, alignment: .topLeading) { bounds in
            GeometryReader { proxy in
                if let selection, let anchor = bounds[selection] {
                    pill(in: proxy[anchor]).id(reduceMotion ? selection : nil)
                }
            }
        }
        // Plain glass: the interactive kind lights the whole capsule under a touch. The pill is the answer.
        .commaGlass(in: Capsule())
        .contentShape(Capsule())
        .gesture(choose)
        .onChange(of: touching) { _, now in
            guard !now else { return }
            hold = nil
            scrub(nil)
        }
        .sensoryFeedback(.selection, trigger: choices)
        .animation(settle, value: selection)
        .accessibilityElement(children: .contain)
    }

    private func segment(_ bucket: TaskBucket) -> some View {
        let selected = bucket == selection
        // At accessibility sizes every segment is a glyph, and Large Content Viewer names it on a long press.
        let named = selected && !glyphOnly
        // The glyph and the name are always there, so they slide together as the segments trade width: the name
        // opens out of the glyph's trailing side as the pill opens over it, and folds back into it.
        return HStack(spacing: 0) {
            TaskStatusIcon(bucket: bucket, size: 20, spins: false)
            Text(bucket.label).font(.subheadline.weight(.medium)).foregroundStyle(CommaTheme.textPrimary)
                .lineLimit(1).fixedSize()
                .opacity(named ? 1 : 0).blur(radius: named ? 0 : 4)
                .padding(.leading, named ? 6 : 0)
                .frame(width: named ? nil : 0, alignment: .leading)
        }
        .padding(.horizontal, named ? 14 : 0)
        .frame(minWidth: named ? nil : 36, maxWidth: named ? nil : .infinity)
        .frame(height: Self.height - Self.inset * 2)
        .clipShape(Capsule())
        // Folded, the name hangs past the segment unseen; VoiceOver finds the segment as drawn.
        .contentShape(.accessibility, Capsule())
        .anchorPreference(key: SegmentBounds.self, value: .bounds) { [bucket: $0] }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { frames[bucket] = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(bucket.label))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { select(bucket) }
        .accessibilityShowsLargeContentViewer {
            Label { Text(bucket.label) } icon: { TaskStatusIcon(bucket: bucket, spins: false) }
        }
    }

    /// The chosen status's grey pill, the tab bar's.
    private func pill(in frame: CGRect) -> some View {
        Capsule().fill(CommaTheme.glassSelection)
            .frame(width: frame.width, height: frame.height)
            .offset(x: frame.minX, y: frame.minY)
            .transition(.opacity)
    }

    /// Chooses the status under the finger the moment it lands. Once the finger moves along the switcher it
    /// scrubs from the status chosen there, choosing each status its place is past halfway to.
    private var choose: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .updating($touching) { _, touching, _ in touching = true }
            .onChanged { value in
                let x = value.location.x
                guard !cancels(value.location) else {
                    hold = nil
                    return scrub(nil)
                }
                guard var current = hold ?? startHold(at: x, moved: abs(value.translation.width)) else { return }
                let place = current.place(at: x)
                let nearest = min(max(Int(place.rounded()), 0), Self.order.count - 1)
                if nearest != current.chosen, abs(place - CGFloat(current.chosen)) >= 0.5 + Self.hysteresis {
                    current.chosen = nearest
                    choose(Self.order[nearest])
                }
                hold = current
                scrub(place)
            }
    }

    /// Before the finger has moved a few points it only chooses what it is on, as a tap would; after, it holds
    /// the switcher from where it is, on the status chosen.
    private func startHold(at x: CGFloat, moved: CGFloat) -> ScrubHold? {
        let touched = bucket(at: x)
        if let touched, touched != selection { choose(touched) }
        guard moved >= 4, let chosen = (touched ?? selection).flatMap({ Self.order.firstIndex(of: $0) }) else {
            return nil
        }
        return ScrubHold(at: x, chosen: chosen, segments: Self.order.compactMap { frames[$0] })
    }

    private func choose(_ bucket: TaskBucket) {
        choices += 1
        select(bucket)
    }

    /// The segment under `x`; past either end, the end segment.
    private func bucket(at x: CGFloat) -> TaskBucket? {
        let order = Self.order.compactMap { bucket in frames[bucket].map { (bucket, $0) } }
        guard let first = order.first, let last = order.last else { return nil }
        if x < min(first.1.minX, last.1.minX) { return first.1.minX < last.1.minX ? first.0 : last.0 }
        if x >= max(first.1.maxX, last.1.maxX) { return first.1.maxX > last.1.maxX ? first.0 : last.0 }
        return order.first { x >= $0.1.minX && x < $0.1.maxX }?.0
    }

    /// A finger dragged well above or below the capsule stops choosing.
    private func cancels(_ location: CGPoint) -> Bool {
        location.y < -44 || location.y > Self.height + 44
    }
}

/// A finger scrubbing along the switcher. Each status owns an equal share of the capsule, whatever width it shows,
/// so the finger goes from status to status at one steady pace, and the chosen status's pill, which is always wider
/// than a share, stays under it. The finger's place, in statuses, starts on the status chosen where it took hold, so
/// nothing jumps as it starts, and reaches the first and last statuses at the middles of their shares; past those
/// it goes on at a share per status.
private struct ScrubHold {
    /// The capsule along the finger's way: where the first status's share starts, which way the statuses run,
    /// and a share's width.
    private let leading: CGFloat
    private let direction: CGFloat
    private let share: CGFloat
    private let last: CGFloat
    /// Where the finger took hold, along the way, and the status chosen then.
    private let start: CGFloat
    private let origin: CGFloat
    /// The status chosen now.
    var chosen: Int

    init?(at x: CGFloat, chosen: Int, segments: [CGRect]) {
        guard segments.count == TaskBucket.homeStatuses.count, let first = segments.first, let end = segments.last,
              let minX = segments.map(\.minX).min(), let maxX = segments.map(\.maxX).max() else { return nil }
        direction = first.midX <= end.midX ? 1 : -1
        leading = direction > 0 ? minX : maxX
        share = (maxX - minX) / CGFloat(segments.count)
        last = CGFloat(segments.count - 1)
        start = (x - leading) * direction
        origin = CGFloat(chosen)
        self.chosen = chosen
    }

    /// The finger's place at `x`, in statuses.
    func place(at x: CGFloat) -> CGFloat {
        let along = (x - leading) * direction
        let ahead = along >= start
        let end = ahead ? last : 0
        // The middle of the end status's share, which the finger's way to takes the place to that status.
        let middle = (end + 0.5) * share
        let room = (middle - start) * (ahead ? 1 : -1)
        guard end != origin, room >= share / 4 else { return origin + (along - start) / share }
        let reached = (along - start) / (middle - start)
        return reached <= 1 ? origin + (end - origin) * reached : end + (along - middle) / share
    }
}

/// Each segment's bounds, for the pill.
private struct SegmentBounds: PreferenceKey {
    static var defaultValue: [TaskBucket: Anchor<CGRect>] { [:] }
    static func reduce(value: inout [TaskBucket: Anchor<CGRect>], nextValue: () -> [TaskBucket: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}
