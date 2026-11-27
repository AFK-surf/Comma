import SwiftUI
import UIKit
import CommaCore

/// The whole briefing in one sheet, opened from Home's greeting. The member comes to see what is left, then act on
/// one suggestion, so the sheet reads in that order: how many cards need them beside the refresh, then every
/// pre-task as a card of its own (`PreTaskGroup`) that names its platform under its words, in the carousel's order,
/// as the desktop's Routines do. Platforms with nothing fold into one quiet line at the end instead of a section
/// each. Choosing a card hands it to `choose`, which closes the sheet.
struct RoutineSheet: View {
    let store: CommaStore
    let choose: (RecommendationItem, RecommendationSource?) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            RoutineContent(store: store, choose: choose)
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
        RoutineContent(store: store, choose: perform, backgroundColor: CommaTheme.bgPrimary)
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

    private func perform(_ item: RecommendationItem, source: RecommendationSource?) {
        RoutineActions(usePrompt: { prompt in
            inserts += 1
            navigation.attachToRouter(ChatAttachedText(source: source?.appName, text: prompt), store: store)
        }, openTask: { id in Task { await store.openTask(id: id) } }, openURL: { openURL($0) }).perform(item)
    }
}

/// The same complete briefing in the compact sheet and the wide Home column.
struct RoutineContent: View {
    let store: CommaStore
    let choose: (RecommendationItem, RecommendationSource?) -> Void
    var backgroundColor: Color = CommaTheme.cardPrimary
    /// The briefing whose last card the member cleared here, and when: its confetti is thrown from then.
    @State private var celebrated: (briefing: Briefing, at: Date)?
    /// The confetti is in the air.
    @State private var bursting = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let feed = store.routines.feed
        let shown = feed?.generation.map { Briefing(read: store.routines.resets, generation: $0) }
        let left = Left(briefing: shown, cards: feed.map(cardsLeft) ?? 0)
        ScrollView {
            // A scroll view is only as wide as its content: with no briefing, or one with no line or card, it would
            // shrink to a strip and leave the rest of the column without its background.
            VStack(spacing: 0) {
                if let feed {
                    briefing(feed, left: left.cards, celebrate: shown != nil && celebrated?.briefing == shown)
                        .padding(.horizontal, GroupedSurface.margin).padding(.top, 8).padding(.bottom, 24)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .background(backgroundColor)
        // The burst has the whole surface. It is thrown from the cleared line, wherever the page puts it.
        .overlayPreferenceValue(RoutinesClearedBounds.self) { bounds in
            GeometryReader { surface in
                if let bounds, let celebrated, bursting, celebrated.briefing == left.briefing {
                    RoutineConfetti(start: celebrated.at, originY: surface[bounds].maxY)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        // The member who clears the last card of the briefing on screen sees it celebrated once. A briefing read
        // already cleared, or a new one published without a card, is not.
        .onChange(of: left) { before, now in
            if let briefing = now.briefing, before.briefing == briefing, before.cards > 0, now.cards == 0 {
                celebrated = (briefing, .now)
                bursting = !reduceMotion
            }
        }
        .task(id: celebrated?.at) {
            guard bursting else { return }
            try? await Task.sleep(for: .seconds(RoutineConfettiPiece.duration))
            bursting = false
        }
    }

    /// One briefing of one Workspace. Generations count per Workspace, so the store's read tells two Workspaces'
    /// briefings apart: it advances each time the store drops the briefing for another Workspace or session.
    private struct Briefing: Equatable {
        let read: Int
        let generation: Int
    }

    private struct Left: Equatable {
        let briefing: Briefing?
        let cards: Int
    }

    /// The cards the briefing shows: what the status line counts.
    private func cardsLeft(_ feed: RecommendationFeed) -> Int {
        feed.platforms.reduce(0) { $0 + store.preTasks(of: $1).count + $1.fallbackTexts.count }
    }

    /// The status line sits on the cards. The quiet line, or the cleared one, sits 24pt under them, three times the
    /// 8pt between two cards.
    private func briefing(_ feed: RecommendationFeed, left: Int, celebrate: Bool) -> some View {
        let platforms = feed.platforms
        let quiet = platforms.filter { !store.hasPreTasks($0) }
        let cleared = feed.hasSnapshot && left == 0
        return VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                if feed.hasSnapshot { RoutineStatusLine(store: store, feed: feed, left: left) }
                VStack(spacing: GroupedSurface.groupSpacing) {
                    ForEach(platforms.filter { store.hasPreTasks($0) }) { platform in
                        PreTaskGroup(platform: platform, items: store.preTasks(of: platform), feed: feed, showsOrigin: true,
                                     dismiss: { item in Task { await store.routines.dismiss(item, store: store) } },
                                     choose: choose)
                    }
                }
            }
            if cleared {
                RoutinesCleared(celebrate: celebrate)
                let unread = quiet.filter { $0.source?.needsReconnect == true }
                if !unread.isEmpty { QuietPlatforms(platforms: unread, namesIdle: false) }
            } else if !quiet.isEmpty {
                QuietPlatforms(platforms: quiet)
            }
        }
    }
}

/// What the Routines hold now, and the refresh that asks for a new briefing, on one line: how many cards are left
/// for the member, or that all are cleared. A refresh the hourly budget refuses says so under the line.
private struct RoutineStatusLine: View {
    let store: CommaStore
    let feed: RecommendationFeed
    let left: Int

    var body: some View {
        let model = store.routines
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                (left > 0 ? Text("\(left) things need you") : Text("All cleared"))
                    .font(.subheadline).foregroundStyle(CommaTheme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("routineStatus")
                Button { Task { await model.refresh(store: store) } } label: {
                    if model.isRefreshing {
                        ProgressView()
                    } else {
                        CentralIcon("central-arrow-rotate-clockwise", size: 20, relativeTo: .subheadline)
                    }
                }
                .buttonStyle(.plain).foregroundStyle(CommaTheme.textSecondary)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .disabled(model.isRefreshing || !feed.canRefresh)
                .accessibilityLabel("Refresh routines")
                .accessibilityIdentifier("refreshRoutines")
            }
            if model.failure == .rateLimited {
                Text("Too many refreshes in the last hour. Try again later.").font(.footnote)
                    .foregroundStyle(CommaTheme.textQuaternary)
            }
        }
        // The captions' edge, so the line and the cards' words share one leading line.
        .padding(.leading, 4)
    }
}

/// The platforms with nothing for the member, in one footnote under the rest: their marks, then their names. A
/// platform Routines can no longer read says so on its own line, since that one needs the member.
private struct QuietPlatforms: View {
    let platforms: [PlatformRoutine]
    /// Says that these platforms have nothing. The cleared line says it for them all.
    var namesIdle = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if namesIdle {
                HStack(spacing: 8) {
                    ProviderLogoStack(sources: platforms.map(\.source))
                    Text("Nothing from \(ListFormatter.localizedString(byJoining: platforms.map(\.heading))) needs you right now.")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
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
