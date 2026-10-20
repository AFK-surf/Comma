import SwiftUI
import UIKit

/// The system tab bar over `ShellTabs`' pages. Home, Inbox and Settings are its tabs, each with an empty stand-in
/// controller: the pages themselves stay on screen under the bar (`ShellTabsController`), so a switch swaps only the
/// stand-in. Task search's button sits beside Inbox; tapping it opens search over the tabs (`TaskSearchLayer`) and
/// leaves the bar's selection where it is. The router's circle is a search tab, which the bar shows apart from the
/// others; selecting it opens the router layer. Neither changes the selected tab.
final class ShellTabBarController: UITabBarController, UITabBarControllerDelegate,
    UILargeContentViewerInteractionDelegate, UIPointerInteractionDelegate {
    private let store: CommaStore
    private let navigation: AppNavigation
    private var items: [AppTab: UITab] = [:]
    private let router = UISearchTab { _ in UIViewController() }
    private let search = UITab(title: "", image: ShellTabArt.search, identifier: "search") { _ in UIViewController() }
    private var bar: ShellTabBar
    /// Over Task search's button, taking its touches from the bar. Pressed, the bar would slide its selection toward
    /// the button and back, as search never takes the selection, and the keyboard rising for search would cover that
    /// slide halfway. VoiceOver still reaches the button itself, whose selection opens search all the same.
    private let searchTouch = SearchTouch()
    /// Drawn over the router's circle: its reply animation and its count (`RouterCircleOverlay`).
    private let routerOverlay = UIHostingController(rootView: RouterCircleOverlay())
    /// The Inbox's and Settings' dots, drawn over the bar: the bar's own badge would be a large dot, where the app's
    /// dots are the small one the rows carry (`AttentionDot`).
    private var dots: [AppTab: UIView] = [:]
    /// When the circle next takes the router chat in, and the tap that goes with it.
    private var intakeBegins: CFTimeInterval = 0
    private var intakeTap: DispatchWorkItem?
    private lazy var intakeFeel = UIImpactFeedbackGenerator(style: .soft, view: view)

    init(store: CommaStore, navigation: AppNavigation, bar: ShellTabBar) {
        self.store = store
        self.navigation = navigation
        // The glyphs and the avatar below already show this much of `bar`; `apply` adds the rest.
        self.bar = ShellTabBar(selection: bar.selection, avatar: bar.avatar)
        super.init(nibName: nil, bundle: nil)
        var tabs: [UITab] = AppTab.allCases.map { tab in
            // Each tab starts with its final glyph: one changed before the bar's first layout left the selected
            // tab's title truncated.
            let image = tab.showsAvatar ? bar.avatar.flatMap(avatarImage)
                : ShellTabArt.glyph(tab, selected: tab == bar.selection)
            // Glyphs only, as the bar was drawn before; VoiceOver still reads each tab's name.
            let item = UITab(title: "", image: image, identifier: tab.identifier) { _ in UIViewController() }
            item.accessibilityLabel = tab.title
            item.accessibilityIdentifier = tab.identifier
            items[tab] = item
            return item
        }
        search.accessibilityLabel = String(localized: "Search tasks")
        search.accessibilityIdentifier = "openTaskSearch"
        tabs.insert(search, at: (tabs.firstIndex { $0 === items[.inbox] } ?? 0) + 1)
        // The mark alone, as on the other tabs: before iOS 26 the bar sets a title under it. VoiceOver reads the name.
        router.title = ""
        router.accessibilityLabel = String(localized: "Comma")
        router.image = ShellTabArt.mark
        router.accessibilityIdentifier = "openRouterChat"
        router.accessibilityHint = String(localized: "Opens your chat with Comma")
        tabs.append(router)
        self.tabs = tabs
        if #available(iOS 27.0, *) { prominentTabIdentifier = router.identifier }
        apply(bar)
        delegate = self
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        tabBar.tintColor = UIColor(CommaTheme.textPrimary)
        for tab in [AppTab.inbox, .settings] {
            let dot = UIView()
            dot.backgroundColor = UIColor(CommaTheme.brandSolid)
            dot.layer.cornerRadius = AttentionDot.size / 2
            dot.isUserInteractionEnabled = false
            dot.isHidden = !(tab == .inbox ? bar.inboxUnread : bar.settingsAttention)
            view.addSubview(dot)
            dots[tab] = dot
        }
        if #available(iOS 26.0, *) { tabBarMinimizeBehavior = .never }
        searchTouch.accessibilityElementsHidden = true
        searchTouch.pressed = { [weak self] down in self?.pressSearchGlyph(down) }
        searchTouch.lifted = { [weak self] point in self?.searchLifted(at: point) }
        // What the bar gives its other buttons and no longer reaches this one: the enlarged glyph a long press shows at
        // accessibility text sizes, and the pointer's hover.
        searchTouch.showsLargeContentViewer = true
        searchTouch.largeContentTitle = String(localized: "Search tasks")
        searchTouch.largeContentImage = ShellTabArt.search
        searchTouch.scalesLargeContentImage = true
        searchTouch.addInteraction(UILargeContentViewerInteraction(delegate: self))
        searchTouch.addInteraction(UIPointerInteraction(delegate: self))
        view.addSubview(searchTouch)
        routerOverlay.view.backgroundColor = .clear
        routerOverlay.view.isUserInteractionEnabled = false
        // Laid out on the circle, part of which lies in the bottom safe area.
        routerOverlay.safeAreaRegions = []
        addChild(routerOverlay)
        view.addSubview(routerOverlay.view)
        routerOverlay.didMove(toParent: self)
        navigation.routerLanding = { [weak self] landing in self?.takeRouterIn(landing) }
    }

    /// The closing router chat reaches the circle as `landing` says: the circle gives under it and springs back past
    /// its size, with a soft tap at the moment it is struck. Only the drawing moves; the bar's own layout is
    /// untouched. Nil calls off an intake still to come, and lets one under way finish.
    private func takeRouterIn(_ landing: RouterLanding?) {
        guard let circle = router.frame(in: view), !circle.isEmpty else { return }
        let layers = [routerCircleView(at: circle)?.layer, routerOverlay.view.layer].compactMap { $0 }
        guard let landing else {
            guard CACurrentMediaTime() < intakeBegins else { return }
            layers.forEach { $0.removeAnimation(forKey: "routerIntake") }
            intakeTap?.cancel()
            return
        }
        intakeBegins = CACurrentMediaTime() + landing.delay
        for layer in layers {
            let intake = landing.intake
            intake.beginTime = layer.convertTime(intakeBegins, from: nil)
            layer.add(intake, forKey: "routerIntake")
        }
        intakeFeel.prepare()
        let centre = CGPoint(x: circle.midX, y: circle.midY)
        let tap = DispatchWorkItem { [weak self] in
            self?.intakeFeel.impactOccurred(intensity: 0.4 + landing.depth * 2, at: centre)
        }
        intakeTap?.cancel()
        intakeTap = tap
        DispatchQueue.main.asyncAfter(deadline: .now() + landing.delay, execute: tap)
    }

    /// The bar's view drawing the router's circle, glass and glyph together: the outermost one under its centre
    /// that is the circle's size. The button the touch lands on draws only the glyph.
    private func routerCircleView(at circle: CGRect) -> UIView? {
        let centre = view.convert(CGPoint(x: circle.midX, y: circle.midY), to: tabBar)
        var candidate = tabBar.hitTest(centre, with: nil), circleView: UIView?
        while let current = candidate, current !== tabBar {
            let frame = current.convert(current.bounds, to: view)
            if abs(frame.width - circle.width) < 4, abs(frame.height - circle.height) < 4 { circleView = current }
            candidate = current.superview
        }
        return circleView
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        tabBar.layoutIfNeeded()
        placeDots()
        placeSearchTouch()
        guard let circle = router.frame(in: view), !circle.isEmpty else { return }
        // Where the router chat zooms out of and back into.
        navigation.routerButtonFrame = view.convert(circle, to: nil)
        routerOverlay.view.frame = circle
        view.bringSubviewToFront(routerOverlay.view)
    }

    /// The selected tab's stand-in, whose safe area holds the room the bar takes from the pages.
    var standIn: UIView? { selectedViewController?.view }

    /// Shows `next` in the bar, touching only what changed.
    func apply(_ next: ShellTabBar) {
        let last = bar
        bar = next
        if let item = items[next.selection], selectedTab !== item { selectedTab = item }
        if last.selection != next.selection {
            for tab in AppTab.allCases where !tab.showsAvatar {
                items[tab]?.image = ShellTabArt.glyph(tab, selected: tab == next.selection)
            }
        }
        if last.avatar != next.avatar, let avatar = next.avatar { items[.settings]?.image = avatarImage(avatar) }
        // Whatever a dot says, VoiceOver says too.
        if last.inboxUnread != next.inboxUnread {
            dots[.inbox]?.isHidden = !next.inboxUnread
            items[.inbox]?.accessibilityValue = next.inboxUnread ? String(localized: "Unread") : nil
        }
        if last.settingsAttention != next.settingsAttention {
            dots[.settings]?.isHidden = !next.settingsAttention
            items[.settings]?.accessibilityValue = next.settingsAttention ? String(localized: "Needs attention") : nil
        }
        if last.routerReplying != next.routerReplying || last.routerUnread != next.routerUnread {
            routerOverlay.rootView = RouterCircleOverlay(replying: next.routerReplying, unread: next.routerUnread)
            router.image = next.routerReplying ? ShellTabArt.blankMark : ShellTabArt.mark
            router.accessibilityValue = next.routerReplying ? String(localized: "Thinking")
                : next.routerUnread > 0 ? String(localized: "\(next.routerUnread) new replies") : nil
        }
    }

    /// Each dot on its tab's glyph's top-trailing corner, just clear of a 24pt glyph and of the 28pt avatar.
    private func placeDots() {
        let side = AttentionDot.size
        let reach: CGFloat = view.effectiveUserInterfaceLayoutDirection == .rightToLeft ? -13 : 13
        for (tab, dot) in dots {
            guard let item = items[tab]?.frame(in: view), !item.isEmpty else { continue }
            dot.frame = CGRect(x: item.midX + reach - side / 2, y: item.midY - 13 - side / 2, width: side, height: side)
            view.bringSubviewToFront(dot)
        }
    }

    /// Over the search button wherever the bar shows it; out of the way while the bar is hidden.
    private func placeSearchTouch() {
        let button = tabBar.isHidden ? nil : search.frame(in: view)
        searchTouch.isHidden = button?.isEmpty ?? true
        if let button { searchTouch.frame = button }
        view.bringSubviewToFront(searchTouch)
    }

    /// The button's glyph gives under the finger and springs back on release, as the app's icon buttons do
    /// (`TactileButtonStyle`), where the bar would have lifted its selection.
    private func pressSearchGlyph(_ down: Bool) {
        guard let glyph = searchGlyph else { return }
        if down {
            UIView.animate(.easeOut(duration: 0.05)) { glyph.transform = CGAffineTransform(scaleX: 0.9, y: 0.9) }
        } else {
            UIView.animate(CommaMotion.release) { glyph.transform = .identity }
        }
    }

    /// Lifted on the button, search opens. Lifted on another tab, as a finger slides along the bar, that tab is chosen,
    /// as the bar chooses the tab a slide ends on.
    private func searchLifted(at point: CGPoint) {
        if searchTouch.bounds.contains(point) { return navigation.openSearch() }
        let lift = searchTouch.convert(point, to: view)
        if let tab = AppTab.allCases.first(where: { items[$0]?.frame(in: view)?.contains(lift) == true }) {
            navigation.select(tab)
        }
    }

    /// The bar's view drawing the search button's glyph: the one a touch on the button lands on.
    private var searchGlyph: UIView? {
        let centre = view.convert(CGPoint(x: searchTouch.frame.midX, y: searchTouch.frame.midY), to: tabBar)
        return tabBar.hitTest(centre, with: nil).flatMap { $0 === tabBar ? nil : $0 }
    }

    // MARK: UITabBarControllerDelegate

    func tabBarController(_ controller: UITabBarController, shouldSelectTab tab: UITab) -> Bool {
        if tab === router {
            navigation.openRouter()
            return false
        }
        if tab === search {
            navigation.openSearch()
            return false
        }
        // Tapping the selected tab again returns it to its root; the page does that itself.
        if tab === controller.selectedTab, let again = appTab(tab) {
            navigation.select(again)
            return false
        }
        return true
    }

    func tabBarController(_ controller: UITabBarController, didSelectTab selected: UITab, previousTab: UITab?) {
        if let tab = appTab(selected), tab != navigation.tab { navigation.select(tab) }
    }

    // MARK: Search button

    func largeContentViewerInteraction(_ interaction: UILargeContentViewerInteraction,
                                       didEndOn item: (any UILargeContentViewerItem)?, at point: CGPoint) {
        if item === searchTouch { navigation.openSearch() }
    }

    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        interaction.view.map { UIPointerStyle(effect: .highlight(UITargetedPreview(view: $0))) }
    }

    // MARK: Drawing

    private func appTab(_ item: UITab) -> AppTab? { AppTab.allCases.first { items[$0] === item } }

    /// The member's avatar, drawn once per change at the size the bar shows its glyphs.
    private func avatarImage(_ key: AvatarKey) -> UIImage? {
        let avatar = UserAvatar(store: store, size: 28).environment(\.colorScheme, key.colorScheme)
        let renderer = ImageRenderer(content: avatar)
        renderer.scale = 3
        return renderer.uiImage?.withRenderingMode(.alwaysOriginal)
    }
}

/// The bar's images that do not depend on the member.
private enum ShellTabArt {
    /// A tab's glyph, filled while the tab is selected.
    static func glyph(_ tab: AppTab, selected: Bool) -> UIImage? {
        UIImage(named: selected ? "\(tab.icon)-fill" : tab.icon)
    }

    /// The Comma mark at the router circle's size, tinted by the bar like the tabs' glyphs.
    @MainActor static let mark: UIImage? = {
        guard let mark = UIImage(named: "CommaMark") else { return nil }
        let side = RouterCircleOverlay.markSide
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            mark.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        }.withRenderingMode(.alwaysTemplate)
    }()

    /// Task search's glyph, tinted by the bar like the tabs' glyphs.
    @MainActor static let search = UIImage(named: "icon-search")

    /// Keeps the circle's layout while the overlay's animation stands in for the mark.
    @MainActor static let blankMark = UIGraphicsImageRenderer(
        size: CGSize(width: RouterCircleOverlay.markSide, height: RouterCircleOverlay.markSide)
    ).image { _ in }.withRenderingMode(.alwaysTemplate)
}

/// Task search's button over the bar's own (`ShellTabBarController`): the press shows only while the finger is on the
/// button, and the lift is decided exactly where the finger leaves, not with a control's usual slack around it, which
/// reached the next tab.
private final class SearchTouch: UIControl {
    /// The press shows on the glyph, or no longer does.
    var pressed: (Bool) -> Void = { _ in }
    /// The finger left the screen here, in the control's space.
    var lifted: (CGPoint) -> Void = { _ in }
    private var down = false

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        press(true)
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        press(bounds.contains(touch.location(in: self)))
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        press(false)
        if let touch { lifted(touch.location(in: self)) }
    }

    override func cancelTracking(with event: UIEvent?) { press(false) }

    private func press(_ next: Bool) {
        guard next != down else { return }
        down = next
        pressed(next)
    }
}
