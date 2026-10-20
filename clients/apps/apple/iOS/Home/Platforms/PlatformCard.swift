import SwiftUI
import CommaCore

/// A connected app on Home, as in the mock: its mark, then its name with how many pre-tasks wait for the member,
/// in the bottom-leading corner. Every card has the same bottom, so marks and names line up across the row; an
/// app connected more than once names the account in the empty top corner. Tapping the card opens the pre-tasks.
struct PlatformCard: View {
    let platform: PlatformRoutine
    /// Visible pre-tasks, shown after the name like the mock's "Slack 0".
    let count: Int
    /// While a new briefing is generated the cards stay and their counts are redacted.
    let refreshing: Bool
    let open: () -> Void
    @ScaledMetric(relativeTo: .body) private var minHeight: CGFloat = 104
    @Environment(\.dynamicTypeSize) private var typeSize

    static let radius: CGFloat = 20
    private static let tallestFloor: CGFloat = 140

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        Button(action: open) {
            VStack(alignment: .leading, spacing: 8) {
                ProviderLogo(source: platform.source, size: 28)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(platform.name).font(.body).foregroundStyle(CommaTheme.textPrimary)
                        // A long name wraps rather than cuts short at accessibility sizes.
                        .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                    Text(count, format: .number).font(.body.monospacedDigit())
                        .foregroundStyle(count > 0 ? CommaTheme.textSecondary : CommaTheme.textQuaternary)
                        .redacted(reason: refreshing ? .placeholder : [])
                        .fixedSize()
                    if needsReconnect {
                        // The desktop's warning glyph, sized with the name.
                        CentralIcon("central-exclamation-triangle", size: 16, relativeTo: .body)
                            .foregroundStyle(CommaTheme.attention)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .overlay(alignment: .topLeading) {
                if let account = platform.connectionLabel {
                    Text(verbatim: account).font(.footnote).foregroundStyle(CommaTheme.textQuaternary)
                        .lineLimit(1).padding(12)
                }
            }
            // The floor lines the cards up at standard sizes; at accessibility sizes the content sets the height,
            // so the mark does not float over an empty card.
            .frame(minHeight: min(minHeight, Self.tallestFloor))
            .background(CommaTheme.cardPrimary, in: shape)
            .overlay(shape.strokeBorder(CommaTheme.borderPrimary, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(TactileButtonStyle(scale: 0.96))
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(needsReconnect ? Text("Needs reconnecting") : Text(verbatim: ""))
        .accessibilityIdentifier("platform-" + platform.id)
    }

    private var needsReconnect: Bool { platform.source?.needsReconnect == true }

    /// "Slack, 3 suggested tasks" or "Slack, nothing new"; a repeated app also names its account.
    private var accessibilityLabel: Text {
        let name = [platform.name, platform.connectionLabel].compactMap { $0 }.joined(separator: ", ")
        return count > 0 ? Text("\(name), ^[\(count) suggested task](inflect: true)") : Text("\(name), nothing new")
    }

    /// A stand-in card for the first read of the briefing.
    static func placeholder(_ index: Int) -> some View {
        let source = RecommendationSource(connectionID: "placeholder-\(index)", appID: "", appName: "Platform")
        return PlatformCard(platform: PlatformRoutine(id: source.id, source: source, card: nil), count: 0,
                            refreshing: false, open: {})
            .redacted(reason: .placeholder)
            .disabled(true)
            .accessibilityHidden(true)
    }
}
