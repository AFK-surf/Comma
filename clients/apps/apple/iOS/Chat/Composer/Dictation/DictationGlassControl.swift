import MetalKit
import SwiftUI
import UIKit

/// The composer's microphone, and the waveform that fills the composer while it records. A tap on the microphone
/// starts a recording that a tap anywhere on the composer ends; holding the microphone records until the finger
/// lifts. Transcribing, the microphone is a spinner and the row says so.
///
/// While dictating, the composer holds its collapsed one-row glass capsule (`ConversationComposer`), and this view
/// lies over it at the same size. The waveform is drawn by Metal (`DictationWaveformRenderer`) straight onto that
/// glass: no second glass. Where the bars reach the capsule's round ends, the shader bends them as the system
/// glass's rim bends what lies under it, and splits their colours.
///
/// Cost while recording: one Metal draw a frame at up to 60 fps, nothing in SwiftUI; otherwise nothing at all.
final class DictationGlassControl: UIView {
    /// The model's phase as the composer last rendered it.
    var phase: DictationModel.Phase = .idle {
        didSet { if phase != oldValue { phaseChanged(from: oldValue) } }
    }
    /// Starts a recording, or ends the one under way.
    var toggle: () -> Void = {}
    var level: () -> CGFloat = { 0 } {
        didSet { renderer?.level = level }
    }

    /// A press held at least this long ends the recording when it lifts; a shorter one is a tap.
    private static let holdThreshold: CFTimeInterval = 0.35

    private let mic = UIImageView(image: UIImage(named: "central-microphone")?.withRenderingMode(.alwaysTemplate))
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let label = UILabel()
    private var waveform: MTKView?
    private var renderer: DictationWaveformRenderer?
    /// When the press began, on the touches' clock (`UITouch.timestamp`).
    private var pressStart: TimeInterval?
    /// This press started the recording, so lifting it after a hold ends it.
    private var pressStarted = false
    private let haptic = UIImpactFeedbackGenerator(style: .medium)

    override init(frame: CGRect) {
        super.init(frame: frame)
        mic.tintColor = UIColor(CommaTheme.textPrimary)
        mic.contentMode = .scaleAspectFit
        spinner.hidesWhenStopped = true
        label.text = String(localized: "Transcribing…")
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = UIColor(CommaTheme.textTertiary)
        label.alpha = 0
        addSubview(label)
        addSubview(mic)
        addSubview(spinner)
        DictationWaveformRenderer.make { [weak self] device, renderer in self?.install(device: device, renderer: renderer) }
        isAccessibilityElement = true
        accessibilityTraits = .button
        updateAccessibility()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in self.renderer?.traits = self.traitCollection }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The waveform, once its shader is compiled. Without Metal the composer records with no waveform.
    private func install(device: MTLDevice, renderer: DictationWaveformRenderer) {
        let view = MTKView(frame: bounds, device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isUserInteractionEnabled = false
        view.delegate = renderer
        renderer.level = level
        renderer.traits = traitCollection
        let recording = phase == .recording
        view.isPaused = !recording
        view.isHidden = !recording
        if recording { renderer.reset() }
        insertSubview(view, at: 0)
        waveform = view
        self.renderer = renderer
    }

    // MARK: Layout

    /// The microphone's 44pt corner, just before Send.
    private var micSlot: CGRect { CGRect(x: bounds.width - 88, y: bounds.height - 44, width: 44, height: 44) }

    override func layoutSubviews() {
        super.layoutSubviews()
        mic.frame = CGRect(origin: .zero, size: CGSize(width: 20, height: 20))
        mic.center = CGPoint(x: micSlot.midX, y: micSlot.midY)
        // Transcribing, Send is hidden, so the spinner takes the row's last corner.
        spinner.center = CGPoint(x: bounds.width - 22, y: bounds.height - 22)
        label.frame = CGRect(x: 16, y: bounds.height - 44, width: max(0, bounds.width - 60), height: 44)
        // The waveform is the composer's capsule: the bottom 44pt row, end to end.
        waveform?.frame = CGRect(x: 0, y: bounds.height - 44, width: bounds.width, height: 44)
    }

    // MARK: Phase

    private func phaseChanged(from old: DictationModel.Phase) {
        updateAccessibility()
        let recording = phase == .recording
        renderer?.traits = traitCollection
        if recording {
            haptic.impactOccurred()
            renderer?.reset()
            waveform?.alpha = 0
            waveform?.isHidden = false
            // The view still holds the last recording's final frame: draw this one's first before it shows.
            waveform?.draw()
            waveform?.isPaused = false
        } else if old == .recording {
            haptic.impactOccurred(intensity: 0.6)
        }
        // The note goes at once: the composer opens out as the words arrive, and their text takes its row.
        if phase == .idle { label.alpha = 0 }
        UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.waveform?.alpha = recording ? 1 : 0
            self.mic.alpha = self.phase == .idle ? 1 : 0
            self.label.alpha = self.phase == .transcribing ? 1 : 0
        } completion: { [weak self] _ in
            // Off screen it draws nothing.
            guard let self, self.phase != .recording else { return }
            self.waveform?.isPaused = true
            self.waveform?.isHidden = true
        }
        if phase == .transcribing { spinner.startAnimating() } else { spinner.stopAnimating() }
    }

    // MARK: Touches

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        // Recording, the whole capsule ends it; otherwise only the microphone answers.
        phase == .recording ? bounds.contains(point) : micSlot.contains(point)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard phase != .transcribing else { return }
        // The touch's own time, not the time it is handled: the keyboard going down as the composer collapses can
        // hold the main thread long enough to make a tap read as a hold.
        pressStart = touches.first?.timestamp ?? ProcessInfo.processInfo.systemUptime
        pressStarted = phase == .idle
        if pressStarted { toggle() }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        release(at: touches.first?.timestamp, cancelled: false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        release(at: touches.first?.timestamp, cancelled: true)
    }

    private func release(at time: TimeInterval?, cancelled: Bool) {
        guard let start = pressStart else { return }
        pressStart = nil
        let held = (time ?? ProcessInfo.processInfo.systemUptime) - start >= Self.holdThreshold
        // A hold ends what it started; a tap leaves the recording running for a tap on the capsule.
        if phase == .recording && (pressStarted ? held : !cancelled) { toggle() }
        pressStarted = false
    }

    // MARK: Accessibility

    private func updateAccessibility() {
        switch phase {
        case .idle: accessibilityLabel = String(localized: "Dictate message")
        case .recording: accessibilityLabel = String(localized: "Stop dictation")
        case .transcribing: accessibilityLabel = String(localized: "Transcribing…")
        }
        accessibilityIdentifier = "dictateMessage"
    }

    override func accessibilityActivate() -> Bool {
        guard phase != .transcribing else { return false }
        toggle()
        return true
    }
}

/// Draws the waveform each frame. The row starts full of faint resting bars, which hold no level and need no slots.
/// Bars enter on a clock of their own at the trailing end, with the level heard since the last one, and the strip
/// moves left at a steady speed, so they push the resting bars out; the shader does the rest.
///
/// Bounds: one bar every `interval`, at most `slots` bars kept, one draw call a frame.
final class DictationWaveformRenderer: NSObject, MTKViewDelegate {
    var level: () -> CGFloat = { 0 }
    var traits = UITraitCollection.current

    /// Enough for the widest window, 2,816pt of strip, and within the 4 KB of `setFragmentBytes`.
    private static let slots = 512
    private static let barWidth: Float = 2.5
    private static let step: Float = 5.5
    /// A bar's time on the row: the strip moves `step` points in this long, so 50pt a second.
    private static let interval: Double = 0.11
    /// Seconds a bar takes to reach its level.
    private static let grow: Float = 0.7
    private static let tallest: CGFloat = 26
    /// The opacity of the bars the row starts with. Bars that enter later are opaque.
    private static let restingOpacity: Float = 0.4

    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var bars = [SIMD2<Float>](repeating: .zero, count: slots)
    private var start = CACurrentMediaTime()
    private var lastFrame = CACurrentMediaTime()
    private var entered = 0
    private var peak: CGFloat = 0

    /// Mirrors `DictationUniforms` in the shader, field for field.
    private struct Uniforms {
        var size: SIMD2<Float>
        var scale: Float
        var offset: Float
        var barWidth: Float
        var step: Float
        var grow: Float
        var band: Float
        var depth: Float
        var dispersion: Float
        var restingOpacity: Float
        var pad: Float = 0
        var color: SIMD4<Float>
        var backdrop: SIMD4<Float>
    }

    /// What every renderer shares.
    private struct Compiled: @unchecked Sendable {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let pipeline: MTLRenderPipelineState
    }

    /// The compiled shader, kept: the first control waits for it, later ones find it ready.
    @MainActor private static var compiled: Compiled?

    /// Calls `ready` on the main thread with a renderer once the shader is compiled; never, when there is no Metal.
    /// The shader is compiled at run time, so building the app needs no Metal toolchain.
    @MainActor static func make(_ ready: @escaping @MainActor (MTLDevice, DictationWaveformRenderer) -> Void) {
        if let compiled { return ready(compiled.device, DictationWaveformRenderer(compiled)) }
        guard let system = MTLCreateSystemDefaultDevice() else { return }
        nonisolated(unsafe) let device = system
        device.makeLibrary(source: shader, options: nil) { built, _ in
            guard let built, let shared = compile(device: device, library: built) else { return }
            Task { @MainActor in
                compiled = shared
                ready(shared.device, DictationWaveformRenderer(shared))
            }
        }
    }

    private init(_ compiled: Compiled) {
        queue = compiled.queue
        pipeline = compiled.pipeline
    }

    private static func compile(device: MTLDevice, library: MTLLibrary) -> Compiled? {
        guard let queue = device.makeCommandQueue(),
              let vertex = library.makeFunction(name: "dictationWaveformVertex"),
              let fragment = library.makeFunction(name: "dictationWaveformFragment") else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = .bgra8Unorm
        // The shader gives premultiplied colour over the glass.
        attachment.isBlendingEnabled = true
        attachment.sourceRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        return Compiled(device: device, queue: queue, pipeline: pipeline)
    }

    func reset() {
        start = CACurrentMediaTime()
        lastFrame = start
        entered = 0
        peak = 0
        bars = [SIMD2<Float>](repeating: .zero, count: Self.slots)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let size = view.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        peak = max(peak, level())
        // A stalled main thread skips frames: the strip resumes where it stopped instead of jumping ahead.
        let now = CACurrentMediaTime()
        if now - lastFrame > 0.1 { start += now - lastFrame - 1.0 / 60 }
        lastFrame = now
        let elapsed = now - start
        let maxHeight = Float(min(size.height - 12, Self.tallest))
        while Double(entered + 1) * Self.interval <= elapsed {
            let height = Self.barWidth + Float(min(1, peak)) * (maxHeight - Self.barWidth)
            bars[entered % Self.slots] = SIMD2(Float(entered), height)
            entered += 1
            peak = 0
        }
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let buffer = queue.makeCommandBuffer(), let encoder = buffer.makeRenderCommandEncoder(descriptor: pass)
        else { return }
        let dark = traits.userInterfaceStyle == .dark
        var uniforms = Uniforms(
            size: SIMD2(Float(size.width), Float(size.height)),
            scale: Float(view.contentScaleFactor),
            offset: Float(elapsed / Self.interval) * Self.step,
            barWidth: Self.barWidth,
            step: Self.step,
            grow: Self.grow * Self.step / Float(Self.interval),
            band: Float(size.height) * 0.3,
            depth: Float(size.height) * 0.375,
            dispersion: 0.04,
            restingOpacity: Self.restingOpacity,
            color: Self.rgba(UIColor(CommaTheme.textPrimary).resolvedColor(with: traits)),
            backdrop: dark ? SIMD4(0.16, 0.16, 0.17, 1) : SIMD4(0.95, 0.95, 0.96, 1)
        )
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        bars.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    private static func rgba(_ color: UIColor) -> SIMD4<Float> {
        var (r, g, b, a): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return SIMD4(Float(r), Float(g), Float(b), Float(a))
    }

    /// The waveform, drawn per pixel. Bars scroll left at a steady speed; each grows from a dot to its level after
    /// it enters, and left of the first one the strip is resting bars. The capsule's outline bends what lies under
    /// it as the system glass's rim does: in a band along the outline each point shows what lies further in along
    /// the outline's normal, reaching furthest at the outline and folding back on itself across the band. So bars near a round end wrap into a crescent that follows its
    /// curve, and the bar crossing the fold swells into a ring. As the system's does, the band reaches past the
    /// bars' ends; only the round ends bend here, as the straight top and bottom edges would show those ends as a
    /// row of dots. Red reaches a little further than green and blue a little less, which splits the bent bars'
    /// edges into colour along the outline.
    private static let shader = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct DictationUniforms {
        float2 size;        // The capsule, in points.
        float scale;        // Pixels per point.
        float offset;       // How far the strip has moved left of the trailing edge, in points.
        float barWidth;
        float step;         // Bar plus gap.
        float grow;         // How far a bar moves while it reaches its level, in points.
        float band;         // How far in from the outline the glass bends what it shows, in points.
        float depth;        // How far inward the outline itself shows, in points: the most the band reaches.
        float dispersion;   // How much further red reaches than green, and blue less, as a share of the reach.
        float restingOpacity; // The bars left of the first one that entered.
        float pad;
        float4 color;       // The bars' colour.
        float4 backdrop;    // The glass's tone behind the bars, for the colour fringes.
    };

    // One bar: its index along the strip and its height in points; a slot not yet used has no height.
    constant int kBarSlots = \#(slots);

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex VertexOut dictationWaveformVertex(uint id [[vertex_id]]) {
        // One triangle that covers the view.
        float2 uv = float2((id << 1) & 2, id & 2);
        VertexOut out;
        out.position = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);
        out.uv = uv;
        return out;
    }

    // How much of the point `p` (in points) a bar covers, 0...1. `soft` widens the edge past one pixel, as a
    // magnified edge is.
    static float coverage(float2 p, float soft, constant DictationUniforms &u, constant float2 *bars) {
        float rel = p.x - (u.size.x - u.offset);
        float cell = floor(rel / u.step);
        float height = u.barWidth;
        float opacity = u.restingOpacity;
        if (cell >= 0) {
            float2 bar = bars[int(cell) % kBarSlots];
            if (bar.y <= 0 || bar.x != cell) return 0;
            float eased = smoothstep(0.0, u.grow, u.offset - (cell + 1) * u.step);
            height = mix(u.barWidth, max(u.barWidth, bar.y), eased);
            opacity = 1;
        }
        float radius = u.barWidth * 0.5;
        float2 q = float2(rel - cell * u.step - radius, p.y - u.size.y * 0.5);
        float2 d = float2(abs(q.x), max(abs(q.y) - (height * 0.5 - radius), 0.0));
        float distance = length(d) - radius;
        return saturate(0.5 - distance * u.scale / soft) * opacity;
    }

    fragment half4 dictationWaveformFragment(VertexOut in [[stage_in]],
                                             constant DictationUniforms &u [[buffer(0)]],
                                             constant float2 *bars [[buffer(1)]]) {
        float2 p = in.uv * u.size;
        float radius = u.size.y * 0.5;

        // The capsule's own edge, so nothing draws past the glass.
        float2 spine = float2(clamp(p.x, radius, u.size.x - radius), radius);
        float inside = saturate(0.5 - (length(p - spine) - radius) * u.scale);
        if (inside <= 0) return half4(0);

        // The outline's inward normal at this point, and how far in from the outline the point is.
        float2 out = p - spine;
        float reach = length(out);
        float2 inward = reach > 1e-3 ? -out / reach : float2(0, 0);
        float fromOutline = radius - reach;
        // How deep into the band, 1 at the outline and 0 where the glass is flat; and how much the outline faces
        // left or right, so the straight top and bottom edges stay flat and the round ends bend most at their tips.
        float t = saturate(1 - fromOutline / u.band);
        float facing = smoothstep(0.0, 0.3, abs(inward.x));
        float bend = t * t * facing;

        // Flat glass neither bends nor splits: one plain sample serves all three colours.
        if (bend <= 0) {
            float a = coverage(p, 1.0, u, bars) * inside;
            return half4(half3(u.color.rgb * a), half(a));
        }

        float3 cover;
        for (int c = 0; c < 3; c++) {
            float shift = u.depth * bend * (1 + u.dispersion * float(1 - c));
            // The band blurs what it bends, by about 3.5pt at the outline as the system glass does, so the bars
            // pulled in run together into one arc along the outline rather than scattered pieces.
            float soft = 1 + 3.5 * u.scale * bend;
            cover[c] = coverage(p + inward * shift, soft, u, bars);
        }
        // Through the band the bars are a little fainter, grey as the system glass shows them there.
        cover *= mix(1.0, 0.7, bend);

        float alpha = max(cover.r, max(cover.g, cover.b));
        // A colour a bar covers less shows more of the glass behind it: that is the fringe.
        float3 rgb = u.color.rgb * cover + u.backdrop.rgb * (alpha - cover);
        return half4(half3(rgb * inside), half(alpha * inside));
    }
    """#
}

/// The control in the composer's SwiftUI row.
struct DictationControl: UIViewRepresentable {
    let model: DictationModel
    let phase: DictationModel.Phase
    let toggle: () -> Void

    func makeUIView(context: Context) -> DictationGlassControl {
        let view = DictationGlassControl()
        view.level = { [weak model] in model?.sampleLevel() ?? 0 }
        return view
    }

    func updateUIView(_ view: DictationGlassControl, context: Context) {
        view.toggle = toggle
        view.phase = phase
    }
}
