import AppKit
import QuartzCore
import QuickChatPrivate

/// NameDrop's connection effect, rebuilt from its Core Animation package for
/// the bottom of a Mac screen.
///
/// The package is authored on a 1179 × 2556 canvas (an iPhone at 3×). Here
/// that canvas is drawn at one scale, centered on the Dock with its bottom on
/// the screen's bottom, so every shape and path keeps the phone's proportions.
/// Where the phone's sides would cut the effect off, it eases out instead, so
/// it has no edges of its own.
///
/// Every property follows the package's one spring (mass 2, stiffness 300,
/// damping 50) at the controller's speed 0.7, with a begin time and speed per
/// layer, all at `Tuning.tempo`.
///
/// - `present`: the connection hint. The bottom of the screen dims, softens
///   and is gently lifted, and glows rise from the Dock; it holds.
/// - `send`: the shockwave. A rainbow ridge refracts its way up with a band of
///   blur, the hint sinks away, the scene recoils, settles and clears.
/// - `cancel`: the hint falls back.
@MainActor
final class NameDropEffect {
    /// The study page's sliders as tuned for Quick Chat (1 is the package).
    /// The package's sparks are left out.
    enum Tuning {
        static let exposure = 0.85
        static let dim = 0.80
        /// How far the hint holds the bottom of the screen lifted. It gets
        /// there with the hint's glows rather than creeping up.
        static let lift = 0.15
        static let blur = 1.10
        static let glow: Float = 0.50
        static let mesh = 0.30
        static let ridge: Float = 1.00
        static let refraction = 1.00
        static let recoil = 1.00
        /// The recoil settles after one bounce: its spring's damping ratio
        /// (the package's is 0.245, which rings four times).
        static let recoilDamping = 0.40
        static let chroma = 1.00
        static let tempo = 2.20
        /// How long the wave's light lasts, in seconds. The ridge, its band of
        /// blur and its lights run at the pace that gives it this.
        static let light = 0.5
    }

    /// The wave's pace against the rest of the shockwave: the package's
    /// rainbow is down to a tenth 0.99 seconds into its timeline.
    nonisolated fileprivate static let rise = 0.99 / (Tuning.light * Tuning.tempo)

    /// Containers are transform layers: they do not flatten their sublayers,
    /// so plusL, colorDodge and multiply still blend with the windows behind.
    /// Inside a plain CALayer those blend with the container's own clear
    /// pixels instead (black and white boxes). A transform layer's opacity
    /// must not animate either: the window server then composites its
    /// sublayers another way and their light jumps. Fades go on the sublayers.
    let layer = CATransformLayer()

    /// Shockwave meshes per second; the window server interpolates between them.
    private static let meshRate = 60.0

    /// From the shockwave's start until everything is gone.
    static let sendDuration = (2.48 + 1.5) / Tuning.tempo
    static let cancelDuration = 0.8 / Tuning.tempo

    /// How dark the hint holds the screen: the package's half dim over a
    /// wallpaper at `Tuning.exposure`.
    private static let holdDarkness = 1 - Tuning.exposure * (1 - 0.5 * Tuning.dim)

    /// The package blurs by 8 canvas units (a gaussian's σ) where its mask
    /// is full: a softening, not frosted glass. A variable blur's σ is twice
    /// its radius, a gaussian blur's equals it.
    private var blurSigma: CGFloat { 8 * stage.scale }

    /// The lift arrives as fast as the hint's edge rises.
    private static let liftSpeed = 0.936

    private let textures = NameDropTextures()
    private var stage = Stage(rect: .zero)
    private var field = Field(widthRatio: 1, reach: 1)
    private var presentedAt: CFTimeInterval = 0

    /// The screen behind the hint, blurred and lifted; the shockwave's
    /// refraction and recoil are drawn on its mesh.
    private let backdrop = CoreAnimationPrivate.backdropLayer()
    private let backdropFade = CALayer()
    /// The band of blur and color fringes the ridge carries up. It samples
    /// the backdrop below it, refraction included.
    private let ridgeBand = CoreAnimationPrivate.backdropLayer()
    private let ridgeBandMask = CALayer()
    private let dimmer = CALayer()
    private let hintContainer = CATransformLayer()
    private let hintGlow = CALayer()
    private let smallGlow = CALayer()
    private let voiceGlow = CALayer()
    private let hintSheen = CALayer()
    private let circleGlow = CALayer()
    private let rainbow = CALayer()
    private let darkArc = CALayer()
    private let ridgeGlow = CALayer()
    private let shockSheen = CALayer()

    init() {
        // Half a pixel per point: what they show is mostly blurred, and the
        // window server samples and blurs it again whenever what is behind changes.
        for sampler in [backdrop, ridgeBand] {
            sampler.setValue(0.5, forKey: "scale")
        }
        backdrop.mask = backdropFade
        ridgeBand.mask = ridgeBandMask

        for (glow, image) in [
            (hintGlow, textures.glow), (smallGlow, textures.glow), (voiceGlow, textures.glow),
            (hintSheen, textures.sheen), (circleGlow, textures.circle), (ridgeGlow, textures.glow),
            (shockSheen, textures.paleSheen),
        ] {
            glow.contents = image
            glow.compositingFilter = "plusL"
        }
        rainbow.contents = textures.rainbowArc
        rainbow.compositingFilter = "colorDodgeBlendMode"
        rainbow.filters = [CoreAnimationPrivate.filter("gaussianBlur", ["inputRadius": 0])]
        darkArc.contents = textures.darkArc
        darkArc.compositingFilter = "multiplyBlendMode"
        hintContainer.addSublayer(hintSheen)
        hintContainer.addSublayer(hintGlow)
        hintContainer.addSublayer(smallGlow)
        hintContainer.addSublayer(voiceGlow)

        // The package's order: the screen, its dim, the shockwave's lights,
        // then the hint's glows on top.
        for child in [
            backdrop, ridgeBand, dimmer,
            circleGlow, rainbow, darkArc, ridgeGlow, shockSheen, hintContainer,
        ] {
            layer.addSublayer(child)
        }
        reset()
    }

    /// `bounds` is the overlay (the whole screen, y up); `stageWidth` is how
    /// wide the package's canvas is drawn, centered on the Dock.
    func layout(overlay bounds: CGRect, stageWidth: CGFloat) {
        let scale = stageWidth / 1179
        stage = Stage(rect: CGRect(
            x: (bounds.width - stageWidth) / 2, y: 0, width: stageWidth, height: 2556 * scale
        ))
        // The backdrop covers what the blur and the meshes move; the dim
        // reaches a little wider and higher.
        let backdropArea = area(in: bounds, halfWidth: Field.reachAcross, height: Field.reachUp)
        let dimArea = area(in: bounds, halfWidth: Field.dimAcross, height: Field.dimUp)
        field = Field(
            widthRatio: Double(stageWidth / backdropArea.width),
            reach: Double(backdropArea.height / stage.rect.height)
        )
        withoutActions {
            layer.frame = bounds
            backdrop.frame = backdropArea
            backdrop.filters = [
                CoreAnimationPrivate.filter("variableBlur", [
                    "inputRadius": 0,
                    "inputMaskImage": field.blurMask(),
                    "inputNormalizeEdges": true,
                ]),
            ]
            // It meets the screen where the effect has died out, through a short fade.
            backdropFade.frame = backdrop.bounds
            backdropFade.contents = Self.coverage(width: 64, height: 64, gray: 1) { x, y in
                (1 - Self.smoothstep(0.93, 1, y)) * (1 - Self.smoothstep(0.93, 1, abs(x - 0.5) * 2))
            }

            ridgeBand.bounds.size = CGSize(width: backdropArea.width, height: stage.rect.height * Field.ridgeBandSpan)
            ridgeBand.position = CGPoint(x: backdropArea.midX, y: 0)
            ridgeBand.filters = [
                CoreAnimationPrivate.filter("chromaticAberration", [
                    "inputRedOffset": NSValue(point: .zero),
                    "inputGreenOffset": NSValue(point: .zero),
                    "inputBlueOffset": NSValue(point: .zero),
                ]),
                CoreAnimationPrivate.filter("gaussianBlur", [
                    "inputRadius": blurSigma,
                    "inputNormalizeEdges": true,
                ]),
            ]
            ridgeBandMask.frame = ridgeBand.bounds
            ridgeBandMask.contents = field.ridgeBandMask()

            dimmer.frame = dimArea
            let dimWidthRatio = Double(stageWidth / dimArea.width)
            let dimReach = Double(dimArea.height / stage.rect.height)
            dimmer.contents = Self.coverage(width: 64, height: 64, gray: 0) { x, y in
                Field.dimShape(across: (x - 0.5) * 2 / dimWidthRatio, up: y * dimReach)
            }

            // The frame setter honors the transform a send or cancel left behind.
            hintContainer.removeAllAnimations()
            hintContainer.transform = CATransform3DIdentity
            hintContainer.frame = bounds
            hintGlow.bounds.size = stage.size(1130, 391, scale: 2.64)
            hintGlow.position = stage.point(589, 2532.5)
            smallGlow.bounds.size = stage.size(648, 391, scale: 1.98)
            smallGlow.position = stage.point(589, 2509.5)
            voiceGlow.bounds.size = stage.size(560, 300, scale: 1.4)
            voiceGlow.position = stage.point(589, 2556)
            hintSheen.bounds.size = stage.size(1346, 1600, scale: 1.89)
            // Two of the light's 250-unit radii each way.
            circleGlow.bounds.size = stage.size(1000, 1000, scale: 1)
            circleGlow.position = stage.point(589.5, 2768)
            rainbow.bounds.size = stage.size(795, 398, scale: 1)
            darkArc.bounds.size = stage.size(795, 398, scale: 1)
            ridgeGlow.bounds.size = stage.size(413, 165, scale: 1)
            shockSheen.bounds.size = stage.size(1130, 391, scale: 4.47)
        }
        reset()
    }

    /// Centered on the stage, from the screen's bottom: `halfWidth` in the
    /// canvas's half-widths, `height` in its heights.
    private func area(in bounds: CGRect, halfWidth: Double, height: Double) -> CGRect {
        let half = min(bounds.width / 2, stage.rect.width / 2 * halfWidth)
        return CGRect(x: bounds.midX - half, y: 0, width: half * 2, height: stage.rect.height * height)
    }

    /// Hides everything, as before the first frame of the hint.
    private func reset() {
        withoutActions {
            for child in [hintGlow, smallGlow, voiceGlow, hintSheen] + (layer.sublayers ?? []) {
                child.removeAllAnimations()
            }
            backdrop.setValue(0, forKeyPath: "filters.variableBlur.inputRadius")
            backdrop.setValue(field.still, forKey: "meshTransform")
            backdrop.opacity = 1
            ridgeBand.opacity = 0
            dimmer.opacity = 0
            hintContainer.transform = CATransform3DIdentity
            for glow in [hintGlow, smallGlow, voiceGlow, hintSheen] { glow.opacity = 0 }
            hintSheen.position = stage.point(589, 694.5)
            for shock in [circleGlow, rainbow, darkArc, ridgeGlow, shockSheen] { shock.opacity = 0 }
        }
    }

    // MARK: Phases

    func present() {
        reset()
        let base = CACurrentMediaTime()
        presentedAt = base
        animate(backdrop, "meshTransform", from: field.still, to: field.lift(Tuning.lift), speed: Self.liftSpeed, base: base)
        animate(backdrop, "filters.variableBlur.inputRadius", from: 0, to: blurSigma / 2, speed: 0.64, base: base)
        animate(dimmer, "opacity", from: 0, to: Self.holdDarkness, speed: 0.40, base: base)
        animate(hintGlow, "opacity", from: 0, to: 0.346357 * Tuning.glow, speed: 0.76, base: base)
        animate(smallGlow, "opacity", from: 0, to: 0.75 * Tuning.glow, speed: 0.592, base: base)
        animate(hintSheen, "opacity", from: 0, to: 0.40 * Tuning.glow, speed: 0.596, base: base)
        animate(hintSheen, "position.y", from: stage.point(589, 694.5).y,
                to: stage.point(589, 2385.5).y, speed: 0.602, base: base)
    }

    /// The voice's loudness, 0…1, already smoothed; brightens the glow at the Dock.
    func setVoiceLevel(_ level: CGFloat) {
        withoutActions { voiceGlow.opacity = Float(level) * 0.55 * Tuning.glow }
    }

    func send() {
        // The backdrop: the lift releases while the ridge refracts its way up
        // and the scene recoils, sampled for the window server to play; it
        // ends unwarped. It is computed before the wave's clock starts, so no
        // animation begins part way through.
        let lifted = Tuning.lift * Self.spring((CACurrentMediaTime() - presentedAt) * Tuning.tempo, speed: Self.liftSpeed)
        let meshes = (0...Int((Self.sendDuration * Self.meshRate).rounded(.up))).map { frame in
            field.shock(time: Double(frame) / Self.meshRate * Tuning.tempo, lifted: lifted)
        }
        let base = CACurrentMediaTime()
        let voice = Double(voiceGlow.presentation()?.opacity ?? voiceGlow.opacity)
        fade(voiceGlow, base: base) { t in voice * (1 - Self.smoothstep(0, 0.2, t)) }

        withoutActions { backdrop.setValue(field.still, forKey: "meshTransform") }
        keyframes(backdrop, "meshTransform", base: base, values: meshes, fill: false)
        animate(backdrop, "filters.variableBlur.inputRadius", to: 0, speed: 1.0, base: base)
        // Its half-resolution copy of the screen goes with the recoil, so the
        // screen is sharp again before the overlay closes.
        fade(backdrop, base: base) { t in (1 - Self.cleanup(t)) * Self.removal(t) }

        // The wave's springs run `rise` times faster: speeds × rise, begin times ÷ rise.
        let rise = Self.rise

        // The ridge's band of blur and fringes, riding up with its refraction.
        let ridgeY = { (phoneY: Double) in self.stage.rect.minY + CGFloat(phoneY) * self.stage.rect.height }
        animate(ridgeBand, "position.y", from: ridgeY(Field.ridgeFrom), to: ridgeY(Field.ridgeTo),
                speed: 1.068 * rise, begin: 0.105 / rise, base: base)
        fade(ridgeBand, base: base) { t in
            min(1, 0.875 * Tuning.blur) * (1 - Self.spring(t * rise, begin: 0.13, speed: 0.46)) * Self.removal(t)
        }
        let fringe = 0.858 * 0.0026 * Tuning.chroma * Tuning.refraction * Double(stage.rect.height)
        for (keyPath, sign) in [("inputRedOffset", 1.0), ("inputBlueOffset", -1.0)] {
            keyframes(ridgeBand, "filters.chromaticAberration.\(keyPath)", base: base, values: Self.samples { t in
                NSValue(point: CGPoint(x: 0, y: sign * fringe * Field.ridgePresence(t * rise)))
            })
        }

        // The hint resets and its glows sink away below the screen.
        animate(hintContainer, "transform.translation.y", to: -1703 * stage.scale, speed: 0.30, base: base)
        animate(hintSheen, "position.y", to: stage.point(589, 2263.81).y, speed: 1.0, base: base)

        // The dim deepens to full, lightens behind the wave, then lifts.
        let held = Double(dimmer.presentation()?.opacity ?? dimmer.opacity) / Self.holdDarkness
        fade(dimmer, base: base) { t in
            let on = max(held, Self.spring(t, speed: 1.10)) * (1 - Self.cleanup(t)) * Self.removal(t)
            let dim = (0.5 + (0.123 - 0.5) * Self.spring(t, begin: 0.36, speed: 0.5)) * on * Tuning.dim
            return 1 - (1 - (1 - Tuning.exposure) * on) * (1 - min(1, dim))
        }

        // The light that blooms from the bottom edge. The package switches the
        // shockwave's lights on at full in its first frame; they come up over
        // a few frames here, so the wave starts without a flash.
        fade(circleGlow, base: base) { t in
            0.681387 * Double(Tuning.ridge) * Self.rampIn(t * rise)
                * (1 - Self.spring(t * rise, begin: 0.105, speed: 0.652))
        }
        animate(circleGlow, "transform.scale", from: 0.81, to: 4.53, speed: 1.0 * rise, begin: 0.105 / rise, base: base)

        // The eclipse: a rainbow arc dodging what is behind, over a dark arc.
        animate(rainbow, "position", from: stage.point(589.5, 2612), to: stage.point(575.5, 1908),
                speed: 1.0 * rise, begin: 0.105 / rise, base: base)
        animate(rainbow, "transform.scale", from: 0.72, to: 4.14, speed: 1.0 * rise, begin: 0.105 / rise, base: base)
        fade(rainbow, base: base) { t in
            Double(Tuning.ridge) * Self.rampIn(t * rise) * (1 - Self.spring(t * rise, begin: 0.15, speed: 0.652))
        }
        animate(rainbow, "filters.gaussianBlur.inputRadius", from: 0, to: 5 * stage.scale,
                speed: 1.0 * rise, begin: 0.25 / rise, base: base)
        animate(darkArc, "position", from: stage.point(589.5, 2612), to: stage.point(589.5, 1635),
                speed: 1.044 * rise, begin: 0.105 / rise, base: base)
        animate(darkArc, "transform.scale", from: 0.72, to: 4.14, speed: 1.0 * rise, begin: 0.105 / rise, base: base)
        fade(darkArc, base: base) { t in
            Double(Tuning.ridge) * Self.rampIn(t * rise) * (1 - Self.spring(t * rise, begin: 0.15, speed: 0.652))
        }

        // The ridge's own light and its chromatic sheen. Lights that rise are
        // gone before they arrive, so none stops against anything.
        animate(ridgeGlow, "position", from: stage.point(589.5, 2866.5), to: stage.point(589.5, 1572.5),
                speed: 0.828 * rise, begin: 0.105 / rise, base: base)
        withoutActions { ridgeGlow.transform = CATransform3DMakeScale(8.54, 5.92, 1) }
        fade(ridgeGlow, base: base) { t in
            0.629671 * Double(Tuning.ridge) * Self.rampIn(t * rise)
                * (1 - Self.spring(t * rise, begin: 0.105, speed: 0.808))
                * Self.goneBefore(Self.spring(t * rise, begin: 0.105, speed: 0.828))
        }
        animate(shockSheen, "position", from: stage.point(589, 1794.5), to: stage.point(589, 1243.5),
                speed: 1.0 * rise, begin: 0.26 / rise, base: base)
        fade(shockSheen, base: base) { t in
            0.5 * Double(Tuning.ridge) * Self.spring(t * rise, begin: 0.105, speed: 1.0)
                * (1 - Self.spring(t * rise, begin: 0.315, speed: 0.5))
                * Self.goneBefore(Self.spring(t * rise, begin: 0.26, speed: 1.0))
        }

        // The hint's glows are gone part way down.
        for glow in [hintGlow, smallGlow, hintSheen] {
            let level = Double(glow.presentation()?.opacity ?? glow.opacity)
            fade(glow, base: base) { t in level * (1 - Self.smoothstep(0.1, 0.6, Self.spring(t, speed: 0.30))) }
        }
    }

    func cancel() {
        let base = CACurrentMediaTime()
        for (child, keyPath) in [
            (dimmer, "opacity"), (hintGlow, "opacity"), (smallGlow, "opacity"),
            (voiceGlow, "opacity"), (hintSheen, "opacity"),
        ] {
            animate(child, keyPath, to: 0, speed: 1.4, base: base)
        }
        animate(backdrop, "filters.variableBlur.inputRadius", to: 0, speed: 1.4, base: base)
        animate(backdrop, "meshTransform", to: field.still, speed: 1.4, base: base)
        animate(backdrop, "opacity", to: 0, speed: 1.4, base: base)
        animate(hintContainer, "transform.translation.y", to: -40 * stage.scale, speed: 1.4, base: base)
    }

    // MARK: Pieces

    /// A `gray` image whose alpha is `alpha(x, y)`, x and y running 0…1 from
    /// the left and the bottom.
    nonisolated fileprivate static func coverage(
        width: Int, height: Int, gray: Double, _ alpha: (Double, Double) -> Double
    ) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            let y = 1 - (Double(row) + 0.5) / Double(height)
            for column in 0..<width {
                let x = (Double(column) + 0.5) / Double(width)
                let a = max(0, min(1, alpha(x, y)))
                let offset = (row * width + column) * 4
                let value = UInt8((gray * a * 255).rounded())
                bytes[offset] = value
                bytes[offset + 1] = value
                bytes[offset + 2] = value
                bytes[offset + 3] = UInt8((a * 255).rounded())
            }
        }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!,
            decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )!
    }

    nonisolated fileprivate static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = max(0, min(1, (x - edge0) / (edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }

    // MARK: Springs

    /// The package's spring, as a value: 0 at `begin`, settling at 1. `time`
    /// is on the package's timeline (seconds × `Tuning.tempo`).
    nonisolated fileprivate static func spring(_ time: Double, begin: Double = 0, speed: Double) -> Double {
        let local = max(time - begin, 0) * 0.7 * speed
        return max(0, min(1, 1 - 3 * exp(-10 * local) + 2 * exp(-15 * local)))
    }

    /// The package's underdamped spring (the recoil's bounce), its natural
    /// frequency kept and its damping ratio `Tuning.recoilDamping`.
    nonisolated fileprivate static func bounce(_ time: Double, begin: Double = 0, speed: Double) -> Double {
        let local = max(time - begin, 0) * 0.7 * speed
        let natural = 12.24745, damping = Tuning.recoilDamping
        let decay = damping * natural, frequency = natural * (1 - damping * damping).squareRoot()
        return 1 - exp(-decay * local) * (cos(frequency * local) + decay / frequency * sin(frequency * local))
    }

    /// The settling ends: the scene clears from 2.48 seconds in.
    nonisolated fileprivate static func cleanup(_ time: Double) -> Double {
        time < 2.48 ? 0 : spring(time - 2.48, speed: 0.342)
    }

    /// What is left goes over the package's last 0.2 seconds.
    nonisolated private static func removal(_ time: Double) -> Double {
        1 - smoothstep(2.48 + 1.3, 2.48 + 1.5, time)
    }

    /// A rising light's share by how far it has come: gone by 85% of the way.
    nonisolated private static func goneBefore(_ travel: Double) -> Double {
        1 - smoothstep(0.5, 0.85, travel)
    }

    /// The package's lights come up over 0.12 seconds of its timeline.
    nonisolated private static func rampIn(_ time: Double) -> Double {
        smoothstep(0, 0.12, time)
    }

    /// `value(t)` at 60 per second over the shockwave, t on the package's timeline.
    private static func samples<Value>(_ value: (Double) -> Value) -> [Value] {
        (0...Int((sendDuration * 60).rounded(.up))).map { value(Double($0) / 60 * Tuning.tempo) }
    }

    /// Opacity following `value(t)` for the shockwave's whole run.
    private func fade(_ target: CALayer, base: CFTimeInterval, _ value: (Double) -> Double) {
        let values = Self.samples { Float(value($0)) }
        withoutActions { target.opacity = values.last ?? 0 }
        keyframes(target, "opacity", base: base, values: values)
    }

    /// `values` spread evenly over the shockwave from `base`. With `fill`,
    /// the first holds before and the last after.
    private func keyframes(_ target: CALayer, _ keyPath: String, base: CFTimeInterval, values: [Any], fill: Bool = true) {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.duration = Self.sendDuration
        animation.beginTime = base
        animation.calculationMode = .linear
        if fill {
            animation.fillMode = .both
            animation.isRemovedOnCompletion = false
        }
        target.add(animation, forKey: keyPath)
    }

    /// The package's spring on `keyPath`, `begin` seconds of its timeline
    /// after `base`, at `speed` × `Tuning.tempo`.
    private func animate(
        _ target: CALayer,
        _ keyPath: String,
        from: Any? = nil,
        to value: Any,
        speed: Double,
        begin: Double = 0,
        base: CFTimeInterval
    ) {
        let animation = CASpringAnimation(keyPath: keyPath)
        animation.mass = 2
        animation.stiffness = 300
        animation.damping = 50
        animation.fromValue = from ?? target.presentation()?.value(forKeyPath: keyPath)
            ?? target.value(forKeyPath: keyPath)
        animation.toValue = value
        animation.speed = Float(0.7 * speed * Tuning.tempo)
        animation.duration = animation.settlingDuration
        animation.beginTime = base + begin / Tuning.tempo
        animation.fillMode = .backwards
        withoutActions { target.setValue(value, forKeyPath: keyPath) }
        target.add(animation, forKey: keyPath)
    }

    private func withoutActions(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}

/// The package's 1179 × 2556 canvas on the screen, at one scale.
private struct Stage {
    var rect: CGRect
    var scale: CGFloat { rect.width / 1179 }

    /// A canvas point (y down from the canvas top) in the overlay's coordinates (y up).
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: rect.minX + x * scale, y: rect.minY + (2556 - y) * scale)
    }

    func size(_ width: CGFloat, _ height: CGFloat, scale layerScale: CGFloat) -> CGSize {
        CGSize(width: width * layerScale * scale, height: height * layerScale * scale)
    }
}

/// Where the effect reaches and how its displacement moves the screen: the
/// package's formulas in the phone's units (x -1…1 across the canvas, y 0…1
/// up it), drawn as meshes over the backdrop. Each grid point shows the
/// content its displacement points to.
private struct Field {
    /// The shockwave's grid is fine enough for the ridge; the lift is smooth
    /// and its grid coarse, which keeps the held backdrop cheap to redraw.
    static let ridgeGrid = (columns: 24, rows: 48)
    static let liftGrid = (columns: 8, rows: 12)

    /// The backdrop: out to where the strength is gone (in the canvas's
    /// half-widths) and up past the blur's soft top (in its heights).
    static let reachAcross = 1.36
    static let reachUp = 0.63
    /// The dim reaches a little wider and higher than the blur.
    static let dimAcross = 1.6
    static let dimUp = 0.66

    /// The ridge's refraction runs from below the screen to a third of the way up.
    static let ridgeFrom = -0.18
    static let ridgeTo = 0.34
    /// The band of blur around the ridge, in canvas heights.
    static let ridgeBandSpan = 1.0

    /// The stage's width over the backdrop's.
    let widthRatio: Double
    /// The backdrop's height over the canvas's.
    let reach: Double
    /// No displacement, on the lift's grid.
    let still: AnyObject

    init(widthRatio: Double, reach: Double) {
        self.widthRatio = widthRatio
        self.reach = reach
        still = Self.mesh(Self.liftGrid, widthRatio: widthRatio, reach: reach) { _, _ in (0, 0) }
    }

    /// How much of the effect applies at `x`: all of it across the middle of
    /// the canvas, easing out past its sides where the phone would end.
    static func strength(across x: Double) -> Double {
        1 - NameDropEffect.smoothstep(0.25, 1.3, abs(x))
    }

    /// The dim's alpha: the package dims the whole phone; here it eases out
    /// above the effect and past the canvas's sides.
    static func dimShape(across x: Double, up y: Double) -> Double {
        (1 - NameDropEffect.smoothstep(0.40, 0.64, y)) * (1 - NameDropEffect.smoothstep(0.4, 1.6, abs(x)))
    }

    /// The hint's blur: full up to its boundary, 0.44 of the way up and
    /// curving up to the sides, then soft above it.
    func blurMask() -> CGImage {
        NameDropEffect.coverage(width: 64, height: 128, gray: 1) { u, v in
            let x = (u - 0.5) * 2 / self.widthRatio
            let y = v * self.reach
            let boundary = 0.44 + 0.020 * x * x
            let mask = 1 - NameDropEffect.smoothstep(boundary - 0.055, boundary + 0.13, y)
            return min(1, mask * NameDropEffect.Tuning.blur) * Self.strength(across: x)
        }
    }

    /// The ridge band's alpha around its center: the ridge's body, curving up to the sides.
    func ridgeBandMask() -> CGImage {
        NameDropEffect.coverage(width: 64, height: 128, gray: 1) { u, v in
            let x = (u - 0.5) * 2 / self.widthRatio
            let curve = min(abs(x), 1)
            let distance = (v - 0.5) * Self.ridgeBandSpan - 0.045 * curve * curve
            return exp(-pow(distance / 0.17, 2)) * Self.strength(across: x)
        }
    }

    /// The ridge's refraction fades as it travels; `time` is the wave's.
    nonisolated static func ridgePresence(_ time: Double) -> Double {
        1 - NameDropEffect.spring(time, begin: 0.105, speed: 0.46)
    }

    /// The hint's "stretch up mesh": the bottom 1243.55 units are sampled
    /// from above, magnified, more at the very bottom; `stretch` of it.
    func lift(_ stretch: Double) -> AnyObject {
        Self.mesh(Self.liftGrid, widthRatio: widthRatio, reach: reach) { x, y in
            (0, Self.lift(y, stretch: stretch) * Self.strength(across: x))
        }
    }

    /// The shockwave at `time` on the package's timeline: the lift releasing
    /// from `lifted`, the ridge refracting upward, then the recoil.
    func shock(time t: Double, lifted: Double) -> AnyObject {
        let spring = NameDropEffect.spring
        let tuning = NameDropEffect.Tuning.self
        let stretch = lifted * (1 - spring(t, 0, 1.0))
        let wave = t * NameDropEffect.rise
        let meshCenter = Self.ridgeFrom + (Self.ridgeTo - Self.ridgeFrom) * spring(wave, 0.105, 1.068)
        let meshPresence = Self.ridgePresence(wave)
        let recoilCenter = 0.12 + 0.16 * NameDropEffect.bounce(t, begin: 0.105, speed: 0.70)
            + 0.035 * spring(t, 0.105, 0.30)
        let recoilPresence = spring(t, 0.105, 3.0) * (1 - NameDropEffect.cleanup(t))
        return Self.mesh(Self.ridgeGrid, widthRatio: widthRatio, reach: reach) { x, y in
            let across = x.clamped(to: -1...1)
            let curve = abs(across)
            let normal = Self.normalize(-0.09 * across, 1)
            let meshDistance = y - (meshCenter + 0.045 * curve * curve)
            let meshQ = meshDistance / 0.090
            let meshDerivative = -2 * meshQ * exp(-meshQ * meshQ)
            let meshBody = exp(-pow(meshDistance / 0.17, 2))
            let recoilQ = (y - (recoilCenter + 0.030 * curve * curve)) / 0.085
            let recoilDerivative = -2 * recoilQ * exp(-recoilQ * recoilQ)
            let lens = meshDerivative * 0.010 * tuning.refraction * meshPresence
                + meshBody * 0.0035 * tuning.mesh * meshPresence
                + recoilDerivative * 0.0035 * tuning.recoil * recoilPresence
            let dx = normal.x * lens - 0.10 * across * curve * meshBody * tuning.mesh * meshPresence
            let strength = Self.strength(across: x)
            return (dx * strength, (normal.y * lens + Self.lift(y, stretch: stretch)) * strength)
        }
    }

    private static func lift(_ y: Double, stretch: Double) -> Double {
        let span = 1243.55 / 2556
        let depth = max(0, min(1, (span - y) / span))
        let ratio = 0.25 + 0.09 * NameDropEffect.smoothstep(0.75, 1, depth)
        return depth * ratio * span * stretch
    }

    private static func normalize(_ x: Double, _ y: Double) -> (x: Double, y: Double) {
        let length = (x * x + y * y).squareRoot()
        return (x / length, y / length)
    }

    /// `displacement(x, y)` is in the phone's units: x -1…1 across the canvas
    /// (beyond it at the backdrop's sides), y 0…1 up it; it returns how far to
    /// sample, x in canvas widths and y in canvas heights.
    private static func mesh(
        _ grid: (columns: Int, rows: Int),
        widthRatio: Double,
        reach: Double,
        _ displacement: (Double, Double) -> (Double, Double)
    ) -> AnyObject {
        var sources: [CGPoint] = []
        sources.reserveCapacity((grid.columns + 1) * (grid.rows + 1))
        for row in 0...grid.rows {
            let v = Double(row) / Double(grid.rows)
            for column in 0...grid.columns {
                let u = Double(column) / Double(grid.columns)
                let (dx, dy) = displacement((u - 0.5) * 2 / widthRatio, v * reach)
                sources.append(CGPoint(
                    x: (u + dx * widthRatio).clamped(to: 0...1),
                    y: (v + dy / reach).clamped(to: 0...1)
                ))
            }
        }
        return QCMeshTransform(grid.columns, grid.rows, sources) as AnyObject
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
