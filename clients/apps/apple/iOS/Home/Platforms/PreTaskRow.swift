import SwiftUI
import CommaCore

/// One pre-task as a card of its own, as on the desktop: what it is, the source words it quotes as its evidence,
/// then where it comes from. The whole card is what the member taps; it hands itself to `choose` and nothing is
/// ever sent from here. The minus in its top-trailing corner stops suggesting the row's source item. A row with
/// nothing to do is drawn without the press.
struct PreTaskRow: View {
    let item: RecommendationItem
    let feed: RecommendationFeed
    /// The platform the row comes from, whose mark stands in for a picture that hasn't loaded.
    let source: RecommendationSource?
    /// The platform's name under the card's words; nil where the page's title already names it.
    var origin: String? = nil
    /// Stops suggesting the row's source item.
    var dismiss: ((RecommendationItem) -> Void)? = nil
    let choose: (RecommendationItem) -> Void
    @ScaledMetric(relativeTo: .footnote) private var originMark: CGFloat = 16

    private static let shape = RoundedRectangle(cornerRadius: GroupedSurface.radius, style: .continuous)
    /// The minus's hit target, which the title leaves room for.
    private static let dismissSide: CGFloat = 44

    var body: some View {
        card
            .background(GroupedSurface.surface, in: Self.shape)
            .clipShape(Self.shape)
            .overlay(alignment: .topTrailing) { dismissControl }
    }

    @ViewBuilder private var card: some View {
        if let hint {
            Button { choose(item) } label: { label }
                .buttonStyle(SurfaceRowButtonStyle())
                .accessibilityHint(hint)
                .accessibilityIdentifier("pretask-" + item.id)
        } else {
            label
        }
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                // Words first on every card, so the cards' text keeps one leading edge; a picture trails them.
                words.frame(maxWidth: .infinity, alignment: .leading)
                if let url = item.imageURL { PreTaskThumbnail(url: url, source: source) }
            }
            .padding(.trailing, dismissible ? Self.dismissSide - GroupedSurface.inset : 0)
            if let quote = item.quote { RoutineQuote(quote: quote) }
            if let origin {
                HStack(spacing: 6) {
                    ProviderLogo(source: source, size: originMark)
                    Text(verbatim: origin).lineLimit(1)
                }
                .font(.footnote)
                .foregroundStyle(CommaTheme.textQuaternary)
            }
        }
        .padding(.horizontal, GroupedSurface.inset).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityText))
    }

    /// A member task leads with the task its prompt names; any other row with its own words.
    @ViewBuilder private var words: some View {
        if let objective = item.objective {
            Text(objective).font(.callout.weight(.medium)).foregroundStyle(CommaTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            RoutineItemText(item: item, feed: feed, source: source)
        }
    }

    private var dismissible: Bool { dismiss != nil && item.sourceItem != nil }

    @ViewBuilder private var dismissControl: some View {
        // The minus sits on the card's own press, so it asks once, as the long press did, before the row leaves.
        if let dismiss, item.sourceItem != nil {
            Menu {
                Button(role: .destructive) { dismiss(item) } label: { Label("Don’t remind me", systemImage: "bell.slash") }
            } label: {
                CentralIcon("central-circle-minus", size: 18)
                    .foregroundStyle(CommaTheme.textQuaternary)
                    .frame(width: Self.dismissSide, height: Self.dismissSide)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Don’t remind me"))
            .accessibilityIdentifier("pretask-dismiss-" + item.id)
        }
    }

    /// The card's words as one sentence: what it is, what is known about it, then the quote.
    private var accessibilityText: String {
        let words: [String?] = if let objective = item.objective { [objective] }
            else if item.text.isEmpty { [item.title, item.detail] }
            else { [item.title, item.text] }
        let quote = item.quote?.plainText
        return (words + [quote, origin]).compactMap { $0 }.joined(separator: ", ")
    }

    /// What choosing the row does, for VoiceOver; nil for a row with nothing to do.
    private var hint: Text? {
        if item.linkedTaskID != nil { return Text("Opens the task") }
        switch item.action {
        case .prompt: return Text("Adds to your message to Comma")
        case .openURL: return Text("Opens the link")
        case nil: return nil
        }
    }
}

/// A media item's picture at the row's trailing side, concentric with the surface's corners. Until it loads, and when it
/// can't, the platform's mark stands on the same tile, so the row keeps its shape and never shows an empty frame.
private struct PreTaskThumbnail: View {
    let url: URL
    let source: RecommendationSource?
    @ScaledMetric(relativeTo: .callout) private var side: CGFloat = 36
    @Environment(\.displayScale) private var displayScale

    /// The surface's 24pt radius less the row's 14pt inset.
    private static let radius = GroupedSurface.radius - GroupedSurface.inset

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                ProviderLogo(source: source, size: side / 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(GroupedSurface.ink)
            }
        }
        .frame(width: side, height: side)
        .clipShape(shape)
        // A neutral hairline keeps a light image's edge on the light surface.
        .overlay(shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 1 / displayScale))
        .accessibilityHidden(true)
    }
}

/// A platform's pre-tasks, each a card of its own, or the card's own words when this app can't draw its template.
/// Both sheets draw a platform with it.
struct PreTaskGroup: View {
    let platform: PlatformRoutine
    let items: [RecommendationItem]
    let feed: RecommendationFeed
    /// Names the platform under each card's words, where nothing above them does.
    var showsOrigin = false
    /// Stops suggesting a row's source item.
    var dismiss: ((RecommendationItem) -> Void)? = nil
    /// Hands over the chosen row with the platform it comes from.
    let choose: (RecommendationItem, RecommendationSource?) -> Void

    var body: some View {
        VStack(spacing: GroupedSurface.groupSpacing) {
            if let fallback = platform.card?.fallbackText {
                Text(fallback).font(.callout).foregroundStyle(CommaTheme.textPrimary)
                    .surfaceRowFrame(vertical: 12)
                    .background(GroupedSurface.surface,
                                in: RoundedRectangle(cornerRadius: GroupedSurface.radius, style: .continuous))
            }
            ForEach(items) {
                PreTaskRow(item: $0, feed: feed, source: platform.source, origin: showsOrigin ? platform.heading : nil,
                           dismiss: dismiss) { choose($0, platform.source) }
            }
        }
    }
}

extension PlatformRoutine {
    /// The name a sheet heads the platform with: its account too when two platforms share the name.
    var heading: String { connectionLabel.map { "\(name) · \($0)" } ?? name }
}

extension CommaStore {
    /// Whether a platform has anything for a sheet to draw: pre-tasks, or the card's own words.
    func hasPreTasks(_ platform: PlatformRoutine) -> Bool {
        platform.card?.fallbackText != nil || !preTasks(of: platform).isEmpty
    }
}
