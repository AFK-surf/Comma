import SwiftUI
import UIKit

/// A separate scene window keeps the call above navigation, sheets and full-screen covers.
/// It never takes keyboard focus, and only the visible call surface intercepts touches.
struct CallWindowHost: UIViewRepresentable {
    let call: CallController

    func makeUIView(context: Context) -> CallWindowAnchor { CallWindowAnchor() }
    func updateUIView(_ view: CallWindowAnchor, context: Context) {
        view.call = call
        view.synchronize(shown: call.shown, expanded: call.expanded)
    }
    static func dismantleUIView(_ view: CallWindowAnchor, coordinator: ()) { view.removeCallWindow() }
}

final class CallWindowAnchor: UIView {
    var call: CallController?
    private var callWindow: CallSurfaceWindow?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { removeCallWindow() }
        else if let call { synchronize(shown: call.shown, expanded: call.expanded) }
    }

    func synchronize(shown: Bool, expanded: Bool) {
        guard let scene = window?.windowScene, let call else { return }
        if callWindow == nil {
            let surface = CallSurfaceWindow(windowScene: scene)
            surface.windowLevel = .alert + 1
            surface.backgroundColor = .clear
            let controller = CallSurfaceController(call: call)
            controller.hostWindow = surface
            surface.rootViewController = controller
            callWindow = surface
        }
        callWindow?.controller?.synchronize(shown: shown, expanded: expanded)
        if shown && expanded { window?.endEditing(true) }
    }

    func removeCallWindow() {
        callWindow?.isHidden = true
        callWindow?.rootViewController = nil
        callWindow = nil
    }
}

private final class CallSurfaceWindow: UIWindow {
    var controller: CallSurfaceController? { rootViewController as? CallSurfaceController }

    /// The full page takes every touch; the bubble only its own, so the app beneath keeps working.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let controller, controller.receivesTouch(at: point) else { return nil }
        return super.hitTest(point, with: event)
    }
}

/// One surface that is the full call page at progress 0 and the floating bubble at progress 1.
///
/// The page is laid out once at the window's size and only ever scaled down, so its text never blurs; the
/// surface's frame and corners carry the size change. Expanding and collapsing run as Core Animation springs,
/// which keep their pace while the main thread is busy. Gestures set the progress directly, frame by frame:
/// dragging the bubble moves it under the finger, and a swipe from the page's left edge shrinks the page
/// toward the bubble as far as the finger has gone.
final class CallSurfaceController: UIViewController, UIGestureRecognizerDelegate {
    static let bubbleSize = CGSize(width: 72, height: 88)
    private static let bubbleRadius: CGFloat = 18
    private static let margin: CGFloat = 12
    /// How far the edge swipe travels, as a share of the width, to shrink the page all the way.
    private static let swipeTravel: CGFloat = 0.75
    private static let duration: TimeInterval = 0.32

    private let call: CallController
    /// The window this surface fills; shown while there is a call to show.
    weak var hostWindow: UIWindow?
    /// Darkens the app behind the page while it shrinks, so the page's edges show; gone at the bubble.
    private let shade = UIView()
    /// Moves and resizes; carries the bubble's shadow, so it does not clip.
    private let card = UIView()
    /// Clips the page and the bubble face to the rounded frame.
    private let surface = UIView()
    private let page: UIHostingController<CallPage>
    private let bubble: UIHostingController<CallBubbleFace>
    private lazy var tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
    private lazy var drag = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
    private lazy var swipe = UIPanGestureRecognizer(target: self, action: #selector(swiped(_:)))

    private var shown = false
    /// Where the surface rests: 0 the page, 1 the bubble.
    private var target: CGFloat = 1
    private var progress: CGFloat = 1
    private var bubbleCenter: CGPoint?
    /// The grabbed point's offset from the bubble's center, so that point stays under the finger.
    private var grab: CGPoint?
    /// Where the finger came down, before any recognizer's slop.
    private var touchDown: CGPoint?
    private var layoutSize: CGSize = .zero

    init(call: CallController) {
        self.call = call
        page = UIHostingController(rootView: CallPage(call: call, insets: EdgeInsets()))
        bubble = UIHostingController(rootView: CallBubbleFace(call: call))
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func loadView() {
        let root = UIView()
        root.backgroundColor = .clear
        view = root

        shade.backgroundColor = .black
        shade.alpha = 0
        shade.isUserInteractionEnabled = false
        shade.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(shade)

        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowRadius = 12
        card.layer.shadowOffset = CGSize(width: 0, height: 4)
        card.layer.shadowOpacity = 0
        card.alpha = 0
        view.addSubview(card)

        surface.frame = card.bounds
        surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        surface.clipsToBounds = true
        surface.layer.cornerCurve = .continuous
        surface.backgroundColor = surfaceColor(1)
        card.addSubview(surface)

        for host in [page, bubble] as [UIViewController] {
            addChild(host)
            host.view.backgroundColor = .clear
            surface.addSubview(host.view)
            host.didMove(toParent: self)
        }
        // Laid out at fixed sizes by this controller: no safe-area or size recomputation while the surface moves.
        page.safeAreaRegions = []
        bubble.safeAreaRegions = []
        page.sizingOptions = []
        bubble.sizingOptions = []

        tap.delegate = self
        drag.delegate = self
        swipe.delegate = self
        drag.maximumNumberOfTouches = 1
        swipe.maximumNumberOfTouches = 1
        card.addGestureRecognizer(tap)
        card.addGestureRecognizer(drag)
        card.addGestureRecognizer(swipe)
        // Light and dark change the page's color, which the surface blends toward.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            if self.card.layer.animationKeys()?.isEmpty != false { self.apply(self.progress); self.settle() }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard view.bounds.size != layoutSize else { return }
        layoutSize = view.bounds.size
        page.view.bounds = CGRect(origin: .zero, size: view.bounds.size)
        shade.frame = view.bounds
        bubble.view.bounds = CGRect(origin: .zero, size: Self.bubbleSize)
        if let center = bubbleCenter { bubbleCenter = clamped(center) }
        apply(progress)
        settle()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        let insets = view.safeAreaInsets
        page.rootView = CallPage(call: call, insets: EdgeInsets(top: insets.top, leading: insets.left,
                                                                bottom: insets.bottom, trailing: insets.right))
        if let center = bubbleCenter { bubbleCenter = clamped(center); if target == 1 { apply(1) } }
    }

    // MARK: State

    func synchronize(shown: Bool, expanded: Bool) {
        loadViewIfNeeded()
        let next: CGFloat = expanded ? 0 : 1
        if shown != self.shown {
            self.shown = shown
            if shown { appear(at: next) } else { disappear() }
            return
        }
        guard shown, next != target else { return }
        animate(to: next)
    }

    func receivesTouch(at point: CGPoint) -> Bool {
        guard shown else { return false }
        if target == 0 || progress < 1 { return true }
        return card.frame.insetBy(dx: -6, dy: -6).contains(point)
    }

    private func appear(at value: CGFloat) {
        hostWindow?.isHidden = false
        view.frame = hostWindow?.bounds ?? view.frame
        view.layoutIfNeeded()
        card.layer.removeAllAnimations()
        target = value
        progress = value
        apply(value)
        settle()
        let scale: CGFloat = value == 0 ? 0.96 : 0.6
        let shadeAlpha = shade.alpha
        shade.alpha = 0
        card.transform = CGAffineTransform(scaleX: scale, y: scale)
        UIView.animate(springDuration: 0.28, bounce: 0, options: [.allowUserInteraction]) {
            self.card.alpha = 1
            self.shade.alpha = shadeAlpha
            self.card.transform = .identity
        }
    }

    private func disappear() {
        UIView.animate(withDuration: reduceMotion ? 0.15 : 0.25, delay: 0, options: [.beginFromCurrentState]) {
            self.card.alpha = 0
            self.shade.alpha = 0
            if !self.reduceMotion { self.card.transform = CGAffineTransform(scaleX: 0.9, y: 0.9) }
        } completion: { _ in
            guard !self.shown else { return }
            self.card.transform = .identity
            self.hostWindow?.isHidden = true
        }
    }

    // MARK: Geometry

    private var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }

    private var bubbleBounds: CGRect {
        let insets = view.safeAreaInsets
        let half = CGSize(width: Self.bubbleSize.width / 2, height: Self.bubbleSize.height / 2)
        return CGRect(x: insets.left + Self.margin + half.width, y: insets.top + Self.margin + half.height,
                      width: max(0, view.bounds.width - insets.left - insets.right - 2 * Self.margin - Self.bubbleSize.width),
                      height: max(0, view.bounds.height - insets.top - insets.bottom - 2 * Self.margin - Self.bubbleSize.height))
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        let bounds = bubbleBounds
        return CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX), y: min(max(point.y, bounds.minY), bounds.maxY))
    }

    /// Top right, under the status bar, until the user moves it.
    private var restingCenter: CGPoint {
        bubbleCenter ?? clamped(CGPoint(x: .greatestFiniteMagnitude, y: view.safeAreaInsets.top + 56 + Self.bubbleSize.height / 2))
    }

    private var bubbleFrame: CGRect {
        let center = restingCenter
        return CGRect(x: center.x - Self.bubbleSize.width / 2, y: center.y - Self.bubbleSize.height / 2,
                      width: Self.bubbleSize.width, height: Self.bubbleSize.height)
    }

    /// Lays out the surface for `value` without fading: the frame, the corners and the page's scale.
    private func applyGeometry(_ value: CGFloat) {
        let full = view.bounds
        let small = bubbleFrame
        let frame = CGRect(x: lerp(full.minX, small.minX, value), y: lerp(full.minY, small.minY, value),
                           width: lerp(full.width, small.width, value), height: lerp(full.height, small.height, value))
        card.bounds = CGRect(origin: .zero, size: frame.size)
        card.center = CGPoint(x: frame.midX, y: frame.midY)
        // Hidden under the display's own corners at full size; the bubble's corners at the end.
        surface.layer.cornerRadius = lerp(44, Self.bubbleRadius, value)
        let middle = CGPoint(x: frame.width / 2, y: frame.height / 2)
        page.view.center = middle
        bubble.view.center = middle
        let scale = full.width > 0 ? max(frame.width / full.width, frame.height / full.height) : 1
        page.view.transform = CGAffineTransform(scaleX: scale, y: scale)
        shade.alpha = 0.3 * (1 - value)
    }

    /// The page stays opaque while it shrinks and fades late; the surface turns from the page's color to the
    /// bubble's under it, so a half-way surface reads as a smaller page, not a gray card.
    private func applyFades(_ value: CGFloat) {
        page.view.alpha = 1 - smoothstep(0.4, 0.85, value)
        bubble.view.alpha = smoothstep(0.6, 1, value)
        surface.backgroundColor = surfaceColor(smoothstep(0.4, 0.9, value))
    }

    /// Between the page's background (0) and the bubble's card colour (1), for the current appearance: light in light
    /// mode, dark in dark mode.
    private func surfaceColor(_ amount: CGFloat) -> UIColor {
        let page = UIColor(CommaTheme.bgPrimary).resolvedColor(with: traitCollection)
        var a = (r: CGFloat(0), g: CGFloat(0), b: CGFloat(0), alpha: CGFloat(0))
        var b = a
        page.getRed(&a.r, green: &a.g, blue: &a.b, alpha: &a.alpha)
        UIColor(CommaTheme.cardPrimary).resolvedColor(with: traitCollection).getRed(&b.r, green: &b.g, blue: &b.b, alpha: &b.alpha)
        return UIColor(red: lerp(a.r, b.r, amount), green: lerp(a.g, b.g, amount), blue: lerp(a.b, b.b, amount), alpha: 1)
    }

    private func apply(_ value: CGFloat) {
        UIView.performWithoutAnimation {
            applyGeometry(value)
            applyFades(value)
        }
    }

    /// At rest, the hidden side leaves the accessibility tree and the bubble gets its shadow.
    private func settle() {
        let collapsed = target == 1
        page.view.isHidden = collapsed
        bubble.view.isHidden = !collapsed
        card.layer.shadowPath = collapsed
            ? UIBezierPath(roundedRect: CGRect(origin: .zero, size: Self.bubbleSize), cornerRadius: Self.bubbleRadius).cgPath
            : nil
        UIView.animate(withDuration: 0.2) { self.card.layer.shadowOpacity = collapsed ? 0.14 : 0 }
        surface.layer.borderColor = UIColor(CommaTheme.borderPrimary).resolvedColor(with: traitCollection).cgColor
        surface.layer.borderWidth = collapsed ? 1 : 0
    }

    private func unsettle() {
        page.view.isHidden = false
        bubble.view.isHidden = false
        card.layer.shadowOpacity = 0
        card.layer.shadowPath = nil
        surface.layer.borderWidth = 0
    }

    // MARK: Animation

    /// Springs from wherever the surface is now; `velocity` is progress per second toward `value`.
    private func animate(to value: CGFloat, velocity: CGFloat = 0) {
        target = value
        unsettle()
        let from = progress
        progress = value
        let remaining = abs(value - from)
        guard remaining > 0.001 else { apply(value); settle(); return }
        if reduceMotion {
            UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.applyGeometry(value)
                self.applyFades(value)
            } completion: { _ in if self.target == value { self.settle() } }
            return
        }
        let initial = min(max(velocity / remaining, 0), 12)
        let duration = Self.duration
        UIView.animate(springDuration: duration, bounce: 0, initialSpringVelocity: initial,
                       options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.applyGeometry(value)
        } completion: { _ in
            if self.target == value { self.settle() }
        }
        // The fades take their share of the same time, so the page is gone before the surface is bubble-sized.
        let collapsing = value > from
        UIView.animateKeyframes(withDuration: duration * 0.8, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            if collapsing {
                UIView.addKeyframe(withRelativeStartTime: 0.2, relativeDuration: 0.45) { self.page.view.alpha = 0 }
                UIView.addKeyframe(withRelativeStartTime: 0.2, relativeDuration: 0.5) { self.surface.backgroundColor = self.surfaceColor(1) }
                UIView.addKeyframe(withRelativeStartTime: 0.45, relativeDuration: 0.55) { self.bubble.view.alpha = 1 }
            } else {
                UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.2) { self.bubble.view.alpha = 0 }
                UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.3) { self.surface.backgroundColor = self.surfaceColor(0) }
                UIView.addKeyframe(withRelativeStartTime: 0.05, relativeDuration: 0.35) { self.page.view.alpha = 1 }
            }
        }
    }

    /// Stops a running animation where it is on screen, so a gesture continues from there.
    private func freeze() {
        guard let presentation = card.layer.presentation() else { return }
        let full = view.bounds, small = bubbleFrame
        let width = presentation.bounds.width
        let value = full.width == small.width ? target : (full.width - width) / (full.width - small.width)
        for layer in [card.layer, surface.layer, page.view.layer, bubble.view.layer, shade.layer] { layer.removeAllAnimations() }
        // The fades restart from the frozen progress rather than their keyframe values.
        progress = min(max(value, 0), 1)
        apply(progress)
    }

    // MARK: Gestures

    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        switch recognizer {
        case tap: return target == 1
        case drag: return target == 1
        case swipe:
            guard target == 0 else { return false }
            let start = swipe.location(in: view), velocity = swipe.velocity(in: view)
            let x = touchDown?.x ?? (start.x - swipe.translation(in: view).x)
            return x < 32 && velocity.x > abs(velocity.y)
        default: return true
        }
    }

    @objc private func tapped() {
        guard target == 1 else { return }
        call.expanded = true
        animate(to: 0)
    }

    /// The bubble stays under the finger, then rests where it is let go, inside the screen.
    @objc private func dragged(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            if card.layer.animationKeys()?.isEmpty == false { freeze() }
            // From where the finger first touched, not where the pan was recognized: the slop counts too.
            let down = touchDown ?? recognizer.location(in: view)
            let center = card.layer.presentation()?.position ?? card.center
            grab = CGPoint(x: center.x - down.x, y: center.y - down.y)
            fallthrough
        case .changed:
            guard let grab else { return }
            let location = recognizer.location(in: view)
            bubbleCenter = clamped(CGPoint(x: location.x + grab.x, y: location.y + grab.y))
            UIView.performWithoutAnimation { card.center = bubbleCenter ?? card.center }
        case .ended, .cancelled, .failed:
            grab = nil
            guard let current = bubbleCenter else { return }
            // A short throw continues a little in its direction, then settles inside the bounds.
            let velocity = recognizer.velocity(in: view)
            let thrown = clamped(CGPoint(x: current.x + velocity.x * 0.08, y: current.y + velocity.y * 0.08))
            bubbleCenter = thrown
            let distance = hypot(thrown.x - current.x, thrown.y - current.y)
            let speed = hypot(velocity.x, velocity.y)
            UIView.animate(springDuration: 0.35, bounce: 0, initialSpringVelocity: distance > 1 ? min(speed / distance, 10) : 0,
                           options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.card.center = thrown
            }
        default: break
        }
    }

    /// A swipe from the page's left edge shrinks it toward the bubble as far as the finger goes.
    @objc private func swiped(_ recognizer: UIPanGestureRecognizer) {
        let travel = max(1, view.bounds.width * Self.swipeTravel)
        switch recognizer.state {
        case .began:
            if card.layer.animationKeys()?.isEmpty == false { freeze() }
            unsettle()
            fallthrough
        case .changed:
            let start = touchDown?.x ?? (recognizer.location(in: view).x - recognizer.translation(in: view).x)
            progress = min(max((recognizer.location(in: view).x - start) / travel, 0), 1)
            apply(progress)
        case .ended, .cancelled, .failed:
            let speed = recognizer.velocity(in: view).x / travel
            let collapse = recognizer.state == .ended && (progress > 0.3 || speed > 1) && speed > -0.5
            if collapse { call.expanded = false }
            animate(to: collapse ? 1 : 0, velocity: abs(speed))
        default: break
        }
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if recognizer === drag || recognizer === swipe { touchDown = touch.location(in: view) }
        return true
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { false }
}

private func lerp(_ from: CGFloat, _ to: CGFloat, _ value: CGFloat) -> CGFloat { from + (to - from) * value }

private func smoothstep(_ low: CGFloat, _ high: CGFloat, _ value: CGFloat) -> CGFloat {
    let t = min(max((value - low) / (high - low), 0), 1)
    return t * t * (3 - 2 * t)
}
