import SwiftUI
import UIKit
import CommaCore

/// The Home tab, as in mock 7: a greeting, the connected apps as platform cards, then the member's Tasks for the
/// status chosen in the floating switcher, with filters and the archive beside the section title. Tapping the tab
/// again scrolls back to the top. Task search opens from the tab bar (`TaskSearchLayer`).
struct HomeView: View {
    let store: CommaStore
    @Bindable var query: HomeTaskQuery
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var filtersOpen = false
    @State private var archivedOpen = false
    @State private var routineSheet: RoutineSheetContent?
    @State private var renaming: TaskSummary?
    @State private var sharing: TaskSummary?
    @State private var keyboardVisible = false
    @State private var pager = HomeTaskPager()
    /// `pager.emptyHeight`, kept here so the rows follow it; it changes with the screen, not with a scroll.
    @State private var emptyHeight: CGFloat = 0
    @Environment(\.horizontalSizeClass) private var sizeClass

    private static let top = "home-top"
    /// The mock's 12pt between the status switcher and the tab bar.
    private static let switcherGap: CGFloat = 12
    /// Back to the top after a re-tap: critically damped, so a long list glides home without overshooting.
    private static let scrollHome = Animation.spring(response: 0.4, dampingFraction: 1)

    var body: some View {
        let rows = query.rows(tasks: store.tasks, pinned: store.pinnedTaskIDs, order: store.taskBoardOrder, knownLabelIDs: [])
        // The status switcher floats over the root's foot, above the tab bar, and above a minimized Task's bar too,
        // since the app card ends over it; a raised Task's sheet covers it. It steps aside while the keyboard is up.
        let switcherShown = !keyboardVisible
        NavigationStack {
            ScrollViewReader { scroller in
                List {
                    HomeHeader(store: store, openBriefing: { routineSheet = .briefing })
                        .id(Self.top)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measureRowAbove(0, $0) }
                        .commaListRow()
                    // Clear of the greeting, so the cards read as their own group.
                    PlatformCarousel(store: store) { routineSheet = .platform($0) }
                        .padding(.top, 12).padding(.bottom, 8)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measureRowAbove(1, $0) }
                        .commaListRow()
                    HomeTaskHeader(query: query, pager: pager, openFilters: { filtersOpen = true },
                                   openArchive: { archivedOpen = true })
                        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { pager.rowsTop = $0 }
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measureRowAbove(2, $0) }
                        .commaListRow()
                    HomeTaskRows(store: store, query: query, rows: rows, pager: pager, emptyHeight: emptyHeight,
                                 renaming: $renaming, sharing: $sharing)
                }
                .listStyle(.plain)
                // Rows keep their own 44pt minimum; the system's taller default would space them out.
                .environment(\.defaultMinListRowHeight, 44)
                .scrollContentBackground(.hidden)
                .background(CommaTheme.bgPrimary)
                .progressiveTopEdge()
                // A status chosen on the switcher turns the pager's strip instead; the list swaps unseen beneath it.
                .animation(pager.moving ? nil : CommaMotion.stateChange, value: query.filter)
                .overlay { HomeTaskPages(store: store, query: query, pager: pager, emptyHeight: emptyHeight) }
                .refreshable { await refresh() }
                // The last rows scroll clear of the switcher.
                .contentMargins(.bottom, switcherShown ? TaskStatusSwitcher.height + Self.switcherGap : 0)
                // The content margin kept for the switcher is not among the scroll view's insets.
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    geometry.containerSize.height - geometry.contentInsets.top - geometry.contentInsets.bottom
                        - (switcherShown ? TaskStatusSwitcher.height + Self.switcherGap : 0)
                } action: { _, height in
                    pager.visibleHeight = height
                    measureEmpty()
                }
                .toolbarVisibility(.hidden, for: .navigationBar)
                .onChange(of: navigation.reselect[.home]) { _, _ in
                    withAnimation(reduceMotion ? nil : Self.scrollHome) { scroller.scrollTo(Self.top, anchor: .top) }
                }
            }
        }
        .tabBottom(wash: CommaTheme.bgPrimary) {
            if switcherShown {
                HomeStatusSwitcher(query: query, pager: pager, choose: chooseStatus, scrub: scrub)
                    .frame(maxWidth: sizeClass == .regular ? 420 : 360)
                    .padding(.horizontal, 16)
                    .padding(.bottom, Self.switcherGap)
            } else {
                Color.clear.frame(height: 0)
            }
        }
        // Like the system bar's accessory, the switcher and the room kept for it come and go in one frame.
        .transaction(value: switcherShown) { $0.animation = nil }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardVisible = false
        }
        .taskActionSheets(store: store, renaming: $renaming, sharing: $sharing)
        .sheet(isPresented: $filtersOpen) {
            TaskFilterSheet(filter: $query.filter, fields: [.status, .label, .schedule, .platform, .clientPlatform],
                            tasks: store.tasks, labelCatalog: nil)
        }
        .sheet(isPresented: $archivedOpen) {
            ArchivedTasksView(store: store) { task in Task { await store.openTask(id: task.id) } }
                .environment(\.inSheet, true)
        }
        .preTaskSheet($routineSheet, store: store)
        // A tapped status's rows wait beside the old ones for an update, then slide in.
        .onChange(of: pager.turns) { _, _ in pager.turn() }
        // The list takes the status the strip came to rest on, while nothing moves.
        .onChange(of: pager.arrivals) { _, _ in
            if let pending = pager.pending, pending != query.selectedBucket { query.select(pending) }
            pager.rest()
        }
    }

    private func measureRowAbove(_ index: Int, _ height: CGFloat) {
        pager.rowsAbove[index] = height
        measureEmpty()
    }

    /// Follows the room below the section title, which changes with the screen, the insets or the rows above, never
    /// with a scroll.
    private func measureEmpty() {
        let height = pager.emptyHeight
        if abs(height - emptyHeight) > 0.5 { emptyHeight = height }
    }

    /// A status chosen on the switcher. The strip shows it, already under the finger mid-scrub or turning to it
    /// after a tap, and the list takes it once the strip rests; with Reduce Motion the rows crossfade at once.
    private func chooseStatus(_ bucket: TaskBucket) {
        if pager.scrub(to: bucket) { return }
        if reduceMotion || !pager.turn(from: pager.pending ?? query.selectedBucket, to: bucket) { query.select(bucket) }
    }

    /// The finger moving along the switcher, in statuses; nil once it lets go.
    private func scrub(_ position: CGFloat?) {
        guard let position, !reduceMotion else { return pager.release() }
        pager.track(position, from: pager.pending ?? query.selectedBucket)
    }

    /// Pull to refresh reads the Tasks and the briefing side by side.
    private func refresh() async {
        async let tasks: Void = store.refresh()
        async let briefing = store.routines.load(store: store)
        _ = await (tasks, briefing)
    }
}

/// The status switcher over Home, showing the status the strip shows before the list takes it. Its own view, so a
/// scrub redraws only the switcher.
private struct HomeStatusSwitcher: View {
    let query: HomeTaskQuery
    let pager: HomeTaskPager
    let choose: (TaskBucket) -> Void
    let scrub: (CGFloat?) -> Void

    var body: some View {
        TaskStatusSwitcher(selection: pager.pending ?? query.selectedBucket, select: choose, scrub: scrub)
    }
}
