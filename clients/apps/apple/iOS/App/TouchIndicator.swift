import UIKit
import UIKit.UIGestureRecognizerSubclass

/// A dot under each finger while the screen is captured: a screen recording, AirPlay or a wired mirror, or a computer
/// reading the screen over USB. A viewer of the capture sees where the member touches; nothing shows otherwise.
///
/// The dots sit on the scene's topmost window of the app, over sheets, toasts and the call, and take no touches.
/// They are plain views there, not a window of their own, which would decide the status bar's look and the
/// rotation while it shows.
@MainActor
final class TouchIndicator: NSObject {
    static let shared = TouchIndicator()
    static let diameter: CGFloat = 40
    /// Frosted glass: the page shows through blurred under a white wash, bright on a light page and dimmer on a
    /// dark one. The ring shows it on a dark page, the hairline around it and the shadow on a light one.
    private static let frost = UIBlurEffect(style: .systemUltraThinMaterial)
    private static let wash = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.2) : UIColor(white: 1, alpha: 0.5) }
    private static let ring = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.45) : UIColor(white: 1, alpha: 0.9) }
    private static let ringWidth: CGFloat = 1.5
    private static let hairline = UIColor.black.withAlphaComponent(0.18)
    private static let shadowOpacity: Float = 0.28
    private static let shadowRadius: CGFloat = 6
    private static let shadowOffset = CGSize(width: 0, height: 2)
    private static let enter: TimeInterval = 0.1
    private static let exit: TimeInterval = 0.2
    /// A tap's dot stays this long at least, so a capture's frames show it.
    private static let shortest: TimeInterval = 0.15
    /// A dot enters and leaves by its size, from and to half of it, where it is not visible.
    private static let small = CGAffineTransform(scaleX: 0.5, y: 0.5)

    #if DEBUG
    /// `--show-touches` marks the fingers without a capture, to look at in a simulator, whose recordings are not
    /// captures to the app.
    private static let always = ProcessInfo.processInfo.arguments.contains("--show-touches")
    #else
    private static let always = false
    #endif

    private let stage = UIView()
    private var dots: [ObjectIdentifier: (view: UIView, since: CFTimeInterval)] = [:]
    private var watching = false

    override init() {
        super.init()
        stage.isUserInteractionEnabled = false
        stage.accessibilityElementsHidden = true
        stage.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // Over what the window presents later, which it adds above its earlier subviews.
        stage.layer.zPosition = .greatestFiniteMagnitude
    }

    /// Follows the touches of each window from when it shows, for as long as the process lasts.
    func watch() {
        guard !watching else { return }
        watching = true
        NotificationCenter.default.addObserver(self, selector: #selector(shown), name: UIWindow.didBecomeVisibleNotification,
                                               object: nil)
        for scene in UIApplication.shared.connectedScenes {
            (scene as? UIWindowScene)?.windows.forEach(watch)
        }
    }

    func watches(_ window: UIWindow) -> Bool {
        window.gestureRecognizers?.contains { $0 is TouchWatcher } == true
    }

    @objc private func shown(_ note: Notification) {
        if let window = note.object as? UIWindow { watch(window) }
    }

    private func watch(_ window: UIWindow) {
        if !watches(window) { window.addGestureRecognizer(TouchWatcher(self)) }
    }

    /// The fingers down, in the screen's coordinates.
    var points: [CGPoint] {
        dots.values.map { stage.convert($0.view.center, to: stage.window?.screen.coordinateSpace ?? stage) }
    }

    /// The window the dots are on, while there are any.
    var window: UIWindow? { stage.window }

    func follow(_ touches: Set<UITouch>) {
        // A pointer has the system's own cursor.
        for touch in touches where touch.type != .indirectPointer {
            let id = ObjectIdentifier(touch)
            guard let window = touch.window else { lift(id); continue }
            follow(id, phase: touch.phase, at: touch.location(in: window), in: window,
                   captured: Self.always || window.traitCollection.sceneCaptureState == .active)
        }
    }

    /// One touch's step: `point` is in `window`, the window the touch is in.
    func follow(_ id: ObjectIdentifier, phase: UITouch.Phase, at point: CGPoint, in window: UIWindow, captured: Bool) {
        guard captured else { return clear() }
        switch phase {
        case .ended, .cancelled: lift(id)
        default:
            let top = Self.top(over: window)
            if stage.superview !== top {
                stage.frame = top.bounds
                top.addSubview(stage)
            }
            let dot = dots[id]?.view ?? add(id)
            dot.center = stage.convert(point, from: window)
        }
    }

    /// The topmost of the app's windows that show in the touched window's scene. The system's own windows there
    /// (the text effects) are left alone.
    private static func top(over window: UIWindow) -> UIWindow {
        var top = window
        for other in window.windowScene?.windows ?? [] where !other.isHidden && other.alpha > 0 {
            let kind: AnyClass = type(of: other)
            guard kind == UIWindow.self || Bundle(for: kind) == .main else { continue }
            if other.windowLevel >= top.windowLevel { top = other }
        }
        return top
    }

    private func add(_ id: ObjectIdentifier) -> UIView {
        let dot = UIView(frame: CGRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter))
        dot.layer.cornerRadius = Self.diameter / 2
        dot.layer.borderColor = Self.hairline.cgColor
        dot.layer.borderWidth = 1 / max(stage.traitCollection.displayScale, 1)
        dot.layer.shadowColor = UIColor.black.cgColor
        dot.layer.shadowOpacity = Self.shadowOpacity
        dot.layer.shadowRadius = Self.shadowRadius
        dot.layer.shadowOffset = Self.shadowOffset
        dot.layer.shadowPath = UIBezierPath(ovalIn: dot.bounds).cgPath
        let glass = UIVisualEffectView(effect: Self.frost)
        glass.frame = dot.bounds
        glass.contentView.backgroundColor = Self.wash
        glass.clipsToBounds = true
        glass.layer.cornerRadius = Self.diameter / 2
        glass.layer.borderColor = Self.ring.resolvedColor(with: stage.traitCollection).cgColor
        glass.layer.borderWidth = Self.ringWidth
        dot.addSubview(glass)
        dot.alpha = 0
        dot.transform = Self.small
        stage.addSubview(dot)
        dots[id] = (dot, CACurrentMediaTime())
        UIView.animate(withDuration: Self.enter, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
            dot.alpha = 1
            dot.transform = .identity
        }
        return dot
    }

    private func lift(_ id: ObjectIdentifier) {
        guard let (dot, since) = dots.removeValue(forKey: id) else { return }
        let wait = max(0, Self.shortest - (CACurrentMediaTime() - since))
        UIView.animate(withDuration: Self.exit, delay: wait, options: [.curveEaseIn, .beginFromCurrentState]) {
            dot.alpha = 0
            dot.transform = Self.small
        } completion: { [weak self] _ in
            dot.removeFromSuperview()
            self?.settle()
        }
    }

    /// The capture ended: its dots go at once, as nothing records their exit.
    private func clear() {
        guard !dots.isEmpty else { return }
        dots.removeAll()
        stage.subviews.forEach { $0.removeFromSuperview() }
        settle()
    }

    /// Leaves the window once the last dot has gone.
    private func settle() {
        if stage.subviews.isEmpty { stage.removeFromSuperview() }
    }
}

/// Sees a window's touches and recognizes nothing: it takes no touch from the views and holds no other recognizer
/// back, and none ends it.
private final class TouchWatcher: UIGestureRecognizer {
    private unowned let indicator: TouchIndicator

    init(_ indicator: TouchIndicator) {
        self.indicator = indicator
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func canPrevent(_ other: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by other: UIGestureRecognizer) -> Bool { false }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) { indicator.follow(touches) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) { indicator.follow(touches) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { indicator.follow(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { indicator.follow(touches) }
}
