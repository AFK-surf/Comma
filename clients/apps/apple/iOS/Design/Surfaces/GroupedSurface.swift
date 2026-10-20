import SwiftUI

/// The app's grouped rows, drawn rather than left to the system form so they look the same on every iOS version:
/// Settings, the filter sheets and the sheets drawn like them. Rows sit 14pt in from 24pt continuous corners and
/// are at least 50pt tall, on a surface one step off the page, split by hairlines where the page shows through;
/// groups keep 16pt from the page's edges. Controls on the surface take an ink overlay, like the desktop's alpha
/// tokens (black in light mode, white in dark), so they read one step deeper on whatever they sit.
enum GroupedSurface {
    static let inset: CGFloat = 14
    static let margin: CGFloat = 16
    static let rowHeight: CGFloat = 50
    static let radius: CGFloat = 24
    /// Between groups that no caption separates, such as the filter sheet's applied filters.
    static let groupSpacing: CGFloat = 8
    /// The page under the groups; in a sheet, the sheet's own surface (`commaSheet`'s) instead.
    static let page = CommaTheme.bgPrimary
    static let sheet = CommaTheme.cardPrimary
    static let surface = CommaTheme.bgTertiary
    /// A pressed row, and capsules on the surface (chips, the search field): one step deeper than it.
    static let ink = ink(0.06)

    /// The same ink at another strength, such as a checkbox's fill and outline.
    static func ink(_ amount: Double) -> Color { CommaTheme.textPrimary.opacity(amount) }
}

/// Rows on one rounded surface, split by hairlines where the page shows through. Rows that resolve to nothing
/// leave no empty group behind.
struct SurfaceGroup<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Group(subviews: content) { rows in
            if !rows.isEmpty {
                VStack(spacing: 2 / displayScale) {
                    ForEach(rows) { row in
                        row.frame(maxWidth: .infinity, alignment: .leading).background(GroupedSurface.surface)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: GroupedSurface.radius, style: .continuous))
            }
        }
    }
}

/// The small muted caption over a group, with an optional action at its end. Over Liquid Glass (`onGlass`), what
/// shows through the glass lowers its contrast, so it takes the next, deeper ink there and still reads at 4.5:1.
struct SurfaceCaption<Trailing: View>: View {
    let title: Text
    var onGlass = false
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            title.accessibilityAddTraits(.isHeader)
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(onGlass ? CommaTheme.textTertiary : CommaTheme.textQuaternary)
        .padding(.horizontal, 4)
    }
}

extension SurfaceCaption where Trailing == EmptyView {
    init(_ title: Text, onGlass: Bool = false) {
        self.init(title: title, onGlass: onGlass) { EmptyView() }
    }
}

/// A row on the surface that deepens the instant a finger lands and fades back on release.
struct SurfaceRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(GroupedSurface.ink.opacity(configuration.isPressed ? 1 : 0))
            .animation(configuration.isPressed ? nil : .easeOut(duration: 0.2), value: configuration.isPressed)
    }
}

extension View {
    /// A row's margins: the surface's inset at the sides, and at least the row height, which grows with the
    /// text. Taller content gets `vertical` above and below.
    func surfaceRowFrame(vertical: CGFloat = 10) -> some View { modifier(SurfaceRowFrame(vertical: vertical)) }
}

private struct SurfaceRowFrame: ViewModifier {
    let vertical: CGFloat
    @ScaledMetric(relativeTo: .body) private var height = GroupedSurface.rowHeight

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, GroupedSurface.inset).padding(.vertical, vertical)
            .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
            .contentShape(Rectangle())
    }
}
