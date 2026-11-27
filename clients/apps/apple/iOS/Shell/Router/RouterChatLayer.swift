import SwiftUI
import UIKit

/// The router chat as a layer over the tabs and their chrome, under the Task dock. It zooms out of the router button
/// and back into it with the system zoom transition, which also lets a finger close it; so do the close button and the
/// VoiceOver escape gesture.
struct RouterChatLayer: UIViewControllerRepresentable {
    let store: CommaStore
    let open: Bool
    var sharesRoutineColumn = false
    @Environment(AppNavigation.self) private var navigation
    @Environment(CallController.self) private var call: CallController?

    func makeUIViewController(context: Context) -> RouterLayerController {
        RouterLayerController(content: content(context), open: open)
    }

    func updateUIViewController(_ presenter: RouterLayerController, context: Context) {
        presenter.update(content: content(context), open: open)
    }

    static func dismantleUIViewController(_ presenter: RouterLayerController, coordinator: ()) {
        presenter.cancelOpeningFrame()
        presenter.restoreRouterButton()
    }

    private func content(_ context: Context) -> HostedContent<RouterLayerContent> {
        HostedContent(content: RouterLayerContent(store: store, navigation: navigation, call: call,
                                                 sharesRoutineColumn: sharesRoutineColumn), environment: context.environment)
    }
}

/// UIKit owns the layer. Closed, the chat waits on `parking`; opening pushes `page`, which takes the chat and zooms out
/// of the router button. Closed, and from the moment it starts closing, every touch passes through to the tabs.
final class RouterLayerController: UIViewController, UINavigationControllerDelegate {
    let hosting: UIHostingController<HostedContent<RouterLayerContent>>
    private let stack = UINavigationController()
    private let parking = UIViewController()
    private let page = UIViewController()
    private let touchOrigin = RouterTouchOrigin()
    private var navigation: AppNavigation { hosting.rootView.content.navigation }
    private var programmaticPop = false
    /// A finger let the chat go past the point of closing, and the navigation already has it closed.
    private var closedByFinger = false
    private var statedCorners: [CGFloat] = []
    private var startsOpen: Bool
    private var requestedOpen: Bool
    /// The zoom out waits for this frame, until the button's face has been on screen in its source page.
    private var openingFrame: CADisplayLink?
    /// Advances with each push of the chat, so a timer left from an earlier opening does not settle a later one.
    private var openingGeneration = 0
    /// Advances on every badge hide/reveal schedule so a cancelled or re-opened zoom never reveals a stale badge.
    private var badgeRevealGeneration = 0

    init(content: HostedContent<RouterLayerContent>, open: Bool) {
        hosting = UIHostingController(rootView: content)
        // The chat page inside the navigation stack avoids the keyboard itself.
        hosting.safeAreaRegions = .container
        startsOpen = open && !content.content.navigation.animatesRouterOpening
        requestedOpen = open
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let container = RouterContainerView()
        container.controller = self
        view = container
    }

    /// Whether the chat takes touches: once it is on its way open, and until it starts closing.
    fileprivate var takesTouches: Bool { stack.topViewController === page }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        stack.setNavigationBarHidden(true, animated: false)
        stack.view.backgroundColor = .clear
        parking.view.backgroundColor = .clear
        page.view.backgroundColor = UIColor(CommaTheme.bgPrimary)
        page.view.addGestureRecognizer(touchOrigin)
        hosting.view.backgroundColor = .clear
        addChild(stack)
        stack.view.frame = view.bounds
        stack.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(stack.view)
        stack.didMove(toParent: self)
        stack.setViewControllers([parking], animated: false)
        stack.delegate = self
        moveContent(to: parking)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        synchronize()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if #available(iOS 26.0, *) { stateCorners() }
    }

    /// The zoom rounds the chat page to the page's own corners, which are concentric with this layer. The app card
    /// around the layer is square while no Task docks, so a held chat had only the page's minimum corners. Stated here
    /// without clipping, the layer's corners are the display's, as the system zoom rounds a page; above a docked Task the
    /// card's own foot is rounder than square, and its corners are kept there.
    @available(iOS 26.0, *)
    private func stateCorners() {
        guard view.window != nil else { return }
        func corner(_ corner: UIRectCorner) -> CGFloat {
            var ancestor = view.superview
            while let current = ancestor {
                let radius = current.effectiveRadius(corner: corner)
                if radius > 0 { return radius }
                ancestor = current.superview
            }
            return 0
        }
        let corners = [corner(.topLeft), corner(.topRight), corner(.bottomLeft), corner(.bottomRight)]
        guard corners != statedCorners else { return }
        statedCorners = corners
        view.cornerConfiguration = .corners(topLeftRadius: .fixed(corners[0]), topRightRadius: .fixed(corners[1]),
                                            bottomLeftRadius: .fixed(corners[2]), bottomRightRadius: .fixed(corners[3]))
    }

    func update(content: HostedContent<RouterLayerContent>, open: Bool) {
        hosting.rootView = content
        view.accessibilityViewIsModal = open && !content.content.sharesRoutineColumn
        guard open != requestedOpen else { return }
        requestedOpen = open
        if open { hideRouterBadge(animated: true) }
        // Closing ends editing after SwiftUI has finished updating the tab bar's keyboard inset.
        DispatchQueue.main.async { [weak self] in self?.synchronize() }
    }

    /// Brings the stack to where the navigation has the chat. A change asked for while the stack moves waits for it
    /// to land: the stack drops a push or pop started during another one.
    private func synchronize() {
        guard viewIfLoaded?.window != nil else { return }
        // A docking Task can round the card's foot without resizing this layer.
        if #available(iOS 26.0, *) { stateCorners() }
        if let moving = stack.transitionCoordinator {
            moving.animate(alongsideTransition: nil) { [weak self] _ in
                DispatchQueue.main.async { self?.synchronize() }
            }
            return
        }
        if navigation.routerOpen, stack.topViewController === parking {
            guard openingFrame == nil else { return }
            moveContent(to: page)
            // A launch directly into chat skips the zoom. Its return page still needs the whole button
            // in place before UIKit takes the first frame of a dismissal.
            _ = navigation.routerTabBar?.zoomSource(in: parking.view, viewport: view)
            hideRouterBadge(animated: !startsOpen)
            configureTransition()
            if startsOpen {
                startsOpen = false
                openingGeneration += 1
                stack.pushViewController(page, animated: false)
                return
            }
            // The zoom hides its source as it starts and draws the source itself only once that has been on screen.
            // The face took the button's place just now, so the push waits a frame: the button would otherwise be
            // missing for the zoom's first frame, and for several on the first zoom after launch.
            let frame = CADisplayLink(target: self, selector: #selector(openAfterFrame))
            frame.add(to: .main, forMode: .common)
            openingFrame = frame
        } else if !navigation.routerOpen, stack.topViewController === page {
            roundPage(true)
            programmaticPop = true
            putKeyboardAway()
            stack.popViewController(animated: true)
        }
    }

    /// The face has been on screen: the chat zooms out of it, or, closed again meanwhile, stays parked. The push
    /// leaves the frame's callback first: a zoom started inside it jumped straight to its end.
    @objc private func openAfterFrame() {
        openingFrame?.invalidate()
        DispatchQueue.main.async { [weak self] in self?.openFromFace() }
    }

    fileprivate func cancelOpeningFrame() {
        openingFrame?.invalidate()
        openingFrame = nil
    }

    private func openFromFace() {
        guard openingFrame != nil else { return }
        openingFrame = nil
        guard stack.topViewController === parking else { return }
        if navigation.routerOpen, viewIfLoaded?.window != nil {
            roundPage(true)
            openingGeneration += 1
            stack.pushViewController(page, animated: true)
        } else {
            moveContent(to: parking)
            restoreRouterButton()
        }
    }

    /// Ends editing before the page leaves the stack. The stack keeps a leaving page's keyboard and brings it back
    /// when the same page is pushed again, so ending it once the pop has begun reopened the chat with its keyboard up.
    private func putKeyboardAway() {
        hosting.view.endEditing(true)
    }

    /// The zoom under Reduce Motion too: UIKit then fades the page in and out instead of scaling it, and a finger can
    /// still close it, which a cross-dissolve does not allow.
    private func configureTransition() {
        let zoom = UIViewController.Transition.ZoomOptions()
        // The button opens the entire conversation. UIKit scales the page, including its toolbar and transcript.
        zoom.interactiveDismissShouldBegin = { [weak self] interaction in
            guard let self, canDismiss(at: touchOrigin.activeLocation ?? interaction.location,
                                       velocity: interaction.velocity) else { return false }
            putKeyboardAway()
            roundPage(true)
            if #available(iOS 26.0, *) { stateCorners() }
            return true
        }
        page.preferredTransition = .zoom(options: zoom) { [weak self] context in
            guard let self else { return nil }
            return navigation.routerTabBar?.zoomSource(in: context.sourceViewController.view, viewport: view)
        }
    }

    /// The page has the app card's corners only while it zooms. Landed open it fills the layer, which the card
    /// clips to its own corners when a Task docks under it: a page kept rounded showed the tabs at its corners on a
    /// display with smaller corners than the card's (iPhone SE, iPad, Duo's fold).
    private func roundPage(_ rounded: Bool) {
        if rounded { return page.view.clipToAppCardCorners() }
        page.view.clipsToBounds = false
        if #available(iOS 26.0, *) {
            page.view.cornerConfiguration = .corners(radius: .fixed(0))
        } else {
            page.view.layer.cornerRadius = 0
        }
    }

    fileprivate func restoreRouterButton() {
        if let sourcePage = parking.viewIfLoaded {
            navigation.routerTabBar?.restoreRouterFace(from: sourcePage, revealBadge: !navigation.routerOpen)
        }
    }

    private func hideRouterBadge(animated: Bool = true) {
        badgeRevealGeneration += 1
        navigation.routerTabBar?.setRouterBadgeHidden(true, animated: animated)
    }

    private func scheduleRouterBadgeReveal(after delay: TimeInterval) {
        badgeRevealGeneration += 1
        let generation = badgeRevealGeneration
        let reveal = { [weak self] in
            guard let self, generation == badgeRevealGeneration, !navigation.routerOpen else { return }
            navigation.routerTabBar?.setRouterBadgeHidden(false)
        }
        if delay <= 0 {
            reveal()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: reveal)
        }
    }

    private func moveContent(to container: UIViewController) {
        guard hosting.parent !== container else { return }
        if hosting.parent != nil {
            hosting.willMove(toParent: nil)
            hosting.view.removeFromSuperview()
            hosting.removeFromParent()
        }
        container.addChild(hosting)
        hosting.view.isHidden = container === parking
        hosting.view.alpha = 1
        hosting.view.frame = container.view.bounds
        hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.view.addSubview(hosting.view)
        hosting.didMove(toParent: container)
    }

    func navigationController(_ navigationController: UINavigationController, willShow controller: UIViewController,
                              animated: Bool) {
        // The stack reports its first page as it first appears, which can come after the chat opened over it.
        guard controller === navigationController.topViewController else { return }
        let opening = controller === page
        let coordinator = animated ? navigationController.transitionCoordinator : nil
        // Let go past the point of closing, the chat is closed from then on, not once the zoom's spring settles about
        // a second later: until then the button would find the chat still open and not open it again.
        if !opening, let coordinator {
            if coordinator.isInteractive {
                coordinator.notifyWhenInteractionChanges { [weak self] context in
                    guard let self, !context.isCancelled else { return }
                    closedByFinger = true
                    navigation.closeRouter()
                    let remaining = max(0, 1 - context.percentComplete)
                    let delay = UIAccessibility.isReduceMotionEnabled ? 0
                        : min(0.26, max(0.18, coordinator.transitionDuration * remaining * 0.65))
                    scheduleRouterBadgeReveal(after: delay)
                }
                coordinator.animate(alongsideTransition: nil) { [weak self] context in
                    guard let self, context.isCancelled, stack.topViewController === page else { return }
                    roundPage(false)
                }
            } else {
                let delay = UIAccessibility.isReduceMotionEnabled ? 0
                    : min(0.32, max(0.24, coordinator.transitionDuration * 0.82))
                scheduleRouterBadgeReveal(after: delay)
            }
        }
        // The zoom's spring has the chat in place by its nominal duration but reports landing only once it has settled,
        // about three times as long; a composer waiting to take focus need not wait for that.
        if opening, let coordinator, !coordinator.isInteractive {
            let generation = openingGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + coordinator.transitionDuration) { [weak self] in
                guard let self, generation == openingGeneration, stack.topViewController === page else { return }
                navigation.routerSettled()
            }
        }
    }

    func navigationController(_ navigationController: UINavigationController, didShow controller: UIViewController,
                              animated: Bool) {
        guard controller === navigationController.topViewController else { return }
        if controller === page {
            roundPage(false)
            navigation.routerSettled()
        } else {
            // Keep the source mounted in the return page through a cancelled drag and the entire pop.
            restoreRouterButton()
            if hosting.parent === page {
                // Closed by a finger, the navigation may since have opened the chat again; it opens once this lands.
                if !programmaticPop, !closedByFinger { navigation.closeRouter() }
                moveContent(to: parking)
            }
        }
        programmaticPop = false
        closedByFinger = false
        DispatchQueue.main.async { [weak self] in self?.synchronize() }
    }

    private func towardTrailing(_ delta: CGFloat) -> CGFloat {
        view.effectiveUserInterfaceLayoutDirection == .rightToLeft ? -delta : delta
    }

    private func leadingDistance(to point: CGPoint) -> CGFloat {
        view.effectiveUserInterfaceLayoutDirection == .rightToLeft ? view.bounds.maxX - point.x : point.x
    }

    /// Whether the zoom's own drag from `point` at `velocity` may close the chat: downward only from its header, as
    /// below it a downward drag scrolls the transcript, and toward the trailing edge not on a message, which that drag
    /// answers instead, nor on anything that scrolls sideways.
    func canDismiss(at point: CGPoint, velocity: CGVector) -> Bool {
        if velocity.dy > abs(velocity.dx) {
            #if canImport(SwiftUI, _version: 8.0.85)
            if #available(iOS 27.1, *), traitCollection.verticalBarEdge != .unspecified { return false }
            #endif
            return point.y <= view.safeAreaInsets.top + 52
        }
        let fromLeading = leadingDistance(to: point)
        guard fromLeading <= view.bounds.width / 3, towardTrailing(velocity.dx) > abs(velocity.dy) else { return false }
        if fromLeading <= ReplySwipeRegions.edge { return true }
        let pane = hosting.rootView.content.store.router.pane.map(ObjectIdentifier.init)
        if ReplySwipeRegions.shared.claims(view.convert(point, to: nil), in: pane) { return false }
        var hit = view.hitTest(point, with: nil)
        while let current = hit, current !== view {
            if let scroll = current as? UIScrollView, scroll.isScrollEnabled,
               scroll.contentSize.width > scroll.bounds.width + 1 { return false }
            hit = current.superview
        }
        return true
    }

    override func accessibilityPerformEscape() -> Bool {
        guard navigation.routerOpen else { return false }
        navigation.closeRouter()
        return true
    }
}

/// The zoom asks whether it may start after the finger has moved. Remember the initial touch so an edge
/// swipe keeps its priority over a reply on the adjacent bubble. UIKit owns the gesture itself.
private final class RouterTouchOrigin: UIGestureRecognizer {
    private weak var touch: UITouch?
    private var start = CGPoint.zero

    var activeLocation: CGPoint? {
        switch touch?.phase {
        case .began, .moved, .stationary: start
        default: nil
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if let first = touches.first {
            touch = first
            start = first.location(in: view)
        }
        state = .failed
    }
}

/// Passes touches through to the tabs while the chat does not take them.
private final class RouterContainerView: UIView {
    weak var controller: RouterLayerController?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        controller?.takesTouches == true ? super.hitTest(point, with: event) : nil
    }
}
