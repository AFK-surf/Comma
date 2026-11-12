import SwiftUI
import UIKit
import CommaCore

/// The UIKit panel behind `TaskDockHost`: layout, drag progress and the hosted SwiftUI content.
final class TaskDockViewController: UIViewController, UIGestureRecognizerDelegate {
    static let barHeight: CGFloat = 60
    private static let barRadius: CGFloat = 22
    private static let sheetRadius: CGFloat = 38
    /// Space between the status bar and the expanded sheet, like a large system sheet.
    private static let sheetTopGap: CGFloat = 10

    let store: CommaStore
    private var pane: ConversationPane
    private var revealRequest: Int
    private(set) var placement: TaskDockPlacement
    let panel = UIView()
    /// Dims the app behind the raised sheet, in step with the sheet's own progress.
    private let dimmer = UIView()
    let shadow = UIView()
    private let grabber = UIView()
    /// Covers the transcript while minimized, so only the bar reads through the safe-area strip.
    private let cover = UIView()
    private let hosting: UIHostingController<TaskDockContent>
    private let browser: UIHostingController<TaskDockBrowser>
    /// The header and its details card, above the cover so the title capsule's shadow is never cut off.
    private let chrome: UIHostingController<TaskDockChrome>
    private let rail: UIHostingController<TaskDockRail>
    private let chromeLayer = ChromeLayerView()
    /// The last Task's header while it fades out over a new Task's.
    private weak var outgoingHeader: UIView?
    /// 0 minimized, 1 expanded.
    private(set) var progress: CGFloat = 0
    var targetProgress: CGFloat = 1
    var dragStart: CGFloat = 0
    var animator: UIViewPropertyAnimator?
    /// How far the keyboard reaches over the panel; 0 while it is down.
    var keyboardOverlap: CGFloat = 0
    private var laidOutSize: CGSize = .zero
    private var laidOutSafeInsets: UIEdgeInsets = .zero
    private var displayCorners = DisplayCornerRadii()
    private var presented = false
    let state: TaskDockState
    private(set) weak var outsideTap: UITapGestureRecognizer?
    var onExpand: () -> Void
    var onSettled: () -> Void = {}
    var onDismissing: () -> Void = {}
    /// Told when the sheet comes to rest minimized (true) or starts to rise (false).
    var onCovered: (Bool) -> Void = { _ in }
    var settled = false
    var dismissing = false

    init(store: CommaStore, pane: ConversationPane, revealRequest: Int, placement: TaskDockPlacement = .bottom, onExpand: @escaping () -> Void) {
        self.store = store
        self.pane = pane
        self.revealRequest = revealRequest
        self.placement = placement
        self.onExpand = onExpand
        let state = TaskDockState()
        state.browserInline = placement.isLeading
        self.state = state
        hosting = UIHostingController(rootView: TaskDockContent(store: store, pane: pane, state: state))
        browser = UIHostingController(rootView: TaskDockBrowser(state: state))
        chrome = UIHostingController(rootView: TaskDockChrome(store: store, pane: pane, state: state, actions: TaskDockActions()))
        rail = UIHostingController(rootView: TaskDockRail(store: store, pane: pane, state: state, actions: TaskDockActions()))
        super.init(nibName: nil, bundle: nil)
        state.onCoveredChange = { [weak self] covered in self?.onCovered(covered) }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let passthrough = PassthroughView()
        passthrough.dock = self
        view = passthrough
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        dimmer.backgroundColor = .black
        dimmer.alpha = 0
        dimmer.isUserInteractionEnabled = false
        view.addSubview(dimmer)

        shadow.layer.shadowColor = UIColor.black.cgColor
        shadow.layer.shadowOpacity = 0
        shadow.layer.shadowRadius = 20
        shadow.layer.shadowOffset = CGSize(width: 0, height: -2)
        view.addSubview(shadow)

        panel.backgroundColor = UIColor(CommaTheme.bgPrimary)
        panel.clipsToBounds = true
        panel.layer.cornerCurve = .continuous
        if #available(iOS 26.0, *) {
            view.cornerConfiguration = .corners(radius: .containerConcentric())
        } else {
            panel.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        }
        view.addSubview(panel)

        addChild(hosting)
        hosting.safeAreaRegions = []
        hosting.view.backgroundColor = .clear
        panel.addSubview(hosting.view)
        hosting.didMove(toParent: self)

        addChild(browser)
        browser.safeAreaRegions = []
        browser.view.backgroundColor = UIColor(CommaTheme.cardPrimary)
        panel.addSubview(browser.view)
        browser.didMove(toParent: self)

        cover.backgroundColor = UIColor(CommaTheme.bgPrimary)
        cover.isUserInteractionEnabled = false
        panel.addSubview(cover)

        // Closed, the chrome only takes touches in the header band; the transcript below keeps its own.
        chromeLayer.accepts = { [weak self] point in
            guard let self else { return false }
            return self.state.detailsOpen || point.y <= Self.barHeight
        }
        panel.addSubview(chromeLayer)
        addChild(chrome)
        chrome.safeAreaRegions = []
        chrome.view.backgroundColor = .clear
        chromeLayer.addSubview(chrome.view)
        chrome.didMove(toParent: self)

        grabber.backgroundColor = UIColor(CommaTheme.textPlaceholder).withAlphaComponent(0.6)
        grabber.layer.cornerRadius = 2.5
        grabber.isUserInteractionEnabled = false
        panel.addSubview(grabber)

        addChild(rail)
        rail.safeAreaRegions = []
        rail.view.backgroundColor = .clear
        panel.addSubview(rail.view)
        rail.didMove(toParent: self)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        panel.addGestureRecognizer(pan)

        // The strip above the sheet is outside the details too; a tap there closes them.
        let outside = UITapGestureRecognizer(target: self, action: #selector(handleOutsideTap(_:)))
        outside.cancelsTouchesInView = false
        outside.delegate = self
        view.addGestureRecognizer(outside)
        outsideTap = outside

        state.onCapsuleTopChange = { [weak self] in self?.layoutGrabber() }
        state.onBrowserChange = { [weak self] in self?.resizeForBrowser() }
        // The card covers the grabber's spot; it returns once the details close.
        state.onDetailsChange = { [weak self] open in
            guard let self else { return }
            UIView.animate(withDuration: 0.2) { self.grabber.alpha = self.placement.isLeading || open ? 0 : min(1, max(0, self.progress)) }
        }

        installContent()
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChange(_:)),
                                               name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        view.setNeedsLayout()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let insets = safeInsets
        let corners = DisplayCornerRadii(in: view)
        updateInsets()
        guard view.bounds.width > 0,
              view.bounds.size != laidOutSize || insets != laidOutSafeInsets || corners != displayCorners else { return }
        laidOutSize = view.bounds.size
        laidOutSafeInsets = insets
        displayCorners = corners
        let height = sheetHeight
        dimmer.frame = view.bounds
        panel.transform = .identity
        shadow.transform = .identity
        let conversationWidth: CGFloat
        if case .leading(let columnWidth, _) = placement { conversationWidth = min(view.bounds.width, columnWidth) }
        else { conversationWidth = view.bounds.width }
        let browserStart = min(view.bounds.width, conversationWidth + placement.columnGap)
        let browserExpanded = placement.isLeading && state.browser != nil
        let browserWidth = browserExpanded ? max(0, view.bounds.width - browserStart) : 0
        let width = browserExpanded ? view.bounds.width : conversationWidth
        panel.frame = CGRect(x: 0, y: view.bounds.height - height, width: width, height: height)
        if #unavailable(iOS 26.0) {
            panel.layer.maskedCorners = placement.isLeading
                ? [.layerMaxXMinYCorner, .layerMaxXMaxYCorner] : [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        }
        shadow.frame = panel.frame
        shadow.layer.shadowPath = UIBezierPath(roundedRect: shadow.bounds,
            cornerRadius: placement.isLeading ? CommaTheme.cardRadius : Self.sheetRadius).cgPath
        hosting.view.frame = CGRect(x: 0, y: 0, width: conversationWidth, height: height)
        browser.view.frame = CGRect(x: browserStart, y: 0, width: browserWidth, height: height)
        browser.view.isHidden = browserWidth == 0
        chromeLayer.frame = CGRect(x: 0, y: state.topInset, width: conversationWidth,
                                   height: max(0, panel.bounds.height - state.topInset))
        chrome.view.frame = chromeLayer.bounds
        updateInsets()
        cover.frame = placement.isLeading ? panel.bounds
            : CGRect(x: 0, y: Self.barHeight, width: panel.bounds.width, height: panel.bounds.height - Self.barHeight)
        rail.view.frame = CGRect(x: panel.bounds.width - minimizedWidth, y: 0,
                                 width: minimizedWidth, height: panel.bounds.height)
        layoutGrabber()
        if !presented {
            // Enter from the current presentation edge, then settle expanded.
            presented = true
            apply(placement.isLeading ? -minimizedWidth / travel : -(Self.barHeight + safeBottom) / max(1, travel))
            DispatchQueue.main.async { self.animate(to: 1, velocity: 0) }
        } else {
            apply(progress)
        }
    }

    func update(pane next: ConversationPane, revealRequest request: Int, placement nextPlacement: TaskDockPlacement = .bottom) {
        if placement != nextPlacement {
            let resumeTarget = animator != nil && !dismissing ? targetProgress : nil
            stopAtPresentation()
            let changingAxis = placement.isLeading != nextPlacement.isLeading
            placement = nextPlacement
            if changingAxis {
                dismissing = false
                progress = min(1, max(0, progress))
                panel.alpha = 1
                shadow.alpha = 1
                state.covered = progress <= 0
                // A minimized Task shows no viewer to keep; its sheet must not rise over the app.
                if state.covered || resumeTarget == 0 { state.browser = nil }
            }
            laidOutSize = .zero
            view.setNeedsLayout()
            if let resumeTarget {
                DispatchQueue.main.async {
                    guard self.placement == nextPlacement, self.revealRequest == request, !self.dismissing else { return }
                    self.view.layoutIfNeeded()
                    self.animate(to: resumeTarget, velocity: 0)
                }
            }
        }
        if next !== pane {
            // A reused dock serves a new Task: it starts over, never in the old one's closing state.
            pane = next
            state.browser = nil
            state.detailsOpen = false
            dismissing = false
            settled = false
            crossfadeHeader(installContent)
        }
        if request != revealRequest {
            revealRequest = request
            animate(to: 1, velocity: 0)
        }
    }

    // MARK: Geometry

    private var safeInsets: UIEdgeInsets { view.window?.safeAreaInsets ?? view.safeAreaInsets }
    private var safeTop: CGFloat { safeInsets.top }
    var safeBottom: CGFloat { safeInsets.bottom }
    var usesVerticalBar: Bool {
        #if canImport(SwiftUI, _version: 8.0.85)
        if #available(iOS 27.1, *) { return traitCollection.verticalBarEdge != .unspecified }
        #endif
        return false
    }
    var safeSides: CGFloat {
        // Duo's status column is an overlay, not a sensor inset to mirror around the transcript.
        usesVerticalBar ? 0 : placement.isLeading ? safeInsets.left : max(safeInsets.left, safeInsets.right)
    }
    private var sheetHeight: CGFloat {
        placement.isLeading ? view.bounds.height : max(Self.barHeight, view.bounds.height - safeTop - Self.sheetTopGap)
    }
    private var minimizedHeight: CGFloat { Self.barHeight + safeBottom }
    /// Distance the panel travels between minimized and expanded.
    var minimizedWidth: CGFloat { Self.barHeight + safeInsets.left }
    var travel: CGFloat { max(1, placement.isLeading ? panel.bounds.width - minimizedWidth : sheetHeight - minimizedHeight) }

    /// Only transforms and layer properties change here: no layout, no SwiftUI update.
    func apply(_ value: CGFloat) {
        progress = value
        let clamped = min(1, max(0, value))
        let translation = travel * (1 - value)
        panel.transform = placement.isLeading
            ? CGAffineTransform(translationX: -translation, y: 0)
            : CGAffineTransform(translationX: 0, y: translation)
        shadow.transform = panel.transform
        if #available(iOS 26.0, *) {
            let expanded = placement.isLeading ? CommaTheme.cardRadius : Self.sheetRadius
            func radius(near corner: CGFloat) -> UICornerRadius {
                let minimized = min(placement.isLeading ? CommaTheme.cardRadius : Self.barRadius, corner)
                return .fixed(minimized + (expanded - minimized) * clamped)
            }
            panel.cornerConfiguration = placement.isLeading
                ? .corners(topLeftRadius: 0, topRightRadius: radius(near: displayCorners.topLeft),
                           bottomLeftRadius: 0, bottomRightRadius: radius(near: displayCorners.bottomLeft))
                : .corners(topLeftRadius: radius(near: displayCorners.bottomLeft),
                           topRightRadius: radius(near: displayCorners.bottomRight), bottomLeftRadius: 0, bottomRightRadius: 0)
        } else {
            panel.layer.cornerRadius = placement.isLeading ? CommaTheme.cardRadius
                : Self.barRadius + (Self.sheetRadius - Self.barRadius) * clamped
        }
        shadow.layer.shadowOpacity = Float(0.15 * clamped)
        dimmer.alpha = placement.isLeading ? 0 : 0.3 * clamped
        cover.alpha = 1 - min(1, clamped * 2)
        chromeLayer.alpha = placement.isLeading ? min(1, clamped * 2) : 1
        rail.view.alpha = placement.isLeading ? 1 - min(1, clamped * 2) : 0
        rail.view.isUserInteractionEnabled = placement.isLeading && clamped < 0.5
        grabber.alpha = placement.isLeading || state.detailsOpen ? 0 : clamped
    }

    /// Midway between the sheet's top edge and the title capsule.
    private func layoutGrabber() {
        let height: CGFloat = 5
        let y = max(2, (state.capsuleTop - height) / 2)
        grabber.frame = CGRect(x: (panel.bounds.width - 36) / 2, y: y, width: 36, height: height)
    }

    // MARK: Content

    func openBrowser() {
        state.detailsOpen = false
        if state.browser == nil {
            state.browser = PhoneBrowserModel(store: store, workspace: pane.workspace, conversation: pane.conversationID,
                participant: pane.boundWorker?.participantID ?? pane.state.participant?.participantID ?? "")
        }
        if progress < 1 { onExpand(); animate(to: 1, velocity: 0) }
    }

    private func resizeForBrowser() {
        guard isViewLoaded else { return }
        let resumeTarget = animator != nil && !dismissing ? targetProgress : nil
        stopAtPresentation()
        let transition = placement.isLeading && progress >= 1 && resumeTarget == nil && view.window != nil
        let visiblePanel = panel.layer.presentation()?.frame ?? panel.frame
        let visibleShadow = shadow.layer.presentation()?.frame ?? shadow.frame
        let visibleShadowPath = shadow.layer.presentation()?.shadowPath ?? shadow.layer.shadowPath
        laidOutSize = .zero
        view.setNeedsLayout()
        UIView.performWithoutAnimation {
            self.view.layoutIfNeeded()
            self.browser.view.layoutIfNeeded()
        }
        if transition && !UIAccessibility.isReduceMotionEnabled {
            let targetPanel = panel.frame
            let targetShadow = shadow.frame
            let targetShadowPath = shadow.layer.shadowPath
            // Lay out the browser once. Only its outer clipping surface changes during the reveal.
            UIView.performWithoutAnimation {
                self.panel.frame = visiblePanel
                self.shadow.frame = visibleShadow
                self.shadow.layer.shadowPath = visibleShadowPath
            }
            UIView.animate(CommaMotion.settle) {
                self.panel.frame = targetPanel
                self.shadow.frame = targetShadow
                self.shadow.layer.shadowPath = targetShadowPath
            }
        }
        if let resumeTarget { animate(to: resumeTarget, velocity: 0) }
    }

    /// The old Task's header fades out over the new one's as the sheet rises, rather than cutting to it; the
    /// transcript below is still under the bar's cover, which the rising sheet fades away.
    private func crossfadeHeader(_ change: () -> Void) {
        outgoingHeader?.removeFromSuperview()
        guard view.window != nil, let old = chrome.view.snapshotView(afterScreenUpdates: false) else { return change() }
        old.frame = chrome.view.frame
        chromeLayer.addSubview(old)
        outgoingHeader = old
        change()
        chrome.view.alpha = 0
        // The old title leaves before the new one arrives, so the two never read on top of each other.
        UIView.animate(withDuration: 0.12, delay: 0, options: [.curveEaseIn]) { old.alpha = 0 } completion: { _ in
            old.removeFromSuperview()
        }
        UIView.animate(withDuration: 0.22, delay: 0.08, options: [.curveEaseOut]) { self.chrome.view.alpha = 1 }
    }

    /// Hosts the Task's views. Only a new Task replaces them; drags, layout and the keyboard change state.
    private func installContent() {
        let actions = TaskDockActions(
            toggle: { [weak self] in self?.toggle() },
            titleTapped: { [weak self] in self?.headerTapped() },
            close: { [weak self] in self?.dismiss() },
            archive: { [weak self] task in self?.dismiss(archiving: task) },
            openBrowser: { [weak self] in self?.openBrowser() })
        hosting.rootView = TaskDockContent(store: store, pane: pane, state: state, actions: actions)
        chrome.rootView = TaskDockChrome(store: store, pane: pane, state: state, actions: actions)
        rail.rootView = TaskDockRail(store: store, pane: pane, state: state, actions: actions)
    }
}
