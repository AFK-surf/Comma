import SwiftUI

/// The Comma mark over two filled ripples that swell with the agent's voice as it plays. The inner one follows the
/// voice closely; the outer one is larger and slower, so loud syllables spread outward. Silence leaves only the mark.
struct CallAvatar: View {
    let level: Double
    let size: CGFloat

    var body: some View {
        ZStack {
            CallRipples(level: level, size: size)
            Circle().fill(CommaTheme.bgTertiary).frame(width: size, height: size)
            CommaMark(size: size * 0.5).foregroundStyle(CommaTheme.textPrimary)
        }
        .frame(width: size * 1.5, height: size * 1.5)
        .accessibilityHidden(true)
    }
}

/// Two filled circles behind an avatar of `size`, in the logo's colour, grown by the agent's voice `level` (0 to 1).
/// They change only how they draw, not the layout, so a small avatar can carry them inside a tight frame.
struct CallRipples: View {
    let level: Double
    let size: CGFloat
    /// Scales how far the ripples reach; the bubble's small avatar uses less, so they stay clear of its timer.
    var spread: Double = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            ripple(reach: 0.5 * spread, opacity: 0.08)
                .animation(.easeOut(duration: 0.35), value: level)
            ripple(reach: 0.26 * spread, opacity: 0.14)
                .animation(.easeOut(duration: 0.12), value: level)
        }
    }

    /// Grows past the avatar by up to `reach` of its size at full voice. With reduced motion it keeps a fixed size and
    /// only brightens.
    private func ripple(reach: Double, opacity: Double) -> some View {
        Circle()
            .fill(CommaTheme.textPrimary.opacity(reduceMotion ? opacity * level * 2 : opacity))
            .frame(width: size, height: size)
            .scaleEffect(reduceMotion ? 1 + reach * 0.6 : 1 + reach * level)
    }
}

/// An SF Symbol at a fixed point size, for glyphs inside fixed-size call controls.
struct CallSymbol: View {
    let name: String
    let size: CGFloat
    init(_ name: String, size: CGFloat) { self.name = name; self.size = size }
    var body: some View {
        Image(systemName: name).font(.system(size: size, weight: .medium)).accessibilityHidden(true)
    }
}
