import SwiftUI
import UIKit
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
            RoutineContent(store: store, choose: choose, openTask: openTask)
                .pageTitle("Routines")
                .sheetCloseButton { dismiss() }
        }
        .commaSheet()
    }
}

/// The persistent wide-shell column. Tab selection changes only the page beside it.
struct RoutineSidebar: View {
    let store: CommaStore
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.openURL) private var openURL
    @State private var inserts = 0

    var body: some View {
        RoutineContent(store: store, choose: perform, openTask: openTask, backgroundColor: CommaTheme.bgPrimary)
            .pinnedTopBar {
                HomeHeader(store: store, openBriefing: nil)
                    .padding(.top, GroupedSurface.margin)
            }
            .refreshable { _ = await store.routines.load(store: store) }
            .task(id: ReadKey(workspace: store.workspace?.id, resets: store.routines.resets)) {
                await store.routines.reloadIfStale(store: store)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                Task { await store.routines.reloadIfStale(store: store) }
            }
            .sensoryFeedback(.impact(weight: .light), trigger: inserts)
            .accessibilityIdentifier("homeRoutinesColumn")
    }

    private struct ReadKey: Equatable {
        let workspace: String?
        let resets: Int
    }

    private func openTask(_ id: String) {
        Task { await store.openTask(id: id) }
    }

    private func perform(_ item: RecommendationItem, source: RecommendationSource?) {
        RoutineActions(usePrompt: { prompt in
            inserts += 1
            navigation.attachToRouter(ChatAttachedText(source: source?.appName, text: prompt), store: store)
        }, openTask: openTask, openURL: { openURL($0) }).perform(item)
    }
}

/// The same complete briefing in the compact sheet and the wide Home column.
struct RoutineContent: View {
    let store: CommaStore
    let choose: (RecommendationItem, RecommendationSource?) -> Void
    let openTask: (String) -> Void
    var backgroundColor: Color = CommaTheme.cardPrimary

    var body: some View {
        ScrollView {
            if let feed = store.routines.feed {
                briefing(feed)
                    .padding(.horizontal, GroupedSurface.margin).padding(.top, 8).padding(.bottom, 24)
            }
        }
        .background(backgroundColor)
        // A Task in the summary opens in the dock; a source opens in the browser.
        .environment(\.openURL, OpenURLAction { url in
            guard let task = RoutineLink.taskID(url) else { return .systemAction }
            openTask(task)
            return .handled
        })
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
