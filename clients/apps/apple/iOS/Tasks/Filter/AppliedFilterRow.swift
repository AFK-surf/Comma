import SwiftUI
import CommaCore

/// One narrowing field, read as a sentence on its own rounded row: "Status is Done", or "is any of"
/// with two option chips and "+N" for the rest. Tapping the row opens the field's options; the x stops the
/// field narrowing.
struct AppliedFilterRow: View {
    let field: TaskListFilter.Field
    let chosen: [TaskFilterOption]
    let open: () -> Void
    let remove: () -> Void
    @ScaledMetric(relativeTo: .body) private var height = GroupedSurface.rowHeight
    @ScaledMetric(relativeTo: .subheadline) private var glyphSize: CGFloat = 16

    private static let shownChips = 2

    var body: some View {
        Button(action: open) {
            FlowLayout(spacing: 8) {
                Text(field.title).font(.body).foregroundStyle(CommaTheme.textPrimary)
                chip { Text(chosen.count > 1 ? "is any of" : "is").foregroundStyle(CommaTheme.textQuaternary) }
                if chosen.isEmpty {
                    chip { Text("None") }
                }
                ForEach(chosen.prefix(Self.shownChips)) { option in
                    chip {
                        TaskFilterGlyph(glyph: option.glyph, size: glyphSize)
                        Text(option.name)
                    }
                }
                if chosen.count > Self.shownChips {
                    chip { Text(verbatim: "+" + (chosen.count - Self.shownChips).formatted()) }
                }
            }
            // The trailing inset keeps the chips clear of the x laid over the row.
            .padding(.leading, GroupedSurface.inset).padding(.trailing, 44).padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(SurfaceRowButtonStyle())
        .accessibilityIdentifier("appliedFilter-" + field.rawValue)
        .overlay(alignment: .trailing) {
            Button(action: remove) {
                CentralIcon("icon-close", size: 18, relativeTo: .body)
                    .foregroundStyle(CommaTheme.textSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(TactileButtonStyle(scale: 0.88))
            .accessibilityLabel(Text("Remove \(Text(field.title)) filter"))
            .accessibilityIdentifier("removeFilter-" + field.rawValue)
        }
        .background(GroupedSurface.surface)
        .clipShape(RoundedRectangle(cornerRadius: GroupedSurface.radius, style: .continuous))
    }

    /// A relation or an option on a capsule one step deeper than the row.
    private func chip<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 5) { content() }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(CommaTheme.textPrimary)
            .lineLimit(1)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(GroupedSurface.ink, in: Capsule())
    }
}
