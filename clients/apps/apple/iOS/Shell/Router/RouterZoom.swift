import UIKit

/// Where the router chat is on screen: the rect it covers and that rect's corner radius. The chat keeps its
/// full-size UIKit geometry; Core Animation scales its layers uniformly to cover the rect, centred in it, and
/// masks them to the rect. Nothing UIKit lays out changes, so the chat's safe area and layout hold still
/// through a zoom. The mask's frame and radius and the layers' scale and offset all change linearly between
/// any two frames, so one spring over them traces the zoom exactly.
struct RouterZoomFrame {
    var rect: CGRect
    var radius: CGFloat

    /// Settled over the whole layer, where the card's own edges clip the chat.
    static func open(in bounds: CGRect) -> Self { Self(rect: bounds, radius: 0) }

    /// Arriving over the whole layer, with the card's corners; once settled the chat drops them.
    static func opening(in bounds: CGRect) -> Self { Self(rect: bounds, radius: CommaTheme.cardRadius) }

    /// Closed into the router button, a circle.
    static func closed(into button: CGRect) -> Self {
        Self(rect: button, radius: min(button.width, button.height) / 2)
    }

    /// The frame `mask` shows on screen now, partway through its animation while one runs.
    init(shownBy mask: CALayer) {
        let shown = mask.shown
        rect = CGRect(x: shown.position.x - shown.bounds.width / 2, y: shown.position.y - shown.bounds.height / 2,
                      width: shown.bounds.width, height: shown.bounds.height)
        radius = shown.cornerRadius
    }

    private init(rect: CGRect, radius: CGFloat) {
        self.rect = rect
        self.radius = radius
    }

    /// This frame with at least the card's corners, as the chat takes them once it starts to shrink.
    var rounded: Self { Self(rect: rect, radius: max(radius, CommaTheme.cardRadius)) }

    /// The frame `progress` of the way from `start` to `end`, on the straight path a zoom between them takes.
    static func between(_ start: Self, _ end: Self, _ progress: CGFloat) -> Self {
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * progress }
        return Self(rect: CGRect(x: mix(start.rect.minX, end.rect.minX), y: mix(start.rect.minY, end.rect.minY),
                                 width: mix(start.rect.width, end.rect.width),
                                 height: mix(start.rect.height, end.rect.height)),
                    radius: mix(start.radius, end.radius))
    }

    /// Draws `layer`, laid out at its full size, covering the rect inside `mask`, which masks the layer's
    /// superlayer.
    func apply(to layer: CALayer, mask: CALayer) {
        layer.transform = transform(in: layer.bounds)
        shape(mask)
    }

    /// Moves `layer` and `mask` from `start` to this frame on the router spring, or Reduce Motion's ease.
    func animate(layer: CALayer, mask: CALayer, from start: RouterZoomFrame, velocity: CGFloat, reduceMotion: Bool) {
        layer.transform = transform(in: layer.bounds)
        let move = RouterSpring.animation("transform", velocity: velocity, reduceMotion: reduceMotion)
        move.fromValue = NSValue(caTransform3D: start.transform(in: layer.bounds))
        move.toValue = NSValue(caTransform3D: transform(in: layer.bounds))
        layer.add(move, forKey: "routerZoom.transform")
        animateShape(mask, from: start, velocity: velocity, reduceMotion: reduceMotion)
    }

    /// Puts `layer` on the rect, with its corners. `centred` puts the origin of its coordinates at the rect's
    /// centre, so a sublayer placed at the origin stays centred as the shape changes.
    func shape(_ layer: CALayer, centred: Bool = false) {
        layer.bounds = bounds(centred: centred)
        layer.position = CGPoint(x: rect.midX, y: rect.midY)
        layer.cornerRadius = radius
    }

    /// Moves `layer`'s shape (`shape(_:centred:)`) from `start` to this frame on the router spring.
    func animateShape(_ layer: CALayer, from start: RouterZoomFrame, centred: Bool = false, velocity: CGFloat,
                      reduceMotion: Bool) {
        let changes: [(String, Any, Any)] = [
            ("bounds", NSValue(cgRect: start.bounds(centred: centred)), NSValue(cgRect: bounds(centred: centred))),
            ("position", NSValue(cgPoint: CGPoint(x: start.rect.midX, y: start.rect.midY)),
             NSValue(cgPoint: CGPoint(x: rect.midX, y: rect.midY))),
            ("cornerRadius", start.radius, radius),
        ]
        shape(layer, centred: centred)
        for (keyPath, from, to) in changes {
            let animation = RouterSpring.animation(keyPath, velocity: velocity, reduceMotion: reduceMotion)
            animation.fromValue = from
            animation.toValue = to
            layer.add(animation, forKey: "routerZoom.\(keyPath)")
        }
    }

    private func bounds(centred: Bool) -> CGRect {
        let origin = centred ? CGPoint(x: -rect.width / 2, y: -rect.height / 2) : .zero
        return CGRect(origin: origin, size: rect.size)
    }

    /// Scales a layer filling `bounds` about its centre to cover the rect, then centres it on the rect.
    private func transform(in bounds: CGRect) -> CATransform3D {
        let scale = bounds.width > 0 && bounds.height > 0
            ? max(rect.width / bounds.width, rect.height / bounds.height) : 1
        let move = CATransform3DMakeTranslation(rect.midX - bounds.midX, rect.midY - bounds.midY, 0)
        return CATransform3DScale(move, scale, scale, 1)
    }
}

extension CALayer {
    /// The layer as on screen: its presentation while an animation runs on it, else the layer itself, as the
    /// presentation would still hold the last frame an animation drew.
    var shown: CALayer { animationKeys()?.isEmpty == false ? presentation() ?? self : self }
}

/// The router zoom's spring: critically damped with a 0.32 s response, like an app opening from its icon, so
/// neither end overshoots. At 0.4 s the zoom read as slow; this one has the chat into the button in about 0.27 s.
/// Velocities are fractions of the whole move per second.
enum RouterSpring {
    private static let omega = 2 * Double.pi / 0.32

    /// An animation along the spring at `velocity`; with Reduce Motion, a short ease instead.
    static func animation(_ keyPath: String, velocity: CGFloat, reduceMotion: Bool) -> CABasicAnimation {
        guard !reduceMotion else {
            let ease = CABasicAnimation(keyPath: keyPath)
            ease.duration = 0.2
            ease.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            return ease
        }
        let spring = CASpringAnimation(keyPath: keyPath)
        spring.mass = 1
        spring.stiffness = omega * omega
        spring.damping = 2 * omega
        spring.initialVelocity = limited(velocity)
        spring.duration = spring.settlingDuration
        return spring
    }

    /// Fades `layer` to `opacity` while the spring covers `span` of its move, holding its current opacity until
    /// then; with Reduce Motion, over a short ease.
    static func fade(_ layer: CALayer, to opacity: Float, over span: (CGFloat, CGFloat), velocity: CGFloat,
                     reduceMotion: Bool) {
        let from = layer.opacity
        guard from != opacity else { return }
        layer.opacity = opacity
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = opacity
        if reduceMotion {
            fade.duration = 0.2
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        } else {
            let delay = time(toCover: span.0, velocity: velocity)
            fade.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
            fade.duration = max(0.01, time(toCover: span.1, velocity: velocity) - delay)
            fade.fillMode = .backwards
        }
        layer.add(fade, forKey: "routerZoom.opacity")
    }

    /// Seconds until the spring has covered `fraction` of its move.
    static func time(toCover fraction: CGFloat, velocity: CGFloat) -> TimeInterval {
        var time = 0.0
        while time < 1.5, progress(at: time, velocity: velocity) < fraction { time += 1.0 / 240 }
        return time
    }

    /// When the closing chat reaches a button `distance` points narrower than where it started, and how hard.
    static func landing(velocity: CGFloat, distance: CGFloat) -> RouterLanding {
        let delay = time(toCover: 0.86, velocity: velocity)
        let speed = Double(limited(velocity)), decay = exp(-omega * delay)
        // The size's speed as it arrives, in points per second: a throw arrives faster than a tap's close.
        let arriving = (speed + omega * (omega - speed) * delay) * decay * Double(distance)
        return RouterLanding(delay: delay, depth: CGFloat(min(0.13, max(0.1, 0.1 + (arriving - 500) / 8000))))
    }

    /// The share of its move the spring has covered `time` seconds in.
    private static func progress(at time: Double, velocity: CGFloat) -> CGFloat {
        CGFloat(1 - (1 + (omega - Double(limited(velocity))) * time) * exp(-omega * time))
    }

    /// No faster toward the target than a critically damped spring can go without carrying past it, and only a
    /// little away from it: a chat let go while moving toward the button but springing back open first gives way
    /// a few points, as anything moving does, without running off the screen's edge.
    private static func limited(_ velocity: CGFloat) -> CGFloat {
        min(CGFloat(omega), max(-CGFloat(omega) / 2, velocity))
    }
}

/// The closing router chat reaching its button: in `delay` seconds, fast enough to press the button in by `depth`.
struct RouterLanding {
    let delay: TimeInterval
    let depth: CGFloat

    /// The button struck by the chat: it gives at once at the chat's speed, reaches `depth` in about 70 ms, then
    /// springs back past its size and settles. The response of a spring with a 0.35 s response and a 0.45 damping
    /// ratio to a blow, sampled, so its speed never breaks.
    var intake: CAKeyframeAnimation {
        let omega = 2 * Double.pi / 0.35, damping = 0.45, duration = 0.7
        let ringing = omega * (1 - damping * damping).squareRoot()
        // The response's deepest point is 0.512 of its amplitude at this damping.
        let amplitude = Double(depth) / 0.512
        let intake = CAKeyframeAnimation(keyPath: "transform.scale")
        intake.values = stride(from: 0.0, through: duration, by: 1.0 / 120).map { time in
            1 - amplitude * exp(-damping * omega * time) * sin(ringing * time)
        }
        intake.duration = duration
        return intake
    }
}
