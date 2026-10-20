import SwiftUI
import Observation

/// Where the member is: the selected tab and whether the router chat covers the tabs. Owned by
/// `AppShellView` and read from the environment.
@MainActor @Observable
final class AppNavigation {
    var tab: AppTab
    /// Advances when the selected tab is tapped again; that tab pops to its root and scrolls to the top.
    private(set) var reselect: [AppTab: Int] = [:]
    var routerOpen: Bool
    /// An open Task's sheet is up, or on its way up, over the router chat and the tabs; minimized to its bar, it is not.
    var taskRaised = false
    /// Task search is up over the tabs (`TaskSearchLayer`), opened from its button beside the Inbox tab.
    private(set) var searchOpen = false
    /// Advances when the router composer should take focus.
    private(set) var routerFocusRequest = 0
    /// Advances when something covers the router chat and its keyboard should go down.
    private(set) var keyboardDismissal = 0
    /// The router button in global coordinates, where the router chat zooms from and back into.
    @ObservationIgnored var routerButtonFrame: CGRect = .zero
    /// Told, as the router chat starts closing, when it will reach the router button and how hard, so the button can
    /// take it in then; told nil when a closing chat is stopped before it arrives. Set by the tab bar.
    @ObservationIgnored var routerLanding: ((RouterLanding?) -> Void)?
    @ObservationIgnored private var focusAfterOpening = false

    init(tab: AppTab = .home, routerOpen: Bool = false) {
        self.tab = tab
        self.routerOpen = routerOpen
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
