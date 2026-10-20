import SwiftUI
import CommaCore

/// One pre-task in a sheet: what it is over what is known about it, its picture when it has one, then where
/// choosing it goes, a chevron into Comma (the composer or the Task) or an arrow out to the link. It sits on the
/// grouped surface and deepens under the finger like the app's other grouped rows, so it reads as something to tap
/// rather than prose; it hands itself to `choose` and nothing is ever sent from here. A row with nothing to do is
/// drawn without the cue.
struct PreTaskRow: View {
    let item: RecommendationItem
    let feed: RecommendationFeed
    /// The platform the row comes from, whose mark stands in for a picture that hasn't loaded.
    let source: RecommendationSource?
    let choose: (RecommendationItem) -> Void

    private static let chevron = "central-chevron-right-small"

    var body: some View {
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
        HStack(alignment: .center, spacing: 12) {
            // Words first on every row, so a group's text keeps one leading edge; a picture trails them.
            RoutineItemText(item: item, feed: feed, source: source).frame(maxWidth: .infinity, alignment: .leading)
            if let url = item.imageURL { PreTaskThumbnail(url: url, source: source) }
            if let glyph {
                // The arrow is drawn edge to edge where the chevron is small, so it sits smaller to weigh the same,
                // on the same centre line.
                let size: CGFloat = glyph == Self.chevron ? 18 : 14
                CentralIcon(glyph, size: size, relativeTo: .callout)
                    .foregroundStyle(CommaTheme.textQuaternary)
                    .padding(.trailing, 6 - size / 2)
            }
        }
        .surfaceRowFrame(vertical: 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityText))
    }

    /// The row's words as one sentence: a media item's title, then its metadata line.
    private var accessibilityText: String {
        let words = item.text.isEmpty ? [item.title, item.detail] : [item.title, item.text]
        return words.compactMap { $0 }.joined(separator: ", ")
    }

    /// The trailing cue, as `RoutineActions.perform` resolves the row: a Task or a prompt stays in Comma, a link
    /// leaves it.
    private var glyph: String? {
        if item.linkedTaskID != nil { return Self.chevron }
        switch item.action {
        case .prompt: return Self.chevron
        case .openURL: return "central-arrow-up-right"
        case nil: return nil
        }
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

/// A platform's pre-tasks on one rounded surface, or the card's own words when this app can't draw its
/// template. Both sheets draw a platform with it.
struct PreTaskGroup: View {
    let platform: PlatformRoutine
    let items: [RecommendationItem]
    let feed: RecommendationFeed
    /// Hands over the chosen row with the platform it comes from.
    let choose: (RecommendationItem, RecommendationSource?) -> Void

    var body: some View {
        SurfaceGroup {
            if let fallback = platform.card?.fallbackText {
                Text(fallback).font(.callout).foregroundStyle(CommaTheme.textPrimary).surfaceRowFrame(vertical: 12)
            }
            ForEach(items) { PreTaskRow(item: $0, feed: feed, source: platform.source) { choose($0, platform.source) } }
        }
    }
}

/// A platform's mark and name over its group, in the app's caption style and on the captions' edge.
struct PlatformCaption: View {
    let platform: PlatformRoutine
    @ScaledMetric(relativeTo: .subheadline) private var markSize: CGFloat = 18

    var body: some View {
        HStack(spacing: 8) {
            ProviderLogo(source: platform.source, size: markSize)
            Text(verbatim: platform.heading).lineLimit(1)
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(CommaTheme.textQuaternary)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
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
