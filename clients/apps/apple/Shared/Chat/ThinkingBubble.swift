import SwiftUI

/// Desktop `.comma-chat-thinking-bubble`: a 40pt tailed bubble with the animated Comma mark and a
/// shimmering status line. Its surface breathes (1 → 1.025 over 3.6s) while Comma works.
struct ThinkingBubble: View {
    var label: String = String(localized: "Thinking…")
    var compact = false
    /// The mark redraws itself on a 30 Hz clock; it stops while the bubble is scrolled out of view or covered.
    @State private var onScreen = true
    @Environment(\.ambientMotionPaused) private var motionPaused

    var body: some View {
        HStack(spacing: 6) {
            CommaLogoAnimation(ink: CommaTheme.textPrimary, aperture: CommaTheme.bubbleAssistant,
                               paused: !onScreen || motionPaused)
                .frame(width: 16, height: 16)
            ShimmerText(text: label, font: compact ? .footnote : .subheadline)
                .contentTransition(.opacity)
                .animation(CommaMotion.stateChange, value: label)
        }
        .padding(.horizontal, 13)
        .frame(minHeight: compact ? 34 : 40)
        .background(alignment: .bottomLeading) {
            BreathingBubbleSurface(radius: compact ? 16 : CommaTheme.bubbleRadius)
        }
        .onScrollVisibilityChange(threshold: 0.01) { onScreen = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}

/// Running-status text with the desktop `comma-shiny-text` sweep: a band half the text's width crossing it
/// every 1.6s. Reduce Motion leaves the text still.
struct ShimmerText: View {
    let text: String
    var font: Font = .subheadline
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let label = Text(text).font(font).lineLimit(1)
        label.foregroundStyle(CommaTheme.textQuaternary)
            .overlay { if !reduceMotion { ShimmerSweep().mask(label).allowsHitTesting(false) } }
    }
}

#if os(iOS)
/// The sweep's band, moved by Core Animation.
private struct ShimmerSweep: UIViewRepresentable {
    func makeUIView(context: Context) -> ShimmerSweepView { ShimmerSweepView() }
    func updateUIView(_ view: ShimmerSweepView, context: Context) { view.running = !context.environment.ambientMotionPaused }
}

private final class ShimmerSweepView: RenderLoopView {
    private let band = CAGradientLayer()
    private var sweptWidth: CGFloat = 0
    override var loopLayer: CALayer { band }

    override init(frame: CGRect) {
        super.init(frame: frame)
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
        layer.addSublayer(band)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: ShimmerSweepView, _) in view.paint() }
        paint()
    }

    /// The primary text colour at 55%, fading to nothing on both sides.
    private func paint() {
        let ink = UIColor(CommaTheme.textPrimary).resolvedColor(with: traitCollection)
        band.colors = [0, 0.55, 0].map { ink.withAlphaComponent($0).cgColor }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Half the text's width; at rest it waits off the leading edge.
        band.bounds = CGRect(x: 0, y: 0, width: bounds.width / 2, height: bounds.height)
        band.position = CGPoint(x: -bounds.width * 1.25, y: bounds.midY)
        CATransaction.commit()
        if bounds.width != sweptWidth { sweptWidth = bounds.width; restart() }
    }

    /// From 1.5 widths before the text to 1.5 widths after it.
    override func makeLoop() -> CABasicAnimation? {
        guard bounds.width > 0 else { return nil }
        let sweep = CABasicAnimation(keyPath: "position.x")
        sweep.fromValue = -bounds.width * 1.25
        sweep.toValue = bounds.width * 1.75
        sweep.duration = 1.6
        return sweep
    }
}

/// The thinking bubble's surface, `ChatBubbleSurface` with a leading tail, breathing in the render server.
private struct BreathingBubbleSurface: UIViewRepresentable {
    let radius: CGFloat
    func makeUIView(context: Context) -> BreathingSurfaceView { BreathingSurfaceView() }
    func updateUIView(_ view: BreathingSurfaceView, context: Context) {
        view.radius = radius
        view.running = !context.environment.accessibilityReduceMotion && !context.environment.ambientMotionPaused
    }
}

private final class BreathingSurfaceView: RenderLoopView {
    private let surface = UIView()
    private let tail = UIImageView(image: UIImage(named: "MessageTail")?.withRenderingMode(.alwaysTemplate))
    var radius: CGFloat = 0 { didSet { setNeedsLayout() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        surface.backgroundColor = UIColor(CommaTheme.bubbleAssistant)
        surface.layer.cornerCurve = .continuous
        tail.tintColor = surface.backgroundColor
        tail.transform = CGAffineTransform(scaleX: -1, y: 1)
        addSubview(surface)
        addSubview(tail)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        surface.frame = bounds
        surface.layer.cornerRadius = radius
        // The leading tail: 16×10, 8pt in from the edge, hanging 7pt below.
        tail.bounds = CGRect(x: 0, y: 0, width: 16, height: 10)
        tail.center = CGPoint(x: 16, y: bounds.height + 2)
    }

    /// 1 → 1.025 → 1 over 3.6s on the desktop's ease-in-out curve.
    override func makeLoop() -> CABasicAnimation? {
        let breath = CABasicAnimation(keyPath: "transform.scale")
        breath.fromValue = 1
        breath.toValue = 1.025
        breath.duration = 1.8
        breath.autoreverses = true
        breath.timingFunction = CAMediaTimingFunction(controlPoints: 0.77, 0, 0.175, 1)
        return breath
    }
}
#else
private struct ShimmerSweep: View {
    @State private var phase: CGFloat = -1
    var body: some View {
        GeometryReader { geometry in
            LinearGradient(colors: [.clear, CommaTheme.textPrimary.opacity(0.55), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: geometry.size.width * 0.5)
                .offset(x: phase * geometry.size.width * 1.5)
        }
        .onAppear { withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { phase = 1 } }
    }
}

private struct BreathingBubbleSurface: View {
    let radius: CGFloat
    @State private var breathing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ChatBubbleSurface(fill: CommaTheme.bubbleAssistant, tail: .leading, radius: radius) { Color.clear }
            .scaleEffect(breathing ? 1.025 : 1, anchor: .center)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.timingCurve(0.77, 0, 0.175, 1, duration: 1.8).repeatForever(autoreverses: true)) { breathing = true }
            }
    }
}
#endif
