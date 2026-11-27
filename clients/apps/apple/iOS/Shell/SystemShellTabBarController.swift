import SwiftUI
import UIKit

/// The system tab bar over Home, Inbox, People and Settings, before iOS 26: the glass bar and its menu need iOS 26
/// (`ShellTabBarController`), so here Apps, Drive and Plugins stay in Settings. The separate router circle opens the
/// chat layer.
final class SystemShellTabBarController: UITabBarController, UITabBarControllerDelegate, ShellBar {
    private let store: CommaStore
    private let navigation: AppNavigation
    private var items: [AppTab: UITab] = [:]
    private let router = UISearchTab { _ in ShellTabStandInController() }
    private var bar: ShellTabBar
    /// At rest UIKit draws the glass and the mark and handles the press. During a zoom the face carries both with it.
    let routerFace = UIVisualEffectView()
    /// The unread count badge, hosted outside `routerFace` so UIKit's circular zoom portal never clips it.
    private let routerBadgeView = UIHostingConfiguration { RouterBadgeOverlay() }
        .margins(.all, 0).makeContentView()
    var routerBadge: UIView { routerBadgeView }
    private let routerMark = UIHostingConfiguration { RouterCircleOverlay() }
        .margins(.all, 0).makeContentView()
    private let visibleTabs = CALayer()
    private var originalMask: CALayer?
    private weak var zoomPage: UIView?
    private weak var zoomViewport: UIView?
    /// The face is in a zoom's page and draws the mark, which the bar's own button, masked away, does not.
    private var faceAway = false
    /// Hidden while the router chat is opening, open, or being dragged to close, so the badge never floats over the chat.
    private(set) var routerBadgeHidden = false
    /// The page owner follows the system bar's settled safe area, including its first layout.
    var contentLayoutChanged: (() -> Void)?
    /// The Inbox's and Settings' dots, drawn over the bar: the bar's own badge would be a large dot, where the app's
    /// dots are the small one the rows carry (`AttentionDot`).
    private var dots: [AppTab: UIView] = [:]

    init(store: CommaStore, navigation: AppNavigation, bar: ShellTabBar) {
        self.store = store
        self.navigation = navigation
        // The glyphs and the avatar below already show this much of `bar`; `apply` adds the rest.
        self.bar = ShellTabBar(selection: bar.selection, avatar: bar.avatar)
        super.init(nibName: nil, bundle: nil)
        var tabs: [UITab] = AppTab.systemBarTabs.map { tab in
            // Each tab starts with its final glyph: one changed before the bar's first layout left the selected
            // tab's title truncated.
            let image = tab.showsAvatar ? bar.avatar.flatMap(avatarImage)
                : ShellTabArt.glyph(tab, selected: tab == bar.selection)
            // Glyphs only, as the bar was drawn before; VoiceOver still reads each tab's name.
            let item = UITab(title: "", image: image, identifier: tab.identifier) { _ in ShellTabStandInController() }
            item.accessibilityLabel = tab.title
            item.accessibilityIdentifier = tab.identifier
            items[tab] = item
            return item
        }
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
        routerFace.isUserInteractionEnabled = false
        routerFace.accessibilityElementsHidden = true
        routerFace.backgroundColor = .clear
        routerFace.isOpaque = false
        routerFace.layer.cornerCurve = .continuous
        visibleTabs.backgroundColor = UIColor.black.cgColor
        if #available(iOS 26.0, *) {
            routerFace.cornerConfiguration = .capsule()
        }
        routerMark.frame = routerFace.contentView.bounds
        routerMark.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        routerMark.backgroundColor = .clear
        routerFace.contentView.addSubview(routerMark)
        routerBadge.isUserInteractionEnabled = false
        routerBadge.accessibilityElementsHidden = true
        routerBadge.backgroundColor = .clear
        routerBadge.isOpaque = false
        routerBadge.clipsToBounds = false
        navigation.routerTabBar = self
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        tabBar.layoutIfNeeded()
        placeDots()
        layoutRouterCircle()
    }

    /// UIKit composites the zoom source in the presenting page. That page overlays the bar and has the same
    /// bounds as the viewport, even while UIKit moves it.
    func zoomSource(in page: UIView, viewport: UIView) -> UIView? {
        guard let window = viewIfLoaded?.window, window === viewport.window else { return nil }
        zoomPage = page
        zoomViewport = viewport
        return layoutRouterCircle()
    }

    func restoreRouterFace(from page: UIView, revealBadge: Bool = true) {
        guard zoomPage === page else { return }
        zoomPage = nil
        zoomViewport = nil
        if revealBadge { setRouterBadgeHidden(false) }
        layoutRouterCircle()
    }

    /// Hides or reveals the router's unread badge across the zoom transition so it never floats over the moving chat
    /// or sits clipped inside UIKit's circular zoom portal.
    func setRouterBadgeHidden(_ hidden: Bool, animated: Bool = true) {
        guard hidden != routerBadgeHidden else { return }
        routerBadgeHidden = hidden
        if animated {
            showRouterBadge()
        } else {
            UIView.performWithoutAnimation {
                showRouterBadge()
                routerBadge.layoutIfNeeded()
            }
        }
    }

    /// The overlay's mark and reply animation, for the bar as it is and wherever the face is.
    private func showRouterOverlay() {
        let replying = bar.routerReplying, away = faceAway
        routerMark.configuration = UIHostingConfiguration {
            RouterCircleOverlay(replying: replying, restingMark: away)
        }.margins(.all, 0)
    }

    private func showRouterBadge() {
        let unread = bar.routerUnread, visible = !routerBadgeHidden
        routerBadgeView.configuration = UIHostingConfiguration {
            RouterBadgeOverlay(unread: unread, visible: visible)
        }.margins(.all, 0)
    }

    @discardableResult private func layoutRouterCircle() -> UIView? {
        guard let barView = viewIfLoaded else { return nil }
        let host = zoomPage ?? barView
        let badgeHost = zoomViewport ?? barView
        guard let circle = router.frame(in: zoomViewport ?? barView), !circle.isEmpty else {
            if zoomPage == nil {
                setFaceAway(false)
                setVisibleTabs(nil)
                routerFace.removeFromSuperview()
                routerBadge.removeFromSuperview()
            }
            return nil
        }
        let shownTabs = zoomPage == nil ? nil : primaryBarFrame(in: barView)
        // Leaving the bar, the face draws the mark itself before the bar's glyph is masked away with its glass. A bar
        // whose button is not a detached circle keeps drawing its own glyph, so the face draws none over it.
        setFaceAway(shownTabs != nil)
        setVisibleTabs(shownTabs)
        if routerFace.superview !== host { host.addSubview(routerFace) }
        routerFace.frame = circle
        host.bringSubviewToFront(routerFace)
        if #unavailable(iOS 26.0) {
            routerFace.layer.cornerRadius = min(circle.width, circle.height) / 2
        }
        if routerBadge.superview !== badgeHost { badgeHost.addSubview(routerBadge) }
        routerBadge.frame = circle
        badgeHost.bringSubviewToFront(routerBadge)
        return routerFace
    }

    private func setFaceAway(_ away: Bool) {
        guard away != faceAway else { return }
        faceAway = away
        showRouterOverlay()
        routerMark.layoutIfNeeded()
    }

    /// The system lays the separate action beyond all the regular tabs, with a gap between their surfaces.
    /// Get that gap from the actual items, including when the bar is on another edge or in right-to-left layout.
    private func primaryBarFrame(in barView: UIView) -> CGRect? {
        guard #available(iOS 26.0, *), let slot = router.frame(in: barView),
              abs(slot.width - slot.height) < 1 else { return nil }
        let frames = items.values.compactMap { $0.frame(in: barView) }
        guard frames.count == items.count else { return nil }
        let tabs = frames.reduce(CGRect.null) { $0.union($1) }
        let bounds = barView.bounds
        if tabs.maxX < slot.minX {
            let split = (tabs.maxX + slot.minX) / 2
            return bounds.divided(atDistance: split - bounds.minX, from: .minXEdge).slice
        }
        if tabs.minX > slot.maxX {
            let split = (tabs.minX + slot.maxX) / 2
            return bounds.divided(atDistance: bounds.maxX - split, from: .maxXEdge).slice
        }
        if tabs.maxY < slot.minY {
            let split = (tabs.maxY + slot.minY) / 2
            return bounds.divided(atDistance: split - bounds.minY, from: .minYEdge).slice
        }
        if tabs.minY > slot.maxY {
            let split = (tabs.minY + slot.maxY) / 2
            return bounds.divided(atDistance: bounds.maxY - split, from: .maxYEdge).slice
        }
        return nil
    }

    /// UIKit composites the material outside the tab item's own layer. Clip the bar controller's drawing
    /// while its detached glass travels with the mark. The native tab keeps its layout and hit target.
    private func setVisibleTabs(_ frame: CGRect?) {
        guard let layer = viewIfLoaded?.layer else { return }
        guard let frame else {
            if layer.mask === visibleTabs {
                layer.mask = originalMask
                originalMask = nil
                routerFace.effect = nil
            }
            return
        }
        guard layer.mask !== visibleTabs || visibleTabs.frame != frame else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        visibleTabs.frame = frame
        if layer.mask !== visibleTabs {
            originalMask = layer.mask
            layer.mask = visibleTabs
        }
        if #available(iOS 26.0, *) {
            routerFace.effect = UIGlassEffect(style: .regular)
        }
        CATransaction.commit()
    }

    /// The selected tab's stand-in, whose safe area holds the room the bar takes from the pages.
    var standIn: UIView? { selectedViewController?.view }

    /// Whether `hit` is part of the bar: not the controller's own view, nor the stand-in, its subviews or the views
    /// that hold it.
    func drawsBar(_ hit: UIView) -> Bool {
        guard hit !== view else { return false }
        guard let standIn = selectedViewController?.view else { return true }
        return !standIn.isDescendant(of: hit) && !hit.isDescendant(of: standIn)
    }

    /// Shows `next` in the bar, touching only what changed.
    func apply(_ next: ShellTabBar) {
        let last = bar
        bar = next
        if let item = items[next.selection], selectedTab !== item { selectedTab = item }
        if last.selection != next.selection {
            for tab in AppTab.systemBarTabs where !tab.showsAvatar {
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
        if last.routerReplying != next.routerReplying {
            showRouterOverlay()
            router.image = next.routerReplying ? ShellTabArt.blankMark : ShellTabArt.mark
        }
        if last.routerUnread != next.routerUnread {
            showRouterBadge()
        }
        if last.routerReplying != next.routerReplying || last.routerUnread != next.routerUnread {
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

    // MARK: UITabBarControllerDelegate

    func tabBarController(_ controller: UITabBarController, shouldSelectTab tab: UITab) -> Bool {
        if tab === router {
            navigation.openRouter()
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

    // MARK: Drawing

    private func appTab(_ item: UITab) -> AppTab? { AppTab.systemBarTabs.first { items[$0] === item } }

    /// The member's avatar, drawn once per change at the size the bar shows its glyphs.
    private func avatarImage(_ key: AvatarKey) -> UIImage? {
        let avatar = UserAvatar(store: store, size: 28).environment(\.colorScheme, key.colorScheme)
        let renderer = ImageRenderer(content: avatar)
        renderer.scale = 3
        return renderer.uiImage?.withRenderingMode(.alwaysOriginal)
    }
}

/// UIKit updates the selected content safe area independently of the container's layout.
private final class ShellTabStandInController: UIViewController {
    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        view.setNeedsLayout()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let bar = tabBarController as? SystemShellTabBarController, bar.selectedViewController === self else { return }
        bar.contentLayoutChanged?()
    }
}
