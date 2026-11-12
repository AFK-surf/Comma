import SwiftUI

/// Everything inside the app card: the tabs under the system tab bar, Task search over them while it is open, and
/// the router chat above both. It lives inside the card's hosting controller, so animations started here reach the
/// router; one started in `AppShellView` would not cross into that controller.
struct ShellCard: View {
    let store: CommaStore
    let activity: TaskActivityCoordinator
    let navigation: AppNavigation
    let query: HomeTaskQuery
    /// The router layer mounts shortly after launch, on an earlier first opening, or at once when the shell opens on
    /// the chat, and then stays, keeping its transcript position. Built ahead of time, its first opening is only the
    /// zoom.
    @State private var routerMounted = false
    @State private var folded = false

    var body: some View {
        GeometryReader { geometry in
            let columns = ShellColumnLayout(width: geometry.size.width, folded: folded, division: geometry.shellFoldDivision)
            ZStack(alignment: .leading) {
                ShellTabs(store: store, activity: activity, query: query, showsRoutines: false)
                    .accessibilityHidden(navigation.routerOpen || navigation.searchOpen)
                if navigation.searchOpen {
                    // It goes at once, its field with it (`TaskSearchLayer`).
                    TaskSearchLayer(store: store) { navigation.closeSearch() }
                        .transition(.asymmetric(insertion: .opacity, removal: .identity))
                }
                if routerMounted || navigation.routerOpen {
                    RouterChatLayer(store: store, open: navigation.routerOpen, sharesRoutineColumn: columns.isWide)
                        .ignoresSafeArea()
                }
                if columns.isWide {
                    ShellRoutineColumn(store: store, width: columns.leadingWidth, stride: columns.contentLeadingInset)
                }
            }
        }
        .modifier(HomeHingeObserver(folded: $folded))
        .animation(CommaMotion.stateChange, value: navigation.searchOpen)
        .environment(navigation)
        .providingInbox(store: store)
        .environmentObject(activity)
        .onChange(of: navigation.routerOpen, initial: true) { _, open in if open { routerMounted = true } }
        .task {
            // Once the first screen has settled, so building the chat never competes with launch.
            try? await Task.sleep(for: .seconds(1))
            routerMounted = true
        }
    }
}
