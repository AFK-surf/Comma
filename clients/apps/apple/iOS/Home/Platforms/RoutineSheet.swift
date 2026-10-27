import SwiftUI
import CommaCore

/// The whole briefing in one sheet, opened from Home's greeting. The member comes to read the day, then act on
/// one suggestion, so the sheet reads in that order: the summary as plain prose on the page, then every pre-task as
/// a card of its own (`PreTaskGroup`) that names its platform under its words, in the carousel's order, as the
/// desktop's Routines do. Platforms with nothing fold into one quiet line at the end instead of a section each.
/// Choosing a card hands it to `choose`, which closes the sheet.
struct RoutineSheet: View {
    let store: CommaStore
    let choose: (RecommendationItem, RecommendationSource?) -> Void
    /// A Task named in the summary, opened once the sheet has closed.
    let openTask: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                if let feed = store.routines.feed {
                    briefing(feed)
                        .padding(.horizontal, GroupedSurface.margin).padding(.top, 8).padding(.bottom, 24)
                }
            }
            .background(CommaTheme.cardPrimary)
            // A Task in the summary opens in the dock; a source opens in the browser.
            .environment(\.openURL, OpenURLAction { url in
                guard let task = RoutineLink.taskID(url) else { return .systemAction }
                openTask(task)
                return .handled
            })
            .pageTitle("Routines")
            .sheetCloseButton { dismiss() }
        }
        .commaSheet()
    }

    /// The summary, the cards and the quiet line sit 24pt apart, three times the 8pt between two cards.
    private func briefing(_ feed: RecommendationFeed) -> some View {
        let platforms = feed.platforms
        let quiet = platforms.filter { !store.hasPreTasks($0) }
        return VStack(alignment: .leading, spacing: 24) {
            if !feed.summaryBody.isEmpty {
                // The captions' edge, so the prose and the headings under it share one leading line. The sheet's
                // title already names the briefing, so the summary starts at its prose.
                RoutineProse(parts: feed.summaryBody, feed: feed)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
            VStack(spacing: GroupedSurface.groupSpacing) {
                ForEach(platforms.filter { store.hasPreTasks($0) }) { platform in
                    PreTaskGroup(platform: platform, items: store.preTasks(of: platform), feed: feed, showsOrigin: true,
                                 dismiss: { item in Task { await store.routines.dismiss(item, store: store) } },
                                 choose: choose)
                }
            }
            if !quiet.isEmpty { QuietPlatforms(platforms: quiet) }
        }
    }
}

/// The platforms with nothing for the member, in one footnote under the rest: their marks, then their names. A
/// platform Routines can no longer read says so on its own line, since that one needs the member.
private struct QuietPlatforms: View {
    let platforms: [PlatformRoutine]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProviderLogoStack(sources: platforms.map(\.source))
                Text("Nothing from \(ListFormatter.localizedString(byJoining: platforms.map(\.heading))) needs you right now.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(platforms.filter { $0.source?.needsReconnect == true }) { platform in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    CentralIcon("central-exclamation-triangle", size: 16, relativeTo: .footnote)
                        .foregroundStyle(CommaTheme.attention)
                    Text("Routines can’t read \(platform.name). Reconnect it in Plugins on the desktop.")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .font(.footnote)
        .foregroundStyle(CommaTheme.textTertiary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }
}
