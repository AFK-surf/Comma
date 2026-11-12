import SwiftUI
import UIKit
import CommaCore

/// Home, Inbox, Apps and Settings under the system tab bar, which draws the bar and answers it: its glass, the lens a
/// press lifts, the selection and its haptics. The router chat's button is the bar's separate circle, the place
/// iOS keeps for a search tab; it opens the router layer instead of becoming a tab. Tapping the selected tab
/// again returns it to its root (`AppNavigation.reselect`).
struct ShellTabs: View {
    let store: CommaStore
    let activity: TaskActivityCoordinator
    let query: HomeTaskQuery
    var showsRoutines = true
    @Environment(AppNavigation.self) private var navigation
    @Environment(InboxModel.self) private var inbox
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var folded = false

    static let minimumColumnWidth = ShellColumnLayout.minimumColumnWidth

    var body: some View {
        GeometryReader { geometry in
            let layout = ShellColumnLayout(width: geometry.size.width, folded: folded, division: geometry.shellFoldDivision)
            let wide = layout.isWide
            ShellColumns(store: store, navigation: navigation, bar: bar, wide: wide,
                         settingsColumnsFolded: wide ? folded : nil,
                         leadingWidth: layout.leadingWidth,
                         contentLeadingInset: layout.contentLeadingInset, showsRoutines: showsRoutines) { tab in
                page(tab).environment(navigation).environment(inbox).environmentObject(activity)
            }
            .animation(reduceMotion ? nil : CommaMotion.release, value: folded)
            .background(CommaTheme.bgPrimary)
            .modifier(HomeHingeObserver(folded: $folded))
        }
    }

    @ViewBuilder private func page(_ tab: AppTab) -> some View {
        switch tab {
        // Home lays out its floating status switcher.
        case .home: HomeView(store: store, query: query)
        case .inbox: InboxView(store: store)
        case .apps: MiniAppsTabView(store: store)
        case .settings: SettingsView(store: store)
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

/// Division frames use the same local coordinates as the usable column area. A side bar can make
/// the fold off-centre in that area, so the two content columns need not have equal widths.
struct ShellColumnLayout {
    static let minimumColumnWidth: CGFloat = 350
    let gap: CGFloat
    let leadingWidth: CGFloat
    let trailingWidth: CGFloat

    var isWide: Bool {
        leadingWidth + trailingWidth >= Self.minimumColumnWidth * 2
            && leadingWidth > 0 && trailingWidth > 0
    }

    var contentLeadingInset: CGFloat { isWide ? leadingWidth + gap : 0 }

    init(width: CGFloat, folded: Bool, division: CGRect?) {
        let centre = folded ? (division?.midX ?? width / 2) : width / 2
        gap = folded ? max(GroupedSurface.margin * 4, division?.width ?? 0) : 0
        leadingWidth = max(0, centre - gap / 2)
        trailingWidth = max(0, width - centre - gap / 2)
    }
}

extension GeometryProxy {
    var shellFoldDivision: CGRect? {
        #if canImport(SwiftUI, _version: 8.0.85)
        if #available(iOS 27.1, *) {
            return reservedRegions(kind: .division, options: .includeInactive)
                .first { $0.frame.height > $0.frame.width && $0.frame.midX > 0 && $0.frame.midX < size.width }?.frame
        }
        #endif
        return nil
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

/// Interpolate in a SwiftUI view body so UIKit receives each intermediate content inset.
/// Animatable on the representable itself does not drive updateUIViewController per frame.
struct ShellColumns<Page: View>: View, @preconcurrency Animatable {
    let store: CommaStore
    let navigation: AppNavigation
    let bar: ShellTabBar
    let wide: Bool
    var settingsColumnsFolded: Bool? = nil
    var leadingWidth: CGFloat
    var contentLeadingInset: CGFloat
    var showsRoutines = true
    @ViewBuilder let page: (AppTab) -> Page

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(leadingWidth, contentLeadingInset) }
        set {
            leadingWidth = newValue.first
            contentLeadingInset = newValue.second
        }
    }

    var body: some View {
        ZStack(alignment: .leading) {
            ShellTabHost(store: store, navigation: navigation, bar: bar,
                         contentLeadingInset: contentLeadingInset, page: page)
                .environment(\.homeTaskColumn, wide)
                .environment(\.settingsColumnsFolded, settingsColumnsFolded)
                .ignoresSafeArea()
            if wide && showsRoutines {
                ShellRoutineColumn(store: store, width: leadingWidth, stride: contentLeadingInset)
            }
        }
    }
}

/// One persistent sidebar, above the chat layer in the app card or beside tabs in an isolated tab host.
struct ShellRoutineColumn: View {
    let store: CommaStore
    let width: CGFloat
    let stride: CGFloat
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var settingsDetail: Bool {
        navigation.tab == .settings && !navigation.settingsPath.isEmpty && !navigation.routerOpen
    }

    var body: some View {
        RoutineSidebar(store: store)
            .frame(width: width)
            .offset(x: settingsDetail ? -stride : 0)
            .animation(reduceMotion ? nil : CommaMotion.release, value: settingsDetail)
            .opacity(navigation.searchOpen ? 0 : 1)
            .allowsHitTesting(!settingsDetail && !navigation.searchOpen)
            .accessibilityHidden(settingsDetail || navigation.searchOpen)
    }
}

/// Hands each tab's page to the controller with the environment that does not cross into its hosting controller.
private struct ShellTabHost<Page: View>: UIViewControllerRepresentable {
    let store: CommaStore
    let navigation: AppNavigation
    let bar: ShellTabBar
    let contentLeadingInset: CGFloat
    @ViewBuilder let page: (AppTab) -> Page

    func makeUIViewController(context: Context) -> ShellTabsController<Page> {
        ShellTabsController(store: store, navigation: navigation, bar: bar, contentLeadingInset: contentLeadingInset) { tab in
            HostedContent(content: page(tab), environment: context.environment)
        }
    }

    func updateUIViewController(_ controller: ShellTabsController<Page>, context: Context) {
        controller.update(bar: bar, environment: context.environment, contentLeadingInset: contentLeadingInset) { tab in
            HostedContent(content: page(tab), environment: context.environment)
        }
    }
}
