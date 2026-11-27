import SwiftUI
import UIKit

/// What the pages' owner and the router's zoom need of the tab bar, whichever one draws it.
@MainActor protocol ShellBar: UIViewController {
    /// The page owner follows the bar's room, including its first layout.
    var contentLayoutChanged: (() -> Void)? { get set }
    /// A view whose safe area holds the room the bar takes from the pages.
    var standIn: UIView? { get }
    /// The circle's face, which a zoom to the chat carries with it.
    var routerFace: UIVisualEffectView { get }
    /// The unread count badge, hosted outside `routerFace` so UIKit's circular zoom portal never clips it.
    var routerBadge: UIView { get }
    /// Hidden while the router chat is opening, open, or being dragged to close, so the badge never floats over the chat.
    var routerBadgeHidden: Bool { get }
    /// Whether `hit`, found in the bar controller's view, is the bar and not the empty room over the pages.
    func drawsBar(_ hit: UIView) -> Bool
    func apply(_ next: ShellTabBar)
    func zoomSource(in page: UIView, viewport: UIView) -> UIView?
    func restoreRouterFace(from page: UIView, revealBadge: Bool)
    func setRouterBadgeHidden(_ hidden: Bool, animated: Bool)
}

@MainActor extension ShellBar {
    func restoreRouterFace(from page: UIView, revealBadge: Bool = true) {
        restoreRouterFace(from: page, revealBadge: revealBadge)
    }

    func setRouterBadgeHidden(_ hidden: Bool, animated: Bool = true) {
        setRouterBadgeHidden(hidden, animated: animated)
    }
}

/// Hosts a real native `UITabBarController` (`systemBar`) over Home, Inbox, People, a 4th overflow slot (`More`),
/// and the detached router circle (`UISearchTab` + `prominentTabIdentifier`), with `TabOverflowMenuView` layered as
/// a sibling above `systemBar.view`.
///
/// Resting, tab tapping, tab dragging, Duo vertical side-bar widening (`48pt <-> 72.5pt`), and the 120 Hz native
/// Liquid Glass selection lens across all 5 postures (iPhone portrait, iPhone compact landscape, Duo unfolded portrait,
/// Duo vertical trailing & leading) are driven 100 % natively by `systemBar`. Keeping `overflowMenu` above
/// `systemBar.view` lets us mask `systemBar.view.layer` to the router circle's half-plane while the overflow menu is
/// open or morphing—clipping 100 % of iOS 26/27 Liquid Glass portals, Duo vertical rails, and lifted lenses without
/// ever hiding any tab button from UIKit accessibility or letting a lifted lens draw over the open menu.
@available(iOS 26.0, *)
final class ShellTabBarController: UIViewController, UITabBarControllerDelegate, UIGestureRecognizerDelegate, ShellBar {
    private static let primaryTabs: [AppTab] = AppTab.allCases.filter { !$0.inMenu }
    private static let overflowTabs: [AppTab] = AppTab.allCases.filter(\.inMenu)

    /// The real native iOS 26/27 `UITabBarController` driving resting layout, 120 Hz tab switching, and Duo rail widening.
    let systemBar = UITabBarController()

    private let store: CommaStore
    private let navigation: AppNavigation
    private var bar: ShellTabBar
    private var items: [AppTab: UITab] = [:]
    private let moreTab: UITab
    private let router: UISearchTab
    /// Which overflow page the 4th slot currently displays.
    private var overflowSelection: AppTab
    private var cachedAvatarImage: UIImage?
    private var cachedAvatarKey: AvatarKey?

    private struct MoreArtKey: Equatable {
        let tab: AppTab
        let avatar: AvatarKey?
        let style: UIUserInterfaceStyle
        let orientation: TabOverflowMenuView.Orientation
    }
    private var lastMoreArtKey: MoreArtKey?

    /// Liquid Glass overflow menu overlay; stays hidden (`isHidden = true`, zero `CADisplayLink`) except while open/morphing.
    let overflowMenu = TabOverflowMenuView()
    private let systemBarMask = CALayer()
    private var originalSystemBarMask: CALayer?
    private struct WeakView { weak var view: UIView? }
    private var hiddenNativeViews: [WeakView] = []

    /// Cached resting primary platter, slot & router rects (captured while neither dragging nor showing the overflow
    /// menu) so mid-drag handoffs anchor to exact resting geometry even while iOS scales a pressed bar or widens Duo.
    private var restingPlatterFrame: CGRect?
    private var restingSlotFrames: [CGRect]?
    private var restingRouterFrame: CGRect?
    private var restingPillSize: CGSize?
    private var restingPillEdgeInset: CGFloat?

    /// Passive press/drag observer + takeover recognizer for opening the overflow menu from a tap or drag onto `More`.
    private let press = UILongPressGestureRecognizer()
    private let takeOver = TakeOverRecognizer()
    private var startedOnRegularTab = false
    private var openedOnTouchDown = false
    private var menuDwell: DispatchWorkItem?
    private var dwellPoint: CGPoint = .zero
    private var dwellAnchor: CGPoint = .zero
    private var lastLayoutSize: CGSize = .zero

    /// At rest UIKit draws the glass and the mark and handles the press. During a zoom the face carries both with it.
    let routerFace = UIVisualEffectView()
    /// The unread count badge, hosted outside `routerFace` so UIKit's circular zoom portal never clips it.
    private let routerBadgeView = UIHostingConfiguration { RouterBadgeOverlay() }
        .margins(.all, 0).makeContentView()
    var routerBadge: UIView { routerBadgeView }
    private let routerMark = UIHostingConfiguration { RouterCircleOverlay() }
        .margins(.all, 0).makeContentView()
    private weak var zoomPage: UIView?
    private weak var zoomViewport: UIView?
    private var faceAway = false
    /// Hidden while the router chat is opening, open, or being dragged to close, so the badge never floats over the chat.
    private(set) var routerBadgeHidden = false

    /// The page owner follows the system bar's settled safe area, including its first layout.
    var contentLayoutChanged: (() -> Void)?
    /// The Inbox's and Settings' dots, drawn over the bar (`AttentionDot`). Settings is in the menu, so its dot rides `More`.
    private var dots: [AppTab: UIView] = [:]

    init(store: CommaStore, navigation: AppNavigation, bar: ShellTabBar) {
        self.store = store
        self.navigation = navigation
        self.bar = ShellTabBar(selection: bar.selection, avatar: bar.avatar)
        self.overflowSelection = bar.selection.inMenu ? bar.selection : (Self.overflowTabs.first ?? .apps)
        var onStandInLayout: ((UIViewController) -> Void)?
        let makeStandIn: (UITab) -> UIViewController = { _ in
            ShellBarStandInController { standIn in onStandInLayout?(standIn) }
        }
        self.moreTab = UITab(title: "", image: nil, identifier: "tab-more", viewControllerProvider: makeStandIn)
        self.router = UISearchTab(viewControllerProvider: makeStandIn)
        super.init(nibName: nil, bundle: nil)
        onStandInLayout = { [weak self] standIn in self?.handleStandInLayout(standIn) }

        var builtTabs: [UITab] = Self.primaryTabs.map { tab in
            let normal = ShellTabArt.glyph(tab, selected: false)
            let filled = ShellTabArt.glyph(tab, selected: true)
            let initialImage: UIImage?
            if #available(iOS 26.1, *) {
                initialImage = normal
            } else {
                initialImage = tab == bar.selection ? filled : normal
            }
            let item = UITab(title: "", image: initialImage, identifier: tab.identifier, viewControllerProvider: makeStandIn)
            if #available(iOS 26.1, *) {
                item.selectedImage = filled
            }
            item.accessibilityLabel = tab.title
            item.accessibilityIdentifier = tab.identifier
            items[tab] = item
            return item
        }

        moreTab.accessibilityIdentifier = "tab-more"
        builtTabs.append(moreTab)

        router.title = ""
        router.accessibilityLabel = String(localized: "Comma")
        router.image = ShellTabArt.mark
        router.accessibilityIdentifier = "openRouterChat"
        router.accessibilityHint = String(localized: "Opens your chat with Comma")
        builtTabs.append(router)

        systemBar.tabs = builtTabs
        if #available(iOS 27.0, *) { systemBar.prominentTabIdentifier = router.identifier }
        systemBar.delegate = self

        refreshMoreTabArt(force: true)
        syncOverflowMenuModel()
        apply(bar)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        let primaryTint = UIColor(CommaTheme.textPrimary)
        view.backgroundColor = .clear
        view.tintColor = primaryTint

        // Embed the real native `UITabBarController`. Setting `tintColor` on `systemBar.view` as well as
        // `systemBar.tabBar` ensures Duo's vertical rail inherits `CommaTheme.textPrimary` instead of `.systemBlue`.
        addChild(systemBar)
        systemBar.view.backgroundColor = .clear
        systemBar.view.tintColor = primaryTint
        systemBar.tabBar.tintColor = primaryTint
        systemBar.tabBarMinimizeBehavior = .never
        systemBar.view.frame = view.bounds
        systemBar.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(systemBar.view)
        systemBar.didMove(toParent: self)

        routerFace.isUserInteractionEnabled = false
        routerFace.accessibilityElementsHidden = true
        routerFace.backgroundColor = .clear
        routerFace.isOpaque = false
        routerFace.layer.cornerCurve = .continuous
        routerFace.cornerConfiguration = .capsule()
        systemBarMask.backgroundColor = UIColor.black.cgColor
        routerMark.frame = routerFace.contentView.bounds
        routerMark.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        routerMark.backgroundColor = .clear
        routerFace.contentView.addSubview(routerMark)
        routerBadge.isUserInteractionEnabled = false
        routerBadge.accessibilityElementsHidden = true
        routerBadge.backgroundColor = .clear
        routerBadge.isOpaque = false
        routerBadge.clipsToBounds = false

        // Sibling ABOVE `systemBar.view` so no native Liquid Glass portal or lifted lens can draw over the open menu,
        // and masking `systemBar.view.layer` never clips `overflowMenu`.
        overflowMenu.frame = view.bounds
        overflowMenu.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overflowMenu.onPick = { [weak self] id in self?.handleOverflowPick(id) }
        overflowMenu.onOpenChange = { [weak self] open in
            self?.setNativeChromeHiddenWhileOpen(open)
        }
        overflowMenu.onVisibilityChange = { [weak self] visible in
            if !visible {
                self?.clearStrandedDragScales()
            }
            self?.layoutRouterCircle()
        }
        overflowMenu.onTabsShownChange = { [weak self] shown in
            self?.updateDotsForMorph(shown)
        }
        view.addSubview(overflowMenu)

        // Unread/attention dots sit ABOVE `overflowMenu` (fading with `tabsShown`) so `overflowMenu`'s `UIGlassEffect`
        // never samples or refracts the blue dot while the menu closes.
        for tab in [AppTab.inbox, .settings] {
            let dot = UIView()
            dot.backgroundColor = UIColor(CommaTheme.brandSolid)
            dot.layer.cornerRadius = AttentionDot.size / 2
            dot.isUserInteractionEnabled = false
            dot.isHidden = !(tab == .inbox ? bar.inboxUnread : bar.settingsAttention)
            view.addSubview(dot)
            dots[tab] = dot
        }

        press.addTarget(self, action: #selector(handleBarPress(_:)))
        press.minimumPressDuration = 0
        press.allowableMovement = .greatestFiniteMagnitude
        press.cancelsTouchesInView = false
        press.delaysTouchesEnded = false
        press.delegate = self
        view.addGestureRecognizer(press)

        takeOver.onTouchDown = { [weak self] point in
            self?.handleTouchDown(at: point)
        }
        takeOver.delegate = self
        view.addGestureRecognizer(takeOver)

        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitVerticalSizeClass.self, UITraitLayoutDirection.self]) { (self: Self, _) in
            self.restingPlatterFrame = nil
            self.restingSlotFrames = nil
            self.restingRouterFrame = nil
            self.restingPillSize = nil
            self.restingPillEdgeInset = nil
            self.refreshMoreTabArt(force: false)
        }

        navigation.routerTabBar = self
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if systemBar.view.frame != view.bounds {
            systemBar.view.frame = view.bounds
        }
        systemBar.view.layoutIfNeeded()
        systemBar.tabBar.layoutIfNeeded()
        if lastLayoutSize != .zero, lastLayoutSize != view.bounds.size {
            restingPlatterFrame = nil
            restingSlotFrames = nil
            restingRouterFrame = nil
            restingPillSize = nil
            restingPillEdgeInset = nil
            if overflowMenu.isActive {
                overflowMenu.dismissImmediately()
            }
        }
        lastLayoutSize = view.bounds.size
        refreshOverlayLayout()
    }

    private func handleStandInLayout(_ standIn: UIViewController) {
        guard systemBar.selectedViewController === standIn else { return }
        if isViewLoaded { refreshOverlayLayout() }
        contentLayoutChanged?()
    }

    private func refreshOverlayLayout() {
        cacheRestingGeometryIfIdle()
        refreshMoreTabArt(force: false)
        placeDots()
        layoutRouterCircle()
        updateSystemBarMask()
        ensureOverlayZOrder()
    }

    /// Keeps strict z-order: `systemBar.view` < `routerFace` < `overflowMenu` < unread `dots`.
    private func ensureOverlayZOrder() {
        view.bringSubviewToFront(overflowMenu)
        for dot in dots.values where dot.superview === view {
            view.bringSubviewToFront(dot)
        }
    }

    // MARK: ShellBar

    /// The selected tab's stand-in, whose safe area holds the room the bar takes from the pages.
    var standIn: UIView? { systemBar.selectedViewController?.view }

    /// Whether `hit` is part of the bar or open overflow menu rather than the empty stand-in over pages.
    func drawsBar(_ hit: UIView) -> Bool {
        if overflowMenu.isOpen { return true }
        guard hit !== view, hit !== systemBar.view else { return false }
        guard let standIn = systemBar.selectedViewController?.view else { return true }
        return !standIn.isDescendant(of: hit) && !hit.isDescendant(of: standIn)
    }

    /// Shows `next` in the bar, touching only what changed (zero work during normal tab taps on iOS 26.1+).
    func apply(_ next: ShellTabBar) {
        let last = bar
        bar = next
        let targetTab: UITab?
        if next.selection.inMenu {
            if overflowSelection != next.selection {
                overflowSelection = next.selection
            }
            targetTab = moreTab
        } else {
            targetTab = items[next.selection]
        }
        if let targetTab, systemBar.selectedTab !== targetTab {
            systemBar.selectedTab = targetTab
        }
        if #unavailable(iOS 26.1) {
            if last.selection != next.selection {
                for tab in Self.primaryTabs {
                    items[tab]?.image = ShellTabArt.glyph(tab, selected: tab == next.selection)
                }
            }
        }
        if last.avatar != next.avatar || next.selection.inMenu {
            refreshMoreTabArt(force: false)
        }
        if overflowMenu.isActive {
            syncOverflowMenuModel()
        }
        if last.inboxUnread != next.inboxUnread {
            dots[.inbox]?.isHidden = !next.inboxUnread
            items[.inbox]?.accessibilityValue = next.inboxUnread ? String(localized: "Unread") : nil
        }
        if last.settingsAttention != next.settingsAttention {
            dots[.settings]?.isHidden = !next.settingsAttention
            moreTab.accessibilityValue = next.settingsAttention ? String(localized: "Needs attention") : nil
        }
        var values: [String: String] = [:]
        if next.inboxUnread { values[AppTab.inbox.identifier] = String(localized: "Unread") }
        if next.settingsAttention { values[AppTab.settings.identifier] = String(localized: "Needs attention") }
        overflowMenu.itemValues = values

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

    // MARK: Router Zoom Transition

    func zoomSource(in page: UIView, viewport: UIView) -> UIView? {
        guard let window = viewIfLoaded?.window, window === viewport.window else { return nil }
        overflowMenu.dismissImmediately()
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
        let liveCircle = router.frame(in: zoomViewport ?? barView)
        let circle: CGRect
        if zoomPage == nil, overflowMenu.isActive, let cached = restingRouterFrame, !cached.isEmpty {
            circle = cached
        } else if let liveCircle, !liveCircle.isEmpty {
            circle = liveCircle
        } else {
            if zoomPage == nil {
                setFaceAway(false)
                updateSystemBarMask()
                routerFace.removeFromSuperview()
                routerBadge.removeFromSuperview()
            }
            return nil
        }
        let standaloneFace = (zoomPage != nil && primaryBarRegion(in: systemBar.view) != nil) || overflowMenu.isActive
        setFaceAway(standaloneFace)
        updateSystemBarMask()
        if routerFace.superview !== host {
            if host === barView {
                barView.insertSubview(routerFace, belowSubview: overflowMenu)
            } else {
                host.addSubview(routerFace)
            }
        }
        if routerFace.frame != circle { routerFace.frame = circle }
        if host !== barView, host.subviews.last !== routerFace {
            host.bringSubviewToFront(routerFace)
        }
        if routerBadge.superview !== badgeHost {
            if badgeHost === barView {
                barView.insertSubview(routerBadge, belowSubview: overflowMenu)
            } else {
                badgeHost.addSubview(routerBadge)
            }
        }
        if routerBadge.frame != circle { routerBadge.frame = circle }
        if badgeHost !== barView, badgeHost.subviews.last !== routerBadge {
            badgeHost.bringSubviewToFront(routerBadge)
        }
        return routerFace
    }

    private func setFaceAway(_ away: Bool) {
        guard away != faceAway else { return }
        faceAway = away
        showRouterOverlay()
        routerMark.layoutIfNeeded()
    }

    /// Half-plane of `target` containing the primary 4-tab bar (excluding the detached router circle).
    private func primaryBarRegion(in target: UIView) -> CGRect? {
        guard let slot = router.frame(in: target), abs(slot.width - slot.height) < 1 else { return nil }
        let primary = Self.primaryTabs.compactMap { items[$0]?.frame(in: target) } + [moreTab.frame(in: target)].compactMap { $0 }
        guard primary.count == Self.primaryTabs.count + 1 else { return nil }
        let tabs = primary.reduce(CGRect.null) { $0.union($1) }
        let bounds = target.bounds
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

    /// Masks `systemBar.view.layer` for whichever exclusive overlay owns the bar:
    /// - Router zoom (`zoomPage != nil`): shows only `primaryBarRegion` while `routerFace` flies with the chat.
    /// - Overflow menu (`overflowMenu.isActive`): masks `systemBar.view.layer` to `.zero`, hiding 100 % of UIKit's
    ///   `UIGlassContainerEffect` (including any metaball merge bridge between a pressed platter and the router circle,
    ///   Duo vertical rails, and lifted lenses) while keeping every tab button at `alpha == 1` for AX; standalone
    ///   `routerFace` (`routerGlass` + `RouterCircleOverlay`) draws the clean circular router button above it.
    /// - Rest: removes our mask so `systemBar` renders 100 % untouched.
    private func updateSystemBarMask() {
        guard isViewLoaded, systemBar.isViewLoaded else { return }
        let layer = systemBar.view.layer
        let desiredFrame: CGRect?
        let showRouterGlass: Bool
        if zoomPage != nil, let primary = primaryBarRegion(in: systemBar.view) {
            desiredFrame = primary
            showRouterGlass = true
        } else if overflowMenu.isActive {
            desiredFrame = .zero
            showRouterGlass = true
        } else {
            desiredFrame = nil
            showRouterGlass = false
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let frame = desiredFrame {
            if systemBarMask.frame != frame { systemBarMask.frame = frame }
            if layer.mask !== systemBarMask {
                originalSystemBarMask = layer.mask
                layer.mask = systemBarMask
            }
        } else if layer.mask === systemBarMask {
            layer.mask = originalSystemBarMask
            originalSystemBarMask = nil
        }
        if showRouterGlass {
            if routerFace.effect == nil {
                routerFace.effect = UIGlassEffect(style: .regular)
            }
        } else if routerFace.effect != nil {
            routerFace.effect = nil
        }
        CATransaction.commit()
    }

    /// Hides `systemBar.view` and every visible non-standIn descendant view while `overflowMenu.isOpen == true`,
    /// restoring them the instant closing begins (before the `0.3 s` closing morph finishes).
    ///
    /// On iOS 27 iPhone Duo's vertical rail, UIKit renders the lifted `_UILiquidLensView` via a window-level
    /// `CAPortalLayer` that bypasses ancestor `CALayer.mask` clipping; setting `isHidden = true` directly on every
    /// visible non-standIn source view silences that portal with 100% public UIKit APIs, while restoring
    /// `isHidden = false` as soon as `close()` begins keeps `tab-more` accessibility intact during close.
    private func setNativeChromeHiddenWhileOpen(_ hidden: Bool) {
        guard isViewLoaded, systemBar.isViewLoaded else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if hidden {
            if hiddenNativeViews.isEmpty {
                let standInView = standIn
                func hideChrome(in current: UIView) {
                    guard !current.isHidden else { return }
                    if let standInView, current === standInView || current.isDescendant(of: standInView) {
                        return
                    }
                    if let standInView, standInView.isDescendant(of: current) {
                        for sub in current.subviews { hideChrome(in: sub) }
                        return
                    }
                    hiddenNativeViews.append(WeakView(view: current))
                    current.isHidden = true
                    for sub in current.subviews { hideChrome(in: sub) }
                }
                hideChrome(in: systemBar.view)
                if !systemBar.view.isHidden {
                    hiddenNativeViews.append(WeakView(view: systemBar.view))
                    systemBar.view.isHidden = true
                }
            }
        } else if !hiddenNativeViews.isEmpty {
            for entry in hiddenNativeViews {
                entry.view?.isHidden = false
            }
            hiddenNativeViews.removeAll()
            clearStrandedDragScales()
        }
        CATransaction.commit()
    }

    /// Clears any residual lifted-lens uniform scale (e.g. UIKit's `1.16×` `_UITabButton` glyph magnification inside
    /// `SelectedContentView`) left stranded when a drag onto `More` is interrupted by touch-up or `shouldSelectTab`
    /// while `systemBar.view` is hidden. Uses only public `UIView.transform` geometry (pure uniform scale `1.01...1.5`,
    /// zero rotation/translation) so rotated or resting views are never touched.
    private func clearStrandedDragScales() {
        guard isViewLoaded, systemBar.isViewLoaded else { return }
        let standInView = standIn
        UIView.performWithoutAnimation {
            func reset(in current: UIView) {
                if let standInView, current === standInView || current.isDescendant(of: standInView) {
                    return
                }
                let t = current.transform
                if abs(t.b) < 0.001, abs(t.c) < 0.001, abs(t.tx) < 0.001, abs(t.ty) < 0.001,
                   abs(t.a - t.d) < 0.01, t.a > 1.01, t.a <= 1.5 {
                    current.layer.removeAllAnimations()
                    current.transform = .identity
                }
                for sub in current.subviews { reset(in: sub) }
            }
            reset(in: systemBar.view)
        }
    }

    // MARK: Dots

    private func placeDots() {
        let side = AttentionDot.size
        let reach: CGFloat = view.effectiveUserInterfaceLayoutDirection == .rightToLeft ? -13 : 13
        let slots: [AppTab: CGRect?] = [
            .inbox: items[.inbox]?.frame(in: view),
            .settings: moreTab.frame(in: view),
        ]
        let scale = overflowMenu.isActive ? overflowMenu.barMajorScale : 1
        let platter = restingPlatterFrame ?? primaryPlatterFrame(in: view)
        let isVertical = platter.map { $0.height > $0.width * 1.5 } ?? false
        for (tab, dot) in dots {
            guard let item = slots[tab] ?? nil, !item.isEmpty else { continue }
            var cx = item.midX + reach
            var cy = item.midY - 13
            if scale < 0.9995, let platter {
                if isVertical {
                    cy = platter.midY + (cy - platter.midY) * scale
                } else {
                    cx = platter.midX + (cx - platter.midX) * scale
                }
            }
            let nextFrame = CGRect(x: cx - side / 2, y: cy - side / 2, width: side, height: side)
            if dot.frame != nextFrame { dot.frame = nextFrame }
            if abs(dot.alpha - overflowMenu.tabsShown) > 0.001 { dot.alpha = overflowMenu.tabsShown }
        }
    }

    private func updateDotsForMorph(_ shown: CGFloat) {
        if shown > 0.001 {
            placeDots()
        } else {
            for dot in dots.values where abs(dot.alpha - shown) > 0.001 {
                dot.alpha = shown
            }
        }
    }

    // MARK: Native Platter Introspection & Handoff

    /// Finds the native primary 4-tab platter view inside `systemBar.tabBar` (contains `Home` and `More`, excludes the
    /// detached `router` circle). Returns `nil` on Duo vertical rail where the bar lives outside `tabBar`, in which
    /// case `primaryPlatterFrame(in:)` computes the exact platter rect from the 4 native `UITab.frame(in:)` rects.
    private func primaryPlatterView() -> UIView? {
        guard let homeRect = items[.home]?.frame(in: view), !homeRect.isEmpty,
              let moreRect = moreTab.frame(in: view), !moreRect.isEmpty else { return nil }
        let homeCenter = CGPoint(x: homeRect.midX, y: homeRect.midY)
        let moreCenter = CGPoint(x: moreRect.midX, y: moreRect.midY)
        let routerCenter = router.frame(in: view).map { CGPoint(x: $0.midX, y: $0.midY) }
        let maxWidth = view.bounds.width * 0.95
        var best: (view: UIView, area: CGFloat)?
        for sub in systemBar.tabBar.subviews {
            let rect = sub.convert(sub.bounds, to: view)
            guard rect.width > 1, rect.height > 1, rect.width < maxWidth,
                  rect.contains(homeCenter), rect.contains(moreCenter) else { continue }
            if let routerCenter, rect.contains(routerCenter) { continue }
            let area = rect.width * rect.height
            if best == nil || area < best!.area {
                best = (sub, area)
            }
        }
        return best?.view
    }

    /// Live frame of the native primary 4-tab platter in `target` coordinates.
    func primaryPlatterFrame(in target: UIView) -> CGRect? {
        if let platter = primaryPlatterView() {
            let rect = platter.convert(platter.bounds, to: target)
            if rect.width > 1, rect.height > 1 { return rect }
        }
        let rects = liveSlotFrames(in: target)
        guard rects.count == Self.primaryTabs.count + 1 else { return nil }
        let union = rects.reduce(CGRect.null) { $0.union($1) }
        let isVertical = union.height > union.width * 1.5
        return union.insetBy(dx: isVertical ? -2 : -4, dy: isVertical ? -1.5 : -4)
    }

    private func liveSlotFrames(in target: UIView) -> [CGRect] {
        var rects: [CGRect] = []
        for tab in Self.primaryTabs {
            guard let frame = items[tab]?.frame(in: target), !frame.isEmpty else { return [] }
            rects.append(frame)
        }
        guard let moreFrame = moreTab.frame(in: target), !moreFrame.isEmpty else { return [] }
        rects.append(moreFrame)
        return rects
    }

    private func cacheRestingGeometryIfIdle() {
        guard !startedOnRegularTab, !overflowMenu.isActive, zoomPage == nil else { return }
        guard let platter = primaryPlatterFrame(in: view), !platter.isEmpty else { return }
        let slots = liveSlotFrames(in: view)
        guard slots.count == Self.primaryTabs.count + 1 else { return }
        restingPlatterFrame = platter
        restingSlotFrames = slots
        if let circle = router.frame(in: view), !circle.isEmpty {
            restingRouterFrame = circle
        }
        if let metrics = liveRestingPillMetrics(platterFrame: platter) {
            restingPillSize = metrics.size
            if let edgeInset = metrics.edgeInset {
                restingPillEdgeInset = edgeInset
            }
        }
    }

    /// Recursively reads the native resting selection pill dimensions and outer-slot edge inset inside
    /// `primaryPlatterView()` (or inside `systemBar.view` on Duo vertical rail) using pure geometry (zero private APIs
    /// or class-name strings), so `TabOverflowMenuView` lands at 0.0 pt against Apple's native pill across all 5 postures.
    private func liveRestingPillMetrics(platterFrame: CGRect) -> (size: CGSize, edgeInset: CGFloat?)? {
        if platterFrame.height > platterFrame.width * 1.5 {
            // Duo vertical rail: search `systemBar.view` (excluding `standIn`) for the resting vertical pill (~44×58pt).
            let targetW = max(1, platterFrame.width - 4)
            let standInView = standIn
            var bestRect: CGRect?
            func searchVertical(in current: UIView) {
                if let standInView, current === standInView || current.isDescendant(of: standInView) { return }
                guard !current.isHidden, current.alpha > 0.01 else { return }
                let rect = current.convert(current.bounds, to: view)
                if platterFrame.insetBy(dx: -3, dy: -3).contains(rect),
                   abs(rect.width - targetW) <= 2.5,
                   rect.height >= 50, rect.height <= 72 {
                    if let cur = bestRect {
                        if abs(rect.height - 58) < abs(cur.height - 58) { bestRect = rect }
                    } else {
                        bestRect = rect
                    }
                }
                for sub in current.subviews { searchVertical(in: sub) }
            }
            if systemBar.isViewLoaded { searchVertical(in: systemBar.view) }
            if let rect = bestRect {
                let inset = min(rect.minY - platterFrame.minY, platterFrame.maxY - rect.maxY)
                return (rect.size, (0.5...8.0).contains(inset) ? inset : nil)
            }
            return (CGSize(width: targetW, height: 58), nil)
        }
        guard let platter = primaryPlatterView() else {
            return (CGSize(width: min(94, max(66, platterFrame.width / 4 + 4)), height: max(1, platterFrame.height - 8)), nil)
        }
        let platterMajor = max(platter.bounds.width, platter.bounds.height)
        let targetH = max(1, platter.bounds.height - 8)
        var bestRect: CGRect?
        func searchHorizontal(in current: UIView) {
            for sub in current.subviews {
                guard !sub.isHidden, sub.alpha > 0.01 else { continue }
                let rect = sub.convert(sub.bounds, to: platter)
                if abs(rect.height - targetH) <= 2.5,
                   rect.width >= 55, rect.width < platterMajor - 20 {
                    // Prefer the selection pill (`~66..98pt` wide, matching a single tab slot).
                    if bestRect == nil || rect.width > bestRect!.width && rect.width <= 110 {
                        bestRect = rect
                    }
                }
                searchHorizontal(in: sub)
            }
        }
        searchHorizontal(in: platter)
        if let rect = bestRect {
            let inset = min(rect.minX, platter.bounds.width - rect.maxX)
            return (rect.size, (0.5...8.0).contains(inset) ? inset : nil)
        }
        return (CGSize(width: min(94, max(66, platterFrame.width / 4 + 4)), height: targetH), nil)
    }

    private func currentOrientation(platterFrame: CGRect? = nil) -> TabOverflowMenuView.Orientation {
        #if canImport(SwiftUI, _version: 8.0.85)
        if #available(iOS 27.1, *) {
            let rtl = viewIfLoaded?.effectiveUserInterfaceLayoutDirection == .rightToLeft
            switch traitCollection.verticalBarEdge {
            case .leading: return .vertical(trailing: rtl)
            case .trailing: return .vertical(trailing: !rtl)
            default: break
            }
        }
        #endif
        if let frame = platterFrame ?? restingPlatterFrame ?? (isViewLoaded ? primaryPlatterFrame(in: view) : nil),
           frame.height > frame.width * 1.5, let bounds = viewIfLoaded?.bounds {
            return .vertical(trailing: frame.midX > bounds.midX)
        }
        return .horizontal
    }

    /// Reads the live lifted selection rect inside the primary platter using pure view geometry (zero private APIs or
    /// class-name strings), picking the lifted candidate closest to `More` and falling back to lifted-lens sizing on
    /// Duo vertical rail where the bar lives outside `systemBar.tabBar`.
    private func nativeLensFrame(in target: UIView) -> (frame: CGRect, lift: CGFloat)? {
        guard let moreRect = moreTab.frame(in: target), !moreRect.isEmpty else { return nil }
        guard let platter = primaryPlatterView() else {
            return (moreRect.insetBy(dx: -14, dy: -14), 0.9)
        }
        let platterMajor = max(platter.bounds.width, platter.bounds.height)
        let moreCenter = CGPoint(x: moreRect.midX, y: moreRect.midY)
        let root = target.layer.presentation() ?? target.layer
        let slot = items[.home]?.frame(in: target) ?? moreRect
        let restMinor = min(slot.width, slot.height)
        var best: (rect: CGRect, lift: CGFloat, dist: CGFloat)?
        for sub in platter.subviews {
            guard !sub.isHidden, sub.alpha > 0.01, !sub.subviews.isEmpty else { continue }
            let major = max(sub.bounds.width, sub.bounds.height)
            guard major > 20, major < platterMajor - 20 else { continue }
            let layer = sub.layer.presentation() ?? sub.layer
            let rect = root.convert(layer.bounds, from: layer)
            guard rect.width > 1, rect.height > 1, rect.minX.isFinite, rect.minY.isFinite else { continue }
            let lensMinor = min(rect.width, rect.height)
            let lift = restMinor > 0 ? min(max((lensMinor - restMinor - 0.5) / 14, 0), 1) : 0
            let dist = hypot(rect.midX - moreCenter.x, rect.midY - moreCenter.y)
            if let current = best {
                if lift > current.lift + 0.05 || (abs(lift - current.lift) <= 0.05 && dist < current.dist) {
                    best = (rect, lift, dist)
                }
            } else {
                best = (rect, lift, dist)
            }
        }
        if let best, best.lift > 0.05 {
            return (best.rect, best.lift)
        }
        return (moreRect.insetBy(dx: -8, dy: -8), 0.9)
    }

    private func buildAnchor(handoffLens: (frame: CGRect, lift: CGFloat)?, livePlatter: CGRect?) -> TabOverflowMenuView.Anchor? {
        guard var platter = restingPlatterFrame ?? livePlatter ?? primaryPlatterFrame(in: view) else { return nil }
        let slots: [CGRect]
        if let cached = restingSlotFrames, cached.count == Self.primaryTabs.count + 1 {
            slots = cached
        } else {
            let live = liveSlotFrames(in: view)
            guard live.count == Self.primaryTabs.count + 1 else { return nil }
            slots = live
        }
        let orientation = currentOrientation(platterFrame: platter)
        if orientation == .horizontal, view.frame.minX > 0 {
            let minLeft: CGFloat = 8
            let left = min(max(platter.minX, minLeft), max(minLeft, platter.maxX - 180))
            let right = max(min(platter.maxX, view.bounds.width - 8), left + 180)
            platter = CGRect(x: left, y: platter.minY, width: right - left, height: platter.height)
        }
        let initialThickness: CGFloat?
        if orientation != .horizontal, let live = livePlatter, live.width > platter.width + 2 {
            initialThickness = live.width
        } else {
            initialThickness = nil
        }
        let selectedSlot: Int
        if systemBar.selectedTab === moreTab {
            selectedSlot = Self.primaryTabs.count
        } else if let idx = Self.primaryTabs.firstIndex(where: { items[$0] === systemBar.selectedTab }) {
            selectedSlot = idx
        } else {
            selectedSlot = 0
        }
        let liveMetrics = restingPillSize == nil || restingPillEdgeInset == nil ? liveRestingPillMetrics(platterFrame: platter) : nil
        return TabOverflowMenuView.Anchor(
            platterFrame: platter,
            slotFrames: slots,
            orientation: orientation,
            selectedSlot: selectedSlot,
            overflowSelected: systemBar.selectedTab === moreTab,
            handoffLens: handoffLens,
            initialThickness: initialThickness,
            restingPillSize: restingPillSize ?? liveMetrics?.size,
            restingPillEdgeInset: restingPillEdgeInset ?? liveMetrics?.edgeInset
        )
    }

    private func openOverflowMenu(tracking: Bool, at point: CGPoint?, handoffLens: (frame: CGRect, lift: CGFloat)?,
                                  livePlatter: CGRect? = nil) {
        guard zoomPage == nil, !overflowMenu.isOpen,
              let anchor = buildAnchor(handoffLens: handoffLens, livePlatter: livePlatter) else { return }
        syncOverflowMenuModel()
        ensureOverlayZOrder()
        overflowMenu.open(anchor: anchor, tracking: tracking, at: point)
    }

    private func handleOverflowPick(_ id: String) {
        guard let tab = Self.overflowTabs.first(where: { $0.identifier == id }) else { return }
        overflowSelection = tab
        bar.selection = tab
        refreshMoreTabArt(force: false)
        if systemBar.selectedTab !== moreTab { systemBar.selectedTab = moreTab }
        syncOverflowMenuModel()
        navigation.select(tab)
    }

    // MARK: Gestures (Zero Overhead on Regular Tabs; Seamless Tap & Drag Handoff on `More`)

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Keep `takeOver` in `.possible` even while UIKit's tab-bar drag recognizer is active on regular tabs, so
        // `takeOver.take()` can still cancel direct view touches after a 0.3 s dwell on `More`.
        if g === takeOver || other === takeOver {
            if takeOver.state == .possible { return true }
            return g === press || other === press
        }
        return true
    }

    /// Cancels every active touch and gesture recognizer inside `systemBar.view` (including both horizontal `tabBar`
    /// and Duo's vertical rail containers) so UIKit immediately drops its lifted lens and releases any pressed glass.
    private func cancelTabBarTracking() {
        takeOver.take()
        func cancel(in root: UIView) {
            if let recognizers = root.gestureRecognizers {
                for g in recognizers where g.isEnabled {
                    if g.state == .began || g.state == .changed || g.state == .possible {
                        g.isEnabled = false
                        g.isEnabled = true
                    }
                }
            }
            for sub in root.subviews { cancel(in: sub) }
        }
        if systemBar.isViewLoaded {
            cancel(in: systemBar.view)
        }
    }

    private func isOnMoreZone(_ point: CGPoint) -> Bool {
        guard let moreRect = moreTab.frame(in: view), !moreRect.isEmpty,
              let platter = restingPlatterFrame ?? primaryPlatterFrame(in: view) else { return false }
        let orientation = currentOrientation(platterFrame: platter)
        switch orientation {
        case .horizontal:
            guard point.y >= platter.minY - 20 else { return false }
            let rtl = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
            return rtl ? point.x <= moreRect.maxX : point.x >= moreRect.minX
        case .vertical(let trailing):
            let withinPerp = trailing ? point.x >= platter.minX - 40 : point.x <= platter.maxX + 40
            guard withinPerp else { return false }
            return point.y >= moreRect.minY
        }
    }

    private func armMenuDwell(at point: CGPoint) {
        if menuDwell != nil, hypot(point.x - dwellAnchor.x, point.y - dwellAnchor.y) <= TabOverflowMenuView.Metrics.dwellSlop {
            dwellPoint = point
            return
        }
        cancelMenuDwell()
        dwellAnchor = point
        dwellPoint = point
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.startedOnRegularTab, !self.overflowMenu.isOpen else { return }
            self.menuDwell = nil
            let liveLens = self.nativeLensFrame(in: self.view)
            let livePlatter = self.primaryPlatterFrame(in: self.view)
            self.cancelTabBarTracking()
            self.openOverflowMenu(tracking: true, at: self.dwellPoint, handoffLens: liveLens, livePlatter: livePlatter)
        }
        menuDwell = work
        DispatchQueue.main.asyncAfter(deadline: .now() + TabOverflowMenuView.Metrics.menuDwell, execute: work)
    }

    private func cancelMenuDwell() {
        menuDwell?.cancel()
        menuDwell = nil
    }

    private func handleTouchDown(at point: CGPoint) {
        openedOnTouchDown = false
        guard !overflowMenu.isActive, zoomPage == nil else { return }
        guard let moreRect = moreTab.frame(in: view), !moreRect.isEmpty, moreRect.contains(point) else { return }
        startedOnRegularTab = false
        openedOnTouchDown = true
        cancelTabBarTracking()
        openOverflowMenu(tracking: true, at: point, handoffLens: nil)
    }

    @objc private func handleBarPress(_ gesture: UILongPressGestureRecognizer) {
        let point = gesture.location(in: view)
        switch gesture.state {
        case .began:
            if openedOnTouchDown {
                openedOnTouchDown = false
                return
            }
            if overflowMenu.isOpen {
                overflowMenu.beginTracking(at: point)
                return
            }
            guard !overflowMenu.isActive else { return }
            if let moreRect = moreTab.frame(in: view), moreRect.contains(point) {
                startedOnRegularTab = false
                cancelTabBarTracking()
                openOverflowMenu(tracking: true, at: point, handoffLens: nil)
                return
            }
            if let platter = restingPlatterFrame ?? primaryPlatterFrame(in: view),
               platter.insetBy(dx: -20, dy: -20).contains(point) {
                startedOnRegularTab = true
            } else {
                startedOnRegularTab = false
            }
        case .changed:
            if overflowMenu.isOpen {
                overflowMenu.updateTracking(at: point)
                return
            }
            guard startedOnRegularTab else { return }
            if isOnMoreZone(point) {
                armMenuDwell(at: point)
            } else {
                cancelMenuDwell()
            }
        case .ended:
            openedOnTouchDown = false
            cancelMenuDwell()
            if overflowMenu.isOpen {
                overflowMenu.endTracking(at: point)
                startedOnRegularTab = false
                return
            }
            if startedOnRegularTab, isOnMoreZone(point) {
                let liveLens = nativeLensFrame(in: view)
                let livePlatter = primaryPlatterFrame(in: view)
                cancelTabBarTracking()
                openOverflowMenu(tracking: false, at: nil, handoffLens: liveLens, livePlatter: livePlatter)
            }
            startedOnRegularTab = false
        default:
            openedOnTouchDown = false
            cancelMenuDwell()
            if overflowMenu.isOpen && overflowMenu.isTracking {
                overflowMenu.cancelTracking()
            }
            startedOnRegularTab = false
        }
    }

    // MARK: UITabBarControllerDelegate

    func tabBarController(_ controller: UITabBarController, shouldSelectTab tab: UITab) -> Bool {
        if tab === router {
            overflowMenu.dismissImmediately()
            navigation.openRouter()
            return false
        }
        if tab === moreTab {
            if !overflowMenu.isActive {
                openOverflowMenu(tracking: false, at: nil, handoffLens: nil)
            }
            return false
        }
        if tab === controller.selectedTab, let again = appTab(tab) {
            navigation.select(again)
            return false
        }
        return true
    }

    func tabBarController(_ controller: UITabBarController, didSelectTab selected: UITab, previousTab: UITab?) {
        if let tab = appTab(selected), tab != navigation.tab {
            navigation.select(tab)
        }
    }

    // MARK: Art & Model Sync

    private func appTab(_ item: UITab) -> AppTab? {
        Self.primaryTabs.first { items[$0] === item }
    }

    private func avatarImage(_ key: AvatarKey) -> UIImage? {
        if cachedAvatarKey == key, let cachedAvatarImage { return cachedAvatarImage }
        let avatar = UserAvatar(store: store, size: 28).environment(\.colorScheme, key.colorScheme)
        let renderer = ImageRenderer(content: avatar)
        renderer.scale = 3
        let image = renderer.uiImage?.withRenderingMode(.alwaysOriginal)
        cachedAvatarKey = key
        cachedAvatarImage = image
        return image
    }

    private func syncOverflowMenuModel() {
        func menuItem(_ tab: AppTab) -> TabOverflowMenuView.Item {
            if tab.showsAvatar, let avatar = bar.avatar.flatMap(avatarImage) {
                return TabOverflowMenuView.Item(id: tab.identifier, title: tab.title, image: avatar, selectedImage: avatar)
            }
            return TabOverflowMenuView.Item(id: tab.identifier, title: tab.title,
                                            image: ShellTabArt.glyph(tab, selected: false),
                                            selectedImage: ShellTabArt.glyph(tab, selected: true))
        }
        let primary = Self.primaryTabs.map(menuItem)
        let overflow = Self.overflowTabs.map(menuItem)
        if overflowMenu.primaryItems != primary { overflowMenu.primaryItems = primary }
        if overflowMenu.overflow != overflow { overflowMenu.overflow = overflow }
        overflowMenu.selectedID = bar.selection.identifier
        overflowMenu.overflowID = overflowSelection.identifier
    }

    private func refreshMoreTabArt(force: Bool) {
        let orientation = currentOrientation()
        let style = traitCollection.userInterfaceStyle
        let key = MoreArtKey(tab: overflowSelection, avatar: bar.avatar, style: style, orientation: orientation)
        guard force || lastMoreArtKey != key else { return }
        lastMoreArtKey = key
        moreTab.accessibilityIdentifier = "tab-more"
        moreTab.accessibilityLabel = String(localized: "More, \(overflowSelection.title)")
        let normal = overflowTabImage(for: overflowSelection, selected: false, orientation: orientation)
        let selected = overflowTabImage(for: overflowSelection, selected: true, orientation: orientation)
        if #available(iOS 26.1, *) {
            moreTab.image = normal
            moreTab.selectedImage = selected
        } else {
            moreTab.image = bar.selection == overflowSelection ? selected : normal
        }
        overflowMenu.moreTabArt = (normal: normal, selected: selected)
    }

    /// Renders the 4th slot's `glyph/avatar + chevron` image:
    /// - Horizontal (`iPhone` / `Duo unfolded`): `[glyph] + 3pt + chevron.up` side-by-side.
    /// - Vertical trailing (`Duo right rail`): `[glyph]` above `3pt + chevron.left` (pointing inward toward content).
    /// - Vertical leading (`Duo left rail`): `[glyph]` above `3pt + chevron.right` (pointing inward toward content).
    private func overflowTabImage(for tab: AppTab, selected: Bool, orientation: TabOverflowMenuView.Orientation) -> UIImage? {
        let source: UIImage?
        if tab.showsAvatar, let avatar = bar.avatar.flatMap(avatarImage) {
            source = avatar
        } else {
            source = ShellTabArt.glyph(tab, selected: selected)
        }
        guard let source else { return nil }
        let chevronName: String
        switch orientation {
        case .horizontal: chevronName = "chevron.up"
        case .vertical(let trailing): chevronName = trailing ? "chevron.left" : "chevron.right"
        }
        let chevronCfg = UIImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        let chevron = UIImage(systemName: chevronName, withConfiguration: chevronCfg)
        let isOriginal = source.renderingMode == .alwaysOriginal
        let glyphSize = isOriginal ? source.size : CGSize(width: 24, height: 24)
        let chevSize = chevron?.size ?? .zero
        let gap: CGFloat = chevron == nil ? 0 : 3
        let isVertical = orientation != .horizontal
        let canvasSize: CGSize = isVertical
            ? CGSize(width: ceil(max(glyphSize.width, 24, chevSize.width)),
                     height: ceil(glyphSize.height + gap + chevSize.height))
            : CGSize(width: ceil(glyphSize.width + gap + chevSize.width),
                     height: ceil(max(glyphSize.height, 24, chevSize.height)))
        let format = UIGraphicsImageRendererFormat(for: traitCollection)
        let rendered = UIGraphicsImageRenderer(size: canvasSize, format: format).image { _ in
            let glyphRect: CGRect
            let chevRect: CGRect
            if isVertical {
                glyphRect = CGRect(x: (canvasSize.width - glyphSize.width) / 2, y: 0,
                                   width: glyphSize.width, height: glyphSize.height)
                chevRect = CGRect(x: (canvasSize.width - chevSize.width) / 2, y: glyphRect.maxY + gap,
                                  width: chevSize.width, height: chevSize.height)
            } else {
                glyphRect = CGRect(x: 0, y: (canvasSize.height - glyphSize.height) / 2,
                                   width: glyphSize.width, height: glyphSize.height)
                chevRect = CGRect(x: glyphRect.maxX + gap, y: (canvasSize.height - chevSize.height) / 2,
                                  width: chevSize.width, height: chevSize.height)
            }
            if isOriginal {
                source.draw(in: glyphRect)
                if let chevron {
                    let color = (selected ? UIColor(CommaTheme.textPrimary) : Self.restingGlyph).resolvedColor(with: traitCollection)
                    chevron.withTintColor(color, renderingMode: .alwaysOriginal).draw(in: chevRect)
                }
            } else {
                let black = UIColor.black
                source.withTintColor(black, renderingMode: .alwaysOriginal).draw(in: glyphRect)
                chevron?.withTintColor(black, renderingMode: .alwaysOriginal).draw(in: chevRect)
            }
        }
        return rendered.withRenderingMode(isOriginal ? .alwaysOriginal : .alwaysTemplate)
    }

    private static let restingGlyph = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.99) : UIColor(white: 0, alpha: 0.94)
    }
}

/// UIKit updates the selected content safe area independently of the container's layout.
@available(iOS 26.0, *)
private final class ShellBarStandInController: UIViewController {
    private let onLayoutChanged: (UIViewController) -> Void

    init(onLayoutChanged: @escaping (UIViewController) -> Void) {
        self.onLayoutChanged = onLayoutChanged
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        view.setNeedsLayout()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        onLayoutChanged(self)
    }
}

/// The bar's images that do not depend on the member.
enum ShellTabArt {
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

    /// Keeps the circle's layout while the overlay's animation stands in for the mark.
    @MainActor static let blankMark = UIGraphicsImageRenderer(
        size: CGSize(width: RouterCircleOverlay.markSide, height: RouterCircleOverlay.markSide)
    ).image { _ in }.withRenderingMode(.alwaysTemplate)
}
