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
                RoutineProse(parts: item.parts, feed: feed, home: source?.appID)
            } else if let detail = item.detail {
                Text(detail).font(.footnote).foregroundStyle(CommaTheme.textTertiary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A row's prose, `.callout`, a step under the page's body. Text runs, with links and Tasks as mentions: the name
/// a weight heavier after its source's mark, since a box inside the tappable row would read as a second, smaller
/// button. A mention of the row's own platform (`home`) leaves out the mark its title or caption shows.
struct RoutineProse: View {
    let parts: [RecommendationPart]
    let feed: RecommendationFeed
    var home: String?
    /// The inline provider mark sits a point under the text and scales with it.
    @ScaledMetric(relativeTo: .callout) private var mark: CGFloat = 15
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        parts.reduce(Text("")) { text, part in
            switch part {
            case .text(let value):
                return text + Text(Self.inlineMarkdown(value, emphasis: .callout.weight(.semibold)))
                    .foregroundColor(CommaTheme.textPrimary)
            case .link(let label, _, let source): return text + mention(label, sourceID: source)
            case .task(let label, _, let source): return text + mention(label, sourceID: source)
            }
        }
        .font(.callout)
    }

    private func mention(_ label: String, sourceID: String?) -> Text {
        let appID = feed.source(sourceID)?.appID
        var run = AttributedString(label)
        run.foregroundColor = CommaTheme.textPrimary
        run.font = .callout.weight(.medium)
        if appID == home { return Text(run) }
        let tint = UIColor(CommaTheme.textSecondary).resolvedColor(with: UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light))
        // An inline image cannot carry a run background, so the mark leads the label.
        if let image = ProviderArtwork.inline(appID, pointSize: mark, tint: tint) {
            return Text(image).baselineOffset(-2) + Text("\u{2009}") + Text(run)
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

/// A member task's quoted source words under a quote rule, as the desktop's card shows them: in the title's size, a
/// quieter ink, one line per source line, at most four lines. The client core reads the server's quote markup into
/// lines of runs (`RecommendationQuote`); a mention reads a weight heavier and a link underlined. Nothing in it is a
/// target of its own: the card around it is.
struct RoutineQuote: View {
    let quote: RecommendationQuote

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Capsule().fill(CommaTheme.borderPrimary).frame(width: 2)
            Text(Self.attributed(quote))
                .font(.callout)
                .foregroundStyle(CommaTheme.textTertiary)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    static func attributed(_ quote: RecommendationQuote) -> AttributedString {
        var out = AttributedString()
        for (index, line) in quote.lines.enumerated() {
            if index > 0 { out += AttributedString("\n") }
            if line.listItem { out += AttributedString("• ") }
            for run in line.runs {
                var text = AttributedString(run.text)
                switch run.kind {
                case .mention:
                    text.foregroundColor = CommaTheme.textPrimary
                    text.font = .callout.weight(.medium)
                case .link: text.underlineStyle = .single
                case .text, .channel: break
                }
                out += text
            }
        }
        return out
    }
}
