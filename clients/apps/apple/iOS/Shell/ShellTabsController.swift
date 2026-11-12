import SwiftUI
import UIKit

/// The tabs' pages under the system tab bar. Every page stays on screen, the selected one shown and the others
/// hidden, so a switch only hides one page and shows another. Hosted by the bar's own controller, a page left the
/// window on every switch and was drawn again from scratch on its return, a hitch each time. The bar's controller
/// lies over the pages with an empty stand-in for each tab (`ShellTabBarController`).
final class ShellTabsController<Page: View>: UIViewController {
    private let bar: ShellTabBarController
    private var pages: [AppTab: UIHostingController<HostedContent<Page>>] = [:]
    private let pagesView = UIView()
    private var selection: AppTab
    private var contentLeadingInset: CGFloat

    init(store: CommaStore, navigation: AppNavigation, bar state: ShellTabBar, contentLeadingInset: CGFloat = 0, page: (AppTab) -> HostedContent<Page>) {
        bar = ShellTabBarController(store: store, navigation: navigation, bar: state)
        selection = state.selection
        self.contentLeadingInset = contentLeadingInset
        super.init(nibName: nil, bundle: nil)
        bar.contentLayoutChanged = { [weak self] in self?.invalidatePageInsets() }
        for tab in AppTab.allCases {
            let host = UIHostingController(rootView: page(tab))
            host.view.backgroundColor = .clear
            pages[tab] = host
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        view = ShellTabsView(bar: bar, pages: pagesView)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.addSubview(pagesView)
        for tab in AppTab.allCases {
            guard let host = pages[tab] else { continue }
            addChild(host)
            pagesView.addSubview(host.view)
            host.didMove(toParent: self)
            host.view.isHidden = tab != selection
        }
        addChild(bar)
        view.addSubview(bar.view)
        bar.didMove(toParent: self)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if pagesView.frame != view.bounds { pagesView.frame = view.bounds }
        var barFrame = view.bounds
        // Duo owns one vertical system bar for the full viewport. On other devices the
        // bottom tab bar belongs to the trailing content column.
        if !usesVerticalBar {
            barFrame.origin.x += contentLeadingInset
            barFrame.size.width = max(0, barFrame.width - contentLeadingInset)
        }
        if bar.view.frame != barFrame { bar.view.frame = barFrame }
        bar.view.layoutIfNeeded()
        for host in pages.values where host.view.frame != pagesView.bounds { host.view.frame = pagesView.bounds }
        synchronizePageInsets()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        invalidatePageInsets()
    }

    private func invalidatePageInsets() {
        guard let room = pageInsets(), pages.contains(where: { $0.value.additionalSafeAreaInsets != pageInsets(for: $0.key, base: room) }) else { return }
        view.setNeedsLayout()
    }

    private func pageInsets() -> UIEdgeInsets? {
        guard isViewLoaded, view.window != nil, bar.isViewLoaded, let standIn = bar.standIn else { return nil }
        return Self.room(in: standIn.safeAreaInsets, beyond: view.safeAreaInsets)
    }

    private func pageInsets(for tab: AppTab, base: UIEdgeInsets) -> UIEdgeInsets {
        var room = base
        // Settings owns both columns from the start. Its persistent master slides between them;
        // changing the page's safe area during a push would resize and replace its contents.
        if tab != .settings || pages[tab]?.rootView.environment.settingsColumnsFolded == nil {
            room.left += contentLeadingInset
        }
        return room
    }

    private var usesVerticalBar: Bool {
        #if canImport(SwiftUI, _version: 8.0.85)
        if #available(iOS 27.1, *) { return traitCollection.verticalBarEdge != .unspecified }
        #endif
        return false
    }

    /// UIKit can settle the system bar after the container's first layout.
    /// Update the pages when either owner's safe area changes, without waiting for a tab switch.
    private func synchronizePageInsets() {
        guard let room = pageInsets() else { return }
        for (tab, host) in pages {
            let insets = pageInsets(for: tab, base: room)
            if host.additionalSafeAreaInsets != insets { host.additionalSafeAreaInsets = insets }
        }
    }

    /// Shows the selected tab's page and `state` in the bar; gives the pages the environment again when it changed.
    func update(bar state: ShellTabBar, environment: EnvironmentValues, contentLeadingInset: CGFloat = 0, page: (AppTab) -> HostedContent<Page>) {
        if pages[.home]?.rootView.environment != HostedEnvironment(environment) {
            for (tab, host) in pages { host.rootView = page(tab) }
            view.setNeedsLayout()
        }
        if state.selection != selection {
            selection = state.selection
            for (tab, host) in pages { host.view.isHidden = tab != selection }
        }
        bar.apply(state)
        if self.contentLeadingInset != contentLeadingInset {
            self.contentLeadingInset = contentLeadingInset
            view.setNeedsLayout()
            view.layoutIfNeeded()
        }
    }

    private static func room(in standIn: UIEdgeInsets, beyond own: UIEdgeInsets) -> UIEdgeInsets {
        UIEdgeInsets(top: max(0, standIn.top - own.top), left: max(0, standIn.left - own.left),
                     bottom: max(0, standIn.bottom - own.bottom), right: max(0, standIn.right - own.right))
    }
}

/// Gives a touch to the bar only where the bar answers it: everywhere else the bar's controller is its empty stand-in,
/// and the touch belongs to the page under it.
private final class ShellTabsView: UIView {
    private weak var bar: UITabBarController?
    private weak var pages: UIView?

    init(bar: UITabBarController, pages: UIView) {
        self.bar = bar
        self.pages = pages
        super.init(frame: .zero)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01, self.point(inside: point, with: event) else {
            return nil
        }
        guard let bar, let pages, bar.isViewLoaded else { return super.hitTest(point, with: event) }
        if let hit = bar.view.hitTest(convert(point, to: bar.view), with: event), drawsBar(hit, in: bar) { return hit }
        return pages.hitTest(convert(point, to: pages), with: event)
    }

    /// Whether `hit` is part of the bar: not the bar controller's own view, nor the stand-in, its subviews or the
    /// views that hold it.
    private func drawsBar(_ hit: UIView, in bar: UITabBarController) -> Bool {
        guard hit !== bar.view else { return false }
        guard let standIn = bar.selectedViewController?.view else { return true }
        return !standIn.isDescendant(of: hit) && !hit.isDescendant(of: standIn)
    }
}
