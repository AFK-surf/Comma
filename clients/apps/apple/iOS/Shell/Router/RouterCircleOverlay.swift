import SwiftUI

/// What the router's circle in the tab bar shows over the bar's own glyph, where the bar cannot draw it: the logo
/// animation while the router thinks or streams a reply (the bar's glyph is still), and the count of replies not
/// yet seen on its rim (a badge the bar draws on the circle is clipped by it).
struct RouterCircleOverlay: View {
    var replying = false
    var unread = 0

    var body: some View {
        ZStack {
            if replying {
                CommaLogoAnimation(ink: CommaTheme.textPrimary, aperture: CommaTheme.bgPrimary)
                    .frame(width: Self.markSide, height: Self.markSide)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) { CountBadge(count: unread) }
        .animation(CommaMotion.stateChange, value: replying)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The mark's side in the circle, the bar's glyph and the animation alike.
    static let markSide: CGFloat = 26
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
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.4).combined(with: .opacity))
            }
        }
        // The badge's centre sits on the rim: 9pt in from the circle's top-trailing corner each way.
        .alignmentGuide(.trailing) { $0[HorizontalAlignment.center] + 9 }
        .alignmentGuide(.top) { $0[VerticalAlignment.center] - 9 }
        .animation(CommaMotion.settle(reduced: reduceMotion), value: count)
    }
}
