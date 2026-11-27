import SwiftUI
import Observation
import UIKit

/// Where the member is: the selected tab and whether the router chat covers the tabs. Owned by
/// `AppShellView` and read from the environment.
@MainActor @Observable
final class AppNavigation {
    var tab: AppTab
    /// The Task panel’s creation sheet, shared by its compact and Duo toolbar actions.
    var newTaskOpen = false
    /// Settings keeps one stack while its master list moves between the trailing column and the full shell.
    var settingsPath: [SettingsRoute] = []
    /// The open person's id, kept here as Settings' path is, so the shell can make room for its list.
    var peoplePath: [String] = []
    /// Advances when the selected tab is tapped again; that tab pops to its root and scrolls to the top.
    private(set) var reselect: [AppTab: Int] = [:]
    private(set) var animatesRouterOpening = false
    var routerOpen: Bool
    /// An open Task's sheet is up, or on its way up, over the router chat and the tabs; minimized to its bar, it is not.
    var taskRaised = false
    /// Task search is up over the tabs (`TaskSearchLayer`), opened from Home’s search button.
    private(set) var searchOpen = false
    /// Advances when the router composer should take focus.
    private(set) var routerFocusRequest = 0
    /// Advances when something covers the router chat and its keyboard should go down.
    private(set) var keyboardDismissal = 0
    /// The tab bar owns the button used by the chat's zoom.
    @ObservationIgnored weak var routerTabBar: (any ShellBar)?
    @ObservationIgnored private var focusAfterOpening = false

    init(tab: AppTab = .home, routerOpen: Bool = false) {
        self.tab = tab
        self.routerOpen = routerOpen
    }

    /// The selected tab has a detail open beside its list (`AppTab.ownsShellColumns`).
    var columnDetailOpen: Bool {
        switch tab {
        case .settings: !settingsPath.isEmpty
        case .people: !peoplePath.isEmpty
        case .home, .inbox, .apps, .drive, .plugins: false
        }
    }

    func select(_ next: AppTab) {
        if next == tab { reselect[next, default: 0] += 1 } else { tab = next }
    }

    /// Opening from the button keeps the transcript in view; `focus` raises the keyboard once the layer settles.
    func openRouter(focus: Bool = false) {
        if routerOpen {
            if focus { routerFocusRequest += 1 }
            return
        }
        animatesRouterOpening = true
        focusAfterOpening = focus
        // The chat closes into its circle, which search would cover.
        searchOpen = false
        routerOpen = true
    }

    func closeRouter() {
        focusAfterOpening = false
        routerOpen = false
    }

    /// The router layer finished opening: a pending focus request applies now.
    func routerSettled() {
        // The opening has landed; a layer built from here on finds the chat already open.
        animatesRouterOpening = false
        guard routerOpen, focusAfterOpening else { return }
        focusAfterOpening = false
        routerFocusRequest += 1
    }

    /// Stages a Routine item in the router composer as a tile, opens the router and focuses the composer.
    /// The member sends it; nothing is sent here.
    func attachToRouter(_ attached: ChatAttachedText, store: CommaStore) {
        store.router.pane?.attachText(attached)
        openRouter(focus: true)
    }

    func dismissKeyboard() { keyboardDismissal += 1 }

    func openSearch() { searchOpen = true }

    func closeSearch() { searchOpen = false }
}

extension View {
    /// Runs `action` whenever `tab` comes on screen and again when `id` changes while it is there, as `task(id:)`
    /// does for a page that appears. The tabs' pages stay on screen under the bar (`ShellTabsController`), so a
    /// page appears only once, at launch.
    func task(whileShowing tab: AppTab, id: some Equatable,
              _ action: @escaping @MainActor @Sendable () async -> Void) -> some View {
        modifier(ShowingTabTask(tab: tab, id: id, action: action))
    }

    /// Runs `action` whenever `tab` comes on screen (see `task(whileShowing:id:_:)`).
    func task(whileShowing tab: AppTab, _ action: @escaping @MainActor @Sendable () async -> Void) -> some View {
        task(whileShowing: tab, id: true, action)
    }
}

/// Reads the selected tab in a body of its own, so only the task follows it, not the page it is on.
private struct ShowingTabTask<ID: Equatable>: ViewModifier {
    let tab: AppTab
    let id: ID
    let action: @MainActor @Sendable () async -> Void
    @Environment(AppNavigation.self) private var navigation

    func body(content: Content) -> some View {
        let showing = navigation.tab == tab
        content.task(id: Trigger(id: id, showing: showing)) { if showing { await action() } }
    }

    private struct Trigger: Equatable {
        let id: ID
        let showing: Bool
    }
}
