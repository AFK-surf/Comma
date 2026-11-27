import SwiftUI

/// What the router's circle shows over the bar's own glyph: the logo animation while Comma replies, and the mark
/// itself while the circle travels in a zoom, away from the bar. The unread count sits in `RouterBadgeOverlay`
/// outside the zoom's clipped source view so its overhanging rim badge is never clipped by the circle.
struct RouterCircleOverlay: View {
    var replying = false
    /// At rest the bar's glyph is the mark, so it presses, dims and enlarges with the other tabs.
    var restingMark = false

    var body: some View {
        ZStack {
            if replying || restingMark {
                RouterMark(replying: replying, size: Self.markSide, ink: .primary.opacity(0.96)).transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(CommaMotion.stateChange, value: replying)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The mark's side in the circle, the bar's glyph and the animation alike.
    static let markSide: CGFloat = 26
}

/// The router circle's unread count, hosted outside the zoom transition's source view so UIKit's circular morph
/// portal never clips the badge straddling the top-trailing rim.
struct RouterBadgeOverlay: View {
    var unread = 0
    var visible = true

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topTrailing) { CountBadge(count: visible ? unread : 0) }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// A count on the circle's rim, as on an app icon: centred on the edge at its top-trailing diagonal, growing
/// toward the leading side for longer numbers. It pops in and out, and its digits roll as the count changes.
/// Like the circle under it, it stops growing at the largest standard text size; the circle's value reads the
/// count to VoiceOver.
struct CountBadge: View {
    let count: Int

    var body: some View {
        CountBadgeContent(count: count).dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }
}

/// The badge itself, under `CountBadge`'s text-size cap: its scaled height reads the capped size, so the capsule
/// never outgrows the circle it sits on.
private struct CountBadgeContent: View {
    let count: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .caption) private var height: CGFloat = 18

    var body: some View {
        ZStack {
            if count > 0 {
                Text(count > 99 ? "99+" : "\(count)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .contentTransition(.numericText(value: Double(count)))
                    .padding(.horizontal, 5)
                    .frame(minWidth: height, minHeight: height)
                    .background(CommaTheme.brandSolid, in: Capsule())
                    .transition(reduceMotion ? .opacity : .scaleUnseenBelowHalf(0.4))
            }
        }
        // The badge's centre sits on the rim: 9pt in from the circle's top-trailing corner each way.
        .alignmentGuide(.trailing) { $0[HorizontalAlignment.center] + 9 }
        .alignmentGuide(.top) { $0[VerticalAlignment.center] - 9 }
        .animation(CommaMotion.settle(reduced: reduceMotion), value: count)
    }
}
