import SwiftUI
import CommaCore

/// The menu's row and header heights, shared by the rows and the panel's height, so the panel knows its natural
/// height before it lays anything out, and the rows' glyph metrics, which the headers line up with. All grow with
/// Dynamic Type.
struct TriggerMenuMetrics: DynamicProperty {
    @ScaledMetric(relativeTo: .body) var rowHeight: CGFloat = 44
    @ScaledMetric(relativeTo: .subheadline) var headerHeight: CGFloat = 28
    /// A row's glyph and the slot it is centred in, as in the app's other Task rows.
    @ScaledMetric(relativeTo: .body) var glyphSize: CGFloat = 18
    @ScaledMetric(relativeTo: .body) var slot: CGFloat = 24
    static let inset: CGFloat = 6
    static let sectionGap: CGFloat = 6
    static let rowRadius: CGFloat = 18

    /// The panel's height with every row shown: its inset, the way back from a second level (`back`), each section's
    /// header and rows, and one more row for No results or Searching.
    func naturalHeight(of sections: [TriggerMenuSection], back: Bool = false) -> CGFloat {
        let rows = sections.reduce(0) { $0 + $1.items.count } + (back ? 1 : 0)
        let stateRow = sections.allSatisfy(\.items.isEmpty) || sections.contains(where: \.loading)
        return Self.inset * 2 + CGFloat(sections.count) * headerHeight + CGFloat(rows + (stateRow ? 1 : 0)) * rowHeight
            + Self.sectionGap * CGFloat(max(0, sections.count - 1))
    }

    /// The panel's greatest height with `spaceAbove` over the composer: five and a half rows and a header, so a
    /// cut-off row says there is more, within the 8pt gap above the composer and 8pt clear of the conversation's
    /// top. Nil when not even a header and a row fit (an iPhone in landscape with the keyboard up): the menu stays
    /// closed rather than show half a row, or rise into the chrome over the conversation, which takes its touches.
    func cap(below spaceAbove: CGFloat) -> CGFloat? {
        let room = spaceAbove - 16
        guard room >= Self.inset * 2 + headerHeight + rowHeight else { return nil }
        return min(Self.inset * 2 + headerHeight + rowHeight * 5.5, room)
    }
}

/// A section's name above its rows, as the desktop labels its groups, in the app's one section-header style (Home's
/// Tasks, the filter sheet's groups) in its ink for glass, its text lined up with the ink of the rows' glyphs.
struct TriggerMenuHeader: View {
    let title: LocalizedStringResource
    let metrics: TriggerMenuMetrics

    var body: some View {
        SurfaceCaption(Text(title), onGlass: true)
            .lineLimit(1)
            // The row's inset less the caption's own, then the glyph's margin in its slot.
            .padding(.leading, 6 + (metrics.slot - metrics.glyphSize) / 2).padding(.bottom, 4)
            .frame(maxWidth: .infinity, minHeight: metrics.headerHeight, maxHeight: metrics.headerHeight,
                   alignment: .bottomLeading)
    }
}

/// One choice: a Task with its status glyph, a model with the Task agent's sparkles, a skill with the desktop's cube,
/// or an agent command or a model's effort without a glyph; then its label and a muted detail. It lights the moment a
/// finger lands, like a native menu row. A model with efforts behind it (`browse`) ends in a chevron of its own, as a
/// table row's detail button: the row picks the model at its default effort, the chevron shows its efforts.
struct TriggerMenuRow: View {
    let item: TriggerMenuItem
    let metrics: TriggerMenuMetrics
    var browse: (() -> Void)? = nil
    let choose: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if let browse {
            // Over the row, so a touch on the chevron is the chevron's and the row lights to its edge.
            label.overlay(alignment: .trailing) {
                Button(action: browse) {
                    CentralIcon("central-chevron-right-small", size: 20, relativeTo: .body)
                        .foregroundStyle(CommaTheme.textTertiary)
                        .frame(width: metrics.rowHeight, height: metrics.rowHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(TriggerMenuRowStyle())
                .accessibilityLabel(Text("Thinking effort"))
                .accessibilityIdentifier("menu-" + item.id + "/efforts")
            }
        } else {
            label
        }
    }

    private var label: some View {
        let large = typeSize.isAccessibilitySize
        return Button(action: choose) {
            HStack(alignment: .center, spacing: 10) {
                // A command has no glyph, as on the desktop, nor a model's effort: its name starts where a glyph's
                // ink would, on the same edge as its section's header.
                if !item.isBare { icon.frame(width: metrics.slot, height: metrics.slot) }
                // The detail sits on the label's baseline. At accessibility sizes it would be cut to an ellipsis,
                // so it leaves the row; VoiceOver still reads it as the hint. The name there takes a second line
                // within the row's scaled height, and shrinks a little before it is cut.
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(verbatim: item.label)
                        .font(.body).foregroundStyle(CommaTheme.textPrimary)
                        .lineLimit(large ? 2 : 1).minimumScaleFactor(large ? 0.8 : 1).layoutPriority(1)
                    if let detail = item.detail, !large {
                        // Glass lowers the contrast of what sits on it: the deeper muted ink keeps 4.5:1.
                        Text(verbatim: detail)
                            .font(.footnote).foregroundStyle(CommaTheme.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            // The chevron's room, which the label never runs under.
            .padding(.trailing, browse == nil ? 0 : metrics.rowHeight - 10)
            .padding(.leading, item.isBare ? (metrics.slot - metrics.glyphSize) / 2 : 0)
            .frame(height: metrics.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(TriggerMenuRowStyle())
        .hoverEffect(.highlight)
        .accessibilityLabel(Text(verbatim: item.label))
        .accessibilityIdentifier("menu-" + item.id)
        .modifier(RowAccessibility(kind: item.kind, detail: item.detail))
        .accessibilityActions {
            if let browse { Button("Thinking effort", action: browse) }
        }
    }

    @ViewBuilder private var icon: some View {
        switch item.kind {
        case .task(_, _, let bucket):
            TaskStatusIcon(bucket: bucket, size: metrics.glyphSize, spins: false)
        case .model:
            CentralIcon("central-sparkles-two", size: 18, relativeTo: .body).foregroundStyle(CommaTheme.sidebarIcon)
        case .skill:
            CentralIcon("central-3d-box-top", size: 18, relativeTo: .body).foregroundStyle(CommaTheme.sidebarIcon)
        case .effort, .command:
            EmptyView()
        }
    }
}

/// No results, or Searching while a source loads, on the rows' grid.
struct TriggerMenuStateRow: View {
    let loading: Bool
    let height: CGFloat

    var body: some View {
        Group {
            if loading {
                ShimmerText(text: String(localized: "Searching…"), font: .body)
                    .accessibilityIdentifier("composerMenuSearching")
            } else {
                Text("No results").font(.body).foregroundStyle(CommaTheme.textTertiary)
                    .accessibilityIdentifier("composerMenuEmpty")
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
    }
}

/// The light lands at once, as on touch-down in a native menu; only its fade-out is animated. No haptic: a row
/// commits on release, like a tap.
private struct TriggerMenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(CommaTheme.textPrimary.opacity(configuration.isPressed ? 0.06 : 0),
                        in: RoundedRectangle(cornerRadius: TriggerMenuMetrics.rowRadius, style: .continuous))
            .animation(configuration.isPressed ? nil : .easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// The way back from a model's efforts to the list it was opened from: the model's name after a back chevron, as a
/// navigation bar's back button reads, on the rows' grid with the chevron in the glyph's slot.
struct TriggerMenuBackRow: View {
    let back: TriggerMenuBack
    let metrics: TriggerMenuMetrics

    var body: some View {
        Button(action: back.action) {
            HStack(alignment: .center, spacing: 10) {
                CentralIcon("central-chevron-right-small", size: 20, relativeTo: .body)
                    .scaleEffect(x: -1, y: 1)
                    .foregroundStyle(CommaTheme.textTertiary)
                    .frame(width: metrics.slot, height: metrics.slot)
                Text(verbatim: back.title)
                    .font(.body.weight(.semibold)).foregroundStyle(CommaTheme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: metrics.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(TriggerMenuRowStyle())
        .hoverEffect(.highlight)
        .accessibilityLabel(Text("Back"))
        .accessibilityValue(Text(verbatim: back.title))
        .accessibilityIdentifier("composerMenuBack")
    }
}

/// A second level the menu shows in place of its list, under the way back to the list.
struct TriggerMenuBack {
    let title: String
    let action: () -> Void
}

/// A Task reads its status as the value; a skill or command its detail as the hint.
private struct RowAccessibility: ViewModifier {
    let kind: TriggerMenuItem.Kind
    let detail: String?

    func body(content: Content) -> some View {
        if case .task(_, _, let bucket) = kind {
            content.accessibilityValue(Text(bucket.label))
        } else {
            content.accessibilityHint(detail.map { Text(verbatim: $0) } ?? Text(verbatim: ""))
        }
    }
}
