import SwiftUI
import UIKit
import CommaCore

/// The open Task as one UIKit panel over the app. Minimized, only its bar (close, title, status) shows
/// at the bottom edge; dragging the bar or the expanded sheet's header follows the finger between the
/// bar and a full sheet. The panel is sized once to the full sheet and only translated while dragging,
/// so the drag never re-lays out SwiftUI content; release uses a velocity-carrying spring.
struct TaskDockHost: UIViewControllerRepresentable {
    let store: CommaStore
    let pane: ConversationPane
    /// Advances on every request to show a Task, including the one already open.
    let revealRequest: Int
    let onExpand: () -> Void
    /// Fires once the opening sheet has finished rising (or the user has taken hold of it), so the app
    /// behind can make room for the bar while the sheet still covers it.
    var onSettled: () -> Void = {}
    /// Fires when the close button starts sliding the sheet away, so the app behind can take back the
    /// bar's room underneath it.
    var onDismissing: () -> Void = {}

    func makeUIViewController(context: Context) -> TaskDockViewController {
        let controller = TaskDockViewController(store: store, pane: pane, revealRequest: revealRequest, onExpand: onExpand)
        controller.onSettled = onSettled
        controller.onDismissing = onDismissing
        return controller
    }

    func updateUIViewController(_ controller: TaskDockViewController, context: Context) {
        controller.onExpand = onExpand
        controller.onSettled = onSettled
        controller.onDismissing = onDismissing
        controller.update(pane: pane, revealRequest: revealRequest)
    }
}

final class TaskDockViewController: UIViewController, UIGestureRecognizerDelegate {
    static let barHeight: CGFloat = 60
    private static let grabberHeight: CGFloat = 10
    private static let barRadius: CGFloat = 22
    private static let sheetRadius: CGFloat = 38
    /// Space between the status bar and the expanded sheet, like a large system sheet.
    private static let sheetTopGap: CGFloat = 10

    private let store: CommaStore
    private var pane: ConversationPane
    private var revealRequest: Int
    private let panel = UIView()
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
    /// 0 minimized, 1 expanded.
    private var progress: CGFloat = 0
    private var dragStart: CGFloat = 0
    private var animator: UIViewPropertyAnimator?
    private var keyboardOverlap: CGFloat = 0
    private var laidOutSize: CGSize = .zero
    private var laidOutSafeInsets: UIEdgeInsets = .zero
    private var presented = false
    private let state = TaskDockState()
    private weak var outsideTap: UITapGestureRecognizer?
    var onExpand: () -> Void
    var onSettled: () -> Void = {}
    var onDismissing: () -> Void = {}
    private var settled = false
    private var dismissing = false

    init(store: CommaStore, pane: ConversationPane, revealRequest: Int, onExpand: @escaping () -> Void) {
        self.store = store
        self.pane = pane
        self.revealRequest = revealRequest
        self.onExpand = onExpand
        hosting = UIHostingController(rootView: TaskDockContent(store: store, pane: pane, bottomInset: 0))
        chrome = UIHostingController(rootView: TaskDockChrome(store: store, pane: pane, state: state,
                                                              toggle: {}, headerTapped: {}, close: {}))
        super.init(nibName: nil, bundle: nil)
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

        refreshContent()
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
        refreshContent()
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
            refreshContent()
        }
        if request != revealRequest {
            revealRequest = request
            animate(to: 1, velocity: 0)
        }
    }

    // MARK: Geometry

    private var safeInsets: UIEdgeInsets { view.window?.safeAreaInsets ?? view.safeAreaInsets }
    private var safeTop: CGFloat { safeInsets.top }
    private var safeBottom: CGFloat { safeInsets.bottom }
    private var sheetHeight: CGFloat { max(Self.barHeight, view.bounds.height - safeTop - Self.sheetTopGap) }
    private var minimizedHeight: CGFloat { Self.barHeight + safeBottom }
    /// Distance the panel travels between minimized and expanded.
    private var travel: CGFloat { max(1, sheetHeight - minimizedHeight) }

    /// Only transforms and layer properties change here: no layout, no SwiftUI update.
    private func apply(_ value: CGFloat) {
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

    // MARK: Interaction

    /// The strip-above-the-sheet tap only sees touches outside the panel, so it never competes with the
    /// header's buttons or the card's own controls.
    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard recognizer === outsideTap else { return true }
        return state.detailsOpen && !panel.frame.contains(touch.location(in: view))
    }

    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard let pan = recognizer as? UIPanGestureRecognizer else { return true }
        // The open details own every touch until they close.
        if state.detailsOpen { return false }
        // The grabber and header own the drag; the transcript keeps its own scrolling.
        let location = pan.location(in: panel)
        let velocity = pan.velocity(in: panel)
        return location.y <= Self.barHeight && abs(velocity.y) >= abs(velocity.x)
    }

    /// SwiftUI's own recognizers in the header (the title tap, the close button) must not block the drag;
    /// a tap still fails on its own once the finger moves.
    func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        !(other.view is UIScrollView)
    }

    @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            cancelDismissal()
            settle()
            if let animator, animator.isRunning {
                animator.stopAnimation(true)
                // Resume from where the interrupted spring currently draws the panel.
                let drawn = panel.layer.presentation()?.affineTransform().ty ?? panel.transform.ty
                apply(1 - drawn / travel)
            }
            animator = nil
            dragStart = progress
            if progress <= 0.5, pan.velocity(in: view).y < 0 { onExpand() }
            view.endEditing(true)
        case .changed:
            let raw = dragStart - pan.translation(in: view).y / travel
            // Rubber-band past either end, like a sheet at its detent limits.
            apply(raw > 1 ? 1 + (raw - 1) * 0.12 : raw < 0 ? raw * 0.12 : raw)
        case .ended, .cancelled, .failed:
            let velocity = -pan.velocity(in: view).y / travel
            let projected = progress + velocity * 0.2
            animate(to: projected > 0.5 ? 1 : 0, velocity: velocity)
        default:
            break
        }
    }

    /// Closing slides the sheet off the bottom while the dim behind it fades in place; the Task is
    /// removed only once the sheet is gone, so nothing behind it moves with it.
    func dismiss() {
        guard !dismissing else { return }
        dismissing = true
        view.endEditing(true)
        state.detailsOpen = false
        animator?.stopAnimation(true)
        animator = nil
        let offscreen = -(Self.barHeight + safeBottom + 24) / travel
        let spring = UISpringTimingParameters(mass: 1, stiffness: 320, damping: 34, initialVelocity: .zero)
        let closing = UIViewPropertyAnimator(duration: 0, timingParameters: spring)
        closing.addAnimations { self.apply(offscreen) }
        closing.addCompletion { [weak self] position in
            guard let self, position == .end, self.dismissing else { return }
            self.animator = nil
            self.store.closeTask()
        }
        closing.startAnimation()
        // Held as the current animation, so a reveal or a drag can take the sheet back mid-close.
        animator = closing
        onDismissing()
    }

    func toggle() {
        if progress <= 0.5 { onExpand() }
        animate(to: progress > 0.5 ? 0 : 1, velocity: 0)
    }

    private func animate(to target: CGFloat, velocity: CGFloat) {
        animator?.stopAnimation(true)
        cancelDismissal()
        let distance = target - progress
        let relative = abs(distance) > 0.001 ? max(-20, min(20, velocity / distance)) : 0
        // Close to the system sheet spring; the finger's speed carries into the settle.
        let spring = UISpringTimingParameters(mass: 1, stiffness: 320, damping: 34,
                                              initialVelocity: CGVector(dx: 0, dy: relative))
        let animator = UIViewPropertyAnimator(duration: 0, timingParameters: spring)
        animator.addAnimations { self.apply(target) }
        animator.addCompletion { [weak self] _ in
            self?.animator = nil
            self?.settle()
        }
        animator.startAnimation()
        self.animator = animator
        if target < 0.5 {
            view.endEditing(true)
            state.detailsOpen = false
        }
    }

    @objc private func handleOutsideTap(_ tap: UITapGestureRecognizer) {
        guard state.detailsOpen, !panel.frame.contains(tap.location(in: view)) else { return }
        state.detailsOpen = false
    }

    /// Expanded, the header opens the Task details; minimized, it raises the sheet as before.
    private func headerTapped() {
        guard progress > 0.5 else { return toggle() }
        view.endEditing(true)
        state.detailsOpen.toggle()
    }

    /// A reveal or a drag during the close keeps the Task: the close is called off and the app behind
    /// makes room for the bar again once the sheet settles.
    private func cancelDismissal() {
        guard dismissing else { return }
        dismissing = false
        settled = false
    }

    private func settle() {
        guard !settled else { return }
        settled = true
        onSettled()
    }

    /// Touches outside the panel reach the app while minimized; expanded, the sheet takes them all.
    fileprivate func owns(_ point: CGPoint) -> Bool {
        progress > 0.5 || panel.frame.contains(point)
    }

    // MARK: Content

    private func refreshContent() {
        hosting.rootView = TaskDockContent(store: store, pane: pane, bottomInset: max(keyboardOverlap, safeBottom))
        chrome.rootView = TaskDockChrome(store: store, pane: pane, state: state,
                                         toggle: { [weak self] in self?.toggle() },
                                         headerTapped: { [weak self] in self?.headerTapped() },
                                         close: { [weak self] in self?.dismiss() })
    }

    @objc private func keyboardWillChange(_ note: Notification) {
        guard let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue,
              let window = view.window else { return }
        let overlap = max(0, window.bounds.maxY - window.convert(end, from: nil).minY)
        guard abs(overlap - keyboardOverlap) > 0.5 else { return }
        keyboardOverlap = overlap
        let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
        UIView.animate(withDuration: duration) { self.refreshContent(); self.hosting.view.layoutIfNeeded() }
    }
}

/// A full-screen container that only keeps the touches the dock wants.
private final class PassthroughView: UIView {
    weak var dock: TaskDockViewController?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let dock, dock.owns(point) else { return nil }
        return super.hitTest(point, with: event) ?? self
    }
}

/// The dock's transcript: the Task conversation below the header slot.
struct TaskDockContent: View {
    let store: CommaStore
    @Bindable var pane: ConversationPane
    /// Home indicator or keyboard, supplied by the UIKit panel.
    let bottomInset: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            // The header lives in the chrome layer above; this slot keeps the transcript below it.
            Color.clear.frame(height: TaskDockViewController.barHeight)
            PhoneConversationView(store: store, pane: pane)
                .safeAreaPadding(.bottom, bottomInset)
        }
    }
}

/// The header, which grows in place into the Task details. It is hosted above the panel's cover.
struct TaskDockChrome: View {
    let store: CommaStore
    @Bindable var pane: ConversationPane
    @Bindable var state: TaskDockState
    let toggle: () -> Void
    let headerTapped: () -> Void
    let close: () -> Void

    var body: some View {
        TaskDetailsCard(store: store, pane: pane, state: state) {
            TaskDockHeader(store: store, pane: pane, expanded: state.detailsOpen, pressed: state.titlePressed,
                           tap: headerTapped, onPress: { state.titlePressed = $0 }, toggle: toggle,
                           close: close)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// Hosts the chrome and passes through touches the chrome does not claim.
private final class ChromeLayerView: UIView {
    var accepts: (CGPoint) -> Bool = { _ in true }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard accepts(point) else { return nil }
        return super.hitTest(point, with: event)
    }
}

/// Close, title and status. Tapping the title opens or closes the Task details; minimized, it raises the sheet.
private struct TaskDockHeader: View {
    let store: CommaStore
    @Bindable var pane: ConversationPane
    let expanded: Bool
    let pressed: Bool
    let tap: () -> Void
    let onPress: (Bool) -> Void
    let toggle: () -> Void
    let close: () -> Void
    @State private var renaming: Conversation?
    @State private var sharing: Conversation?

    var body: some View {
        let task = store.taskSummary(id: pane.taskID ?? "")
        HStack(spacing: 12) {
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(CommaTheme.textPrimary)
                    .frame(width: 36, height: 36)
                    .commaGlass(in: Circle(), interactive: true)
            }
            .buttonStyle(TactileButtonStyle(scale: 0.9))
            .accessibilityLabel("Close task")
            // The title is a button: held, it grows a little and its surface fills in.
            Button(action: tap) {
                VStack(spacing: 1) {
                    Text(task?.title ?? String(localized: "Task"))
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(CommaTheme.textPrimary).lineLimit(1)
                    if let task {
                        HStack(spacing: 4) {
                            TaskStatusIcon(bucket: task.bucket, size: 11)
                            Text(task.bucket.label).font(.system(size: 12, weight: .medium)).foregroundStyle(CommaTheme.textQuaternary)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .bold)).foregroundStyle(CommaTheme.textPlaceholder)
                                .rotationEffect(.degrees(expanded ? 180 : 0))
                        }
                    }
                }
                .scaleEffect(pressed ? TaskTitlePress.scale : 1)
                .animation(TaskTitlePress.animation(pressed), value: pressed)
                // The details card grows out of the title's resting bounds, measured outside the press scale.
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: TaskTitleFrameKey.self,
                                               value: proxy.frame(in: .named(taskDetailsCardSpace)))
                    }
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressReportingButtonStyle(onPress: onPress))
            .accessibilityLabel(Text(task?.title ?? String(localized: "Task")))
            .accessibilityValue(task.map { Text($0.bucket.label) } ?? Text(""))
            .accessibilityAction(named: Text("Show or minimize task"), toggle)
            // The same width as the close button, so the title stays centred.
            if let task {
                Menu {
                    TaskActionMenuItems(store: store, task: task, rename: { renaming = task }, share: { sharing = task })
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(CommaTheme.textPrimary)
                        .frame(width: 36, height: 36)
                        .commaGlass(in: Circle(), interactive: true)
                }
                .accessibilityLabel("Task actions")
                .accessibilityIdentifier("taskActions")
            } else {
                Color.clear.frame(width: 36, height: 36)
            }
        }
        .padding(.horizontal, 16)
        .taskActionSheets(store: store, renaming: $renaming, sharing: $sharing)
    }
}
