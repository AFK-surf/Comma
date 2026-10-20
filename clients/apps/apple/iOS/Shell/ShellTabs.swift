import SwiftUI
import UIKit
import CommaCore

/// Home, Inbox and Settings under the system tab bar, which draws the bar and answers it: its glass, the lens a
/// press lifts, the selection and its haptics. The router chat's button is the bar's separate circle, the place
/// iOS keeps for a search tab; it opens the router layer instead of becoming a tab. Tapping the selected tab
/// again returns it to its root (`AppNavigation.reselect`).
struct ShellTabs: View {
    let store: CommaStore
    let activity: TaskActivityCoordinator
    let query: HomeTaskQuery
    @Environment(AppNavigation.self) private var navigation
    @Environment(InboxModel.self) private var inbox
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ShellTabHost(store: store, navigation: navigation, bar: bar) { tab in
            page(tab).environment(navigation).environment(inbox).environmentObject(activity)
        }
        // The controller lays its pages and its bar out against the card's edges itself.
        .ignoresSafeArea()
    }

    @ViewBuilder private func page(_ tab: AppTab) -> some View {
        switch tab {
        // Home lays out its own foot, with the status switcher over the blur.
        case .home: HomeView(store: store, query: query)
        case .inbox: InboxView(store: store).tabBottom(wash: tab.wash) { Color.clear.frame(height: 0) }
        case .settings: SettingsView(store: store).tabBottom(wash: tab.wash) { Color.clear.frame(height: 0) }
        }
    }

    /// Everything the bar shows that changes.
    private var bar: ShellTabBar {
        ShellTabBar(selection: navigation.tab,
                    avatar: AvatarKey(photo: store.avatarData, name: store.memberName,
                                      colorScheme: colorScheme),
                    inboxUnread: inbox.hasUnread(tasks: store.tasks),
                    settingsAttention: store.pushRegistrationError != nil
                        || store.taskNotifications?.needsAttention == true,
                    routerUnread: navigation.routerOpen ? 0 : store.router.unreadCount,
                    routerReplying: store.router.pane?.isReplying ?? false)
    }
}

/// What the system tab bar shows besides its tabs' glyphs.
struct ShellTabBar: Equatable {
    var selection: AppTab = .home
    var avatar: AvatarKey?
    /// A row the Inbox shows is unread: the Inbox tab carries a dot, and VoiceOver says so.
    var inboxUnread = false
    /// Notifications the member turned on cannot reach this device, so Settings has something to fix.
    var settingsAttention = false
    /// Router replies not yet seen, counted on the router's circle while the chat is closed.
    var routerUnread = 0
    /// The router is thinking or streaming a reply; its mark plays the logo animation.
    var routerReplying = false
}

/// What the Settings tab's avatar is drawn from; it is drawn again when this changes.
struct AvatarKey: Equatable {
    let photo: Data?
    let name: String?
    let colorScheme: ColorScheme
}

/// Hands each tab's page to the controller with the environment that does not cross into its hosting controller.
private struct ShellTabHost<Page: View>: UIViewControllerRepresentable {
    let store: CommaStore
    let navigation: AppNavigation
    let bar: ShellTabBar
    @ViewBuilder let page: (AppTab) -> Page

    func makeUIViewController(context: Context) -> ShellTabsController<Page> {
        ShellTabsController(store: store, navigation: navigation, bar: bar) { tab in
            HostedContent(content: page(tab), environment: context.environment)
        }
    }

    func updateUIViewController(_ controller: ShellTabsController<Page>, context: Context) {
        controller.update(bar: bar, environment: context.environment) { tab in
            HostedContent(content: page(tab), environment: context.environment)
        }
    }
}
