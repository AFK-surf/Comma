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
    let panel = UIView()
    /// Dims the app behind the raised sheet, in step with the sheet's own progress.
    private let dimmer = UIView()
    private let shadow = UIView()
    private let grabber = UIView()
    /// Covers the transcript while minimized, so only the bar reads through the safe-area strip.
    private let cover = UIView()
    private let hosting: UIHostingController<TaskDockContent>
    /// The header and its details card, above the cover so the title capsule's shadow is never cut off.
    private let chrome: UIHostingController<TaskDockChrome>
    private let chromeLayer = ChromeLayerView()
    /// The last Task's header while it fades out over a new Task's.
    private weak var outgoingHeader: UIView?
    /// 0 minimized, 1 expanded.
    private(set) var progress: CGFloat = 0
    var dragStart: CGFloat = 0
    var animator: UIViewPropertyAnimator?
    /// How far the keyboard reaches over the panel; 0 while it is down.
    var keyboardOverlap: CGFloat = 0
    private var laidOutSize: CGSize = .zero
    private var laidOutSafeInsets: UIEdgeInsets = .zero
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

    init(store: CommaStore, pane: ConversationPane, revealRequest: Int, onExpand: @escaping () -> Void) {
        self.store = store
        self.pane = pane
        self.revealRequest = revealRequest
        self.onExpand = onExpand
        let state = TaskDockState()
        self.state = state
        hosting = UIHostingController(rootView: TaskDockContent(store: store, pane: pane, state: state))
        chrome = UIHostingController(rootView: TaskDockChrome(store: store, pane: pane, state: state, actions: TaskDockActions()))
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
        panel.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        view.addSubview(panel)

        addChild(hosting)
        hosting.safeAreaRegions = []
        hosting.view.backgroundColor = .clear
        panel.addSubview(hosting.view)
        hosting.didMove(toParent: self)

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
        // The card covers the grabber's spot; it returns once the details close.
        state.onDetailsChange = { [weak self] open in
            guard let self else { return }
            UIView.animate(withDuration: 0.2) { self.grabber.alpha = open ? 0 : min(1, max(0, self.progress)) }
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
        guard view.bounds.width > 0,
              view.bounds.size != laidOutSize || insets != laidOutSafeInsets else { return }
        laidOutSize = view.bounds.size
        laidOutSafeInsets = insets
        let height = sheetHeight
        dimmer.frame = view.bounds
        panel.frame = CGRect(x: 0, y: view.bounds.height - height, width: view.bounds.width, height: height)
        shadow.frame = panel.frame
        shadow.layer.shadowPath = UIBezierPath(roundedRect: shadow.bounds, cornerRadius: Self.sheetRadius).cgPath
        hosting.view.frame = panel.bounds
        chromeLayer.frame = panel.bounds
        chrome.view.frame = chromeLayer.bounds
        updateInsets()
        cover.frame = CGRect(x: 0, y: Self.barHeight, width: panel.bounds.width, height: panel.bounds.height - Self.barHeight)
        layoutGrabber()
        if !presented {
            // Rise in from below the screen edge, then settle expanded.
            presented = true
            apply(-(Self.barHeight + safeBottom) / max(1, travel))
            DispatchQueue.main.async { self.animate(to: 1, velocity: 0) }
        } else {
            apply(progress)
        }
    }

    func update(pane next: ConversationPane, revealRequest request: Int) {
        if next !== pane {
            // A reused dock serves a new Task: it starts over, never in the old one's closing state.
            pane = next
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
    var safeSides: CGFloat { max(safeInsets.left, safeInsets.right) }
    private var sheetHeight: CGFloat { max(Self.barHeight, view.bounds.height - safeTop - Self.sheetTopGap) }
    private var minimizedHeight: CGFloat { Self.barHeight + safeBottom }
    /// Distance the panel travels between minimized and expanded.
    var travel: CGFloat { max(1, sheetHeight - minimizedHeight) }

    /// Only transforms and layer properties change here: no layout, no SwiftUI update.
    func apply(_ value: CGFloat) {
        progress = value
        let clamped = min(1, max(0, value))
        let translation = travel * (1 - value)
        panel.transform = CGAffineTransform(translationX: 0, y: translation)
        shadow.transform = panel.transform
        panel.layer.cornerRadius = Self.barRadius + (Self.sheetRadius - Self.barRadius) * clamped
        shadow.layer.shadowOpacity = Float(0.15 * clamped)
        dimmer.alpha = 0.3 * clamped
        cover.alpha = 1 - min(1, clamped * 2)
        grabber.alpha = state.detailsOpen ? 0 : clamped
    }

    /// Midway between the sheet's top edge and the title capsule.
    private func layoutGrabber() {
        let height: CGFloat = 5
        let y = max(2, (state.capsuleTop - height) / 2)
        grabber.frame = CGRect(x: (panel.bounds.width - 36) / 2, y: y, width: 36, height: height)
    }

    // MARK: Content

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
        hosting.rootView = TaskDockContent(store: store, pane: pane, state: state)
        chrome.rootView = TaskDockChrome(store: store, pane: pane, state: state, actions: TaskDockActions(
            toggle: { [weak self] in self?.toggle() },
            titleTapped: { [weak self] in self?.headerTapped() },
            close: { [weak self] in self?.dismiss() },
            archive: { [weak self] task in self?.dismiss(archiving: task) }))
    }
}
