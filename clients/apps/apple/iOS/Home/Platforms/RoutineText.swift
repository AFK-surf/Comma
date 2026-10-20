import SwiftUI
import UIKit
import CommaCore

/// A pre-task's words in two steps: what it is, then what is known about it. A media item leads with its title
/// over its description, the metadata line (an issue's identifier and state, a pull request's repository); a text
/// item is one sentence whose links and Tasks read as mentions, since the row itself is what the member taps.
struct RoutineItemText: View {
    let item: RecommendationItem
    let feed: RecommendationFeed
    /// The platform the row sits under, whose mentions need no mark of their own.
    let source: RecommendationSource?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let title = item.title {
                Text(title).font(.callout.weight(.medium)).foregroundStyle(CommaTheme.textPrimary)
            }
            if !item.parts.isEmpty {
                RoutineProse(parts: item.parts, feed: feed, references: .mentions(within: source?.appID))
            } else if let detail = item.detail {
                Text(detail).font(.footnote).foregroundStyle(CommaTheme.textTertiary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Briefing prose: in a row, `.callout`, a step under the page's body; as the briefing's summary, a lead paragraph
/// a step over it, the first thing read on the sheet. Text runs, and links and Tasks drawn like the desktop's
/// inline sources; in the summary they are links, a Task opening and a source showing in the browser.
struct RoutineProse: View {
    let parts: [RecommendationPart]
    let feed: RecommendationFeed
    var references = References.chips
    /// The inline provider mark sits a point under the text and scales with it.
    @ScaledMetric(relativeTo: .callout) private var rowMark: CGFloat = 15
    @ScaledMetric(relativeTo: .body) private var leadSize: CGFloat = 19
    @ScaledMetric(relativeTo: .body) private var leadMark: CGFloat = 17
    @Environment(\.colorScheme) private var colorScheme

    private var lead: Bool { references == .chips }
    private var font: Font { lead ? .system(size: leadSize) : .callout }

    var body: some View {
        parts.reduce(Text("")) { text, part in
            switch part {
            case .text(let value):
                return text + Text(Self.inlineMarkdown(value, emphasis: font.weight(.semibold)))
                    .foregroundColor(CommaTheme.textPrimary)
            case .link(let label, let url, let source):
                return text + reference(label: label, sourceID: source, opens: url)
            case .task(let label, let id, let source):
                return text + reference(label: label, sourceID: source, opens: RoutineLink.task(id))
            }
        }
        .font(font)
        .lineSpacing(lead ? 5 : 0)
        .tint(CommaTheme.brandSolid)
    }

    /// How links and Tasks read: in the briefing's summary, links in the app's blue after their source's mark, which
    /// open what they name (a box behind a run cannot round its corners and breaks across lines); or, in a row, mentions, the name a weight heavier, so a box inside the tappable row doesn't read as a
    /// second, smaller button. A mention of the row's own platform leaves out the mark its title or caption shows.
    enum References: Equatable {
        case chips
        case mentions(within: String?)
    }

    private func reference(label: String, sourceID: String?, opens url: URL?) -> Text {
        let appID = feed.source(sourceID)?.appID
        var run = AttributedString(label)
        switch references {
        case .chips:
            run.foregroundColor = CommaTheme.brandSolid
            run.font = font.weight(.medium)
            run.link = url
        case .mentions(let home):
            run.foregroundColor = CommaTheme.textPrimary
            run.font = .callout.weight(.medium)
            if appID == home { return Text(run) }
        }
        let tint = UIColor(CommaTheme.textSecondary).resolvedColor(with: UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light))
        // An inline image cannot carry a run background, so the mark leads the label.
        if let mark = ProviderArtwork.inline(appID, pointSize: lead ? leadMark : rowMark, tint: tint) {
            return Text(mark).baselineOffset(-2) + Text("\u{2009}") + Text(run)
        }
        return Text(run)
    }

    /// The model writes light Markdown (bold, code); render it, keep everything else literal. Its bold reads one
    /// step lighter, semibold, so emphasis in the prose doesn't outweigh the rows' titles.
    static func inlineMarkdown(_ value: String, emphasis: Font) -> AttributedString {
        guard var text = try? AttributedString(markdown: value, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        else { return AttributedString(value) }
        for run in text.runs where run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
            text[run.range].inlinePresentationIntent?.remove(.stronglyEmphasized)
            text[run.range].font = emphasis
        }
        return text
    }
}

/// A Task named in the briefing's summary, as a link the sheet opens itself.
enum RoutineLink {
    static let scheme = "comma-task"

    static func task(_ id: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.path = id
        return components.url
    }

    /// The Task a summary link names; nil for a source's own link.
    static func taskID(_ url: URL) -> String? { url.scheme == scheme ? url.path : nil }
}
