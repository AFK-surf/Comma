import AppKit
import Metal
import QuartzCore

final class ColorfulBorderView: NSView {
    enum RenderMode: Equatable {
        case full
        case noiseOnly
    }

    struct Geometry: Equatable {
        var innerRect: CGRect
        var cornerRadius: CGFloat
        var glowScale: CGFloat

        static let zero = Geometry(
            innerRect: .zero,
            cornerRadius: 0,
            glowScale: 1.0
        )
    }

    private static let renderFPS = 30.0
    private static let noisePower = 0.9
    private static let noiseFrequency = 1.8
    private static let noiseMinimumAlpha = 0.03
    private static let noiseIdleValue = 0.5
    private static let minimumNoiseStrength = 0.3
    fileprivate static let minimumBorderAlpha = 0.4
    private static let idleColorMotionAmplitude = 0.18
    private static let noiseAnimationAmount = 0.6
    private static let noiseAnimationSpeed = 0.4
    private static let shaderColors: [SIMD4<Float>] = [
        .init(239 / 255, 176 / 255, 76 / 255, 0.92),
        .init(233 / 255, 128 / 255, 86 / 255, 0.88),
        .init(234 / 255, 75 / 255, 107 / 255, 0.95),
        .init(230 / 255, 97 / 255, 165 / 255, 0.9),
        .init(223 / 255, 138 / 255, 233 / 255, 0.86),
        .init(192 / 255, 160 / 255, 245 / 255, 0.94),
        .init(100 / 255, 181 / 255, 245 / 255, 0.89),
        .init(126 / 255, 201 / 255, 238 / 255, 0.93),
    ]

    private let metalLayer = CAMetalLayer()
    private let renderer = ColorfulBorderShaderRenderer()

    private var renderTimer: Timer?
    private var lastAnimationTimestamp = ProcessInfo.processInfo.systemUptime
    private var noiseTime: Double = 0
    private var activityProgress: Double = 0
    private var targetActivityAmplitude: Double = 0
    private var colorSpecklePositions: [SIMD2<Float>] = []
    private var colorSpeckleTargets: [SIMD2<Float>] = []
    private var renderMode: RenderMode = .full

    private var geometry: Geometry = .zero {
        didSet {
            guard geometry != oldValue else { return }
            renderNow()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        metalLayer.device = renderer.device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = false
        metalLayer.isOpaque = false
        metalLayer.backgroundColor = NSColor.clear.cgColor
        metalLayer.contentsGravity = .resize
        layer?.addSublayer(metalLayer)

        synchronizeColorSpeckles(resetPositions: true)
        updateDrawableState()
        updateAnimationState()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    deinit {
        renderTimer?.invalidate()
    }

    override func layout() {
        super.layout()
        updateDrawableState()
        renderNow()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDrawableState()
        updateAnimationState()
        renderNow()
    }

    func updateGeometry(_ geometry: Geometry) {
        self.geometry = geometry
    }

    func setActivityAmplitude(_ amplitude: Double) {
        let clampedAmplitude = min(max(amplitude, 0), 1)
        guard abs(targetActivityAmplitude - clampedAmplitude) > 0.0001 else { return }
        targetActivityAmplitude = clampedAmplitude
        updateAnimationState()
        renderNow()
    }

    func setRenderMode(_ mode: RenderMode) {
        guard renderMode != mode else { return }
        renderMode = mode
        renderNow()
    }
}

private extension ColorfulBorderView {
    static func visibleActivityAmplitude(for progress: Double) -> Double {
        let clampedProgress = min(max(progress, 0), 1)
        return pow(clampedProgress, 3)
    }

    static func borderColorSpeed(for progress: Double) -> Double {
        let clampedProgress = min(max(progress, 0), 1)
        return 1.0 + clampedProgress * 1.0
    }

    static func randomColorSpecklePoint() -> SIMD2<Float> {
        .init(
            Float.random(in: 0.02 ... 0.98),
            Float.random(in: 0.02 ... 0.98)
        )
    }

    func synchronizeColorSpeckles(resetPositions: Bool) {
        let desiredCount = Self.shaderColors.count
        guard desiredCount > 0 else {
            colorSpecklePositions = []
            colorSpeckleTargets = []
            return
        }

        if resetPositions || colorSpecklePositions.count != desiredCount || colorSpeckleTargets.count != desiredCount {
            colorSpecklePositions = (0 ..< desiredCount).map { _ in Self.randomColorSpecklePoint() }
            colorSpeckleTargets = (0 ..< desiredCount).map { _ in Self.randomColorSpecklePoint() }
        }
    }

    func advanceColorSpeckles(delta: Double, speed: Double) {
        guard !colorSpecklePositions.isEmpty,
              colorSpecklePositions.count == colorSpeckleTargets.count
        else {
            return
        }

        let motionBlend = Float(1 - exp(-delta * max(speed, 0) * 2.4))
        for index in colorSpecklePositions.indices {
            let currentPosition = colorSpecklePositions[index]
            let targetPosition = colorSpeckleTargets[index]
            let updatedPosition = currentPosition + (targetPosition - currentPosition) * motionBlend
            colorSpecklePositions[index] = updatedPosition

            let deltaPosition = updatedPosition - targetPosition
            let squaredDistance = deltaPosition.x * deltaPosition.x + deltaPosition.y * deltaPosition.y
            if squaredDistance < 0.0144 {
                colorSpeckleTargets[index] = Self.randomColorSpecklePoint()
            }
        }
    }

    func updateAnimationState() {
        let shouldAnimate = window != nil

        if shouldAnimate, renderTimer == nil {
            lastAnimationTimestamp = ProcessInfo.processInfo.systemUptime
            let timer = Timer(timeInterval: 1 / Self.renderFPS, repeats: true) { [weak self] _ in
                self?.advanceAnimation()
            }
            renderTimer = timer
            RunLoop.main.add(timer, forMode: .common)
            return
        }

        if !shouldAnimate {
            renderTimer?.invalidate()
            renderTimer = nil
        }
    }

    func advanceAnimation() {
        let now = ProcessInfo.processInfo.systemUptime
        let delta = min(0.12, max(1 / 120, now - lastAnimationTimestamp))
        lastAnimationTimestamp = now

        let blendRate = targetActivityAmplitude > activityProgress ? 7.0 : 1.6
        let blendAmount = 1 - exp(-delta * blendRate)
        activityProgress += (targetActivityAmplitude - activityProgress) * blendAmount

        let visibleActivityAmplitude = Self.visibleActivityAmplitude(for: activityProgress)
        let effectiveNoiseSpeed = Self.noiseAnimationSpeed * visibleActivityAmplitude
        let effectiveColorMotionAmplitude = max(visibleActivityAmplitude, Self.idleColorMotionAmplitude)
        if window != nil {
            noiseTime += delta * effectiveNoiseSpeed
            advanceColorSpeckles(
                delta: delta,
                speed: Self.borderColorSpeed(for: effectiveColorMotionAmplitude)
            )
        }

        updateAnimationState()
        renderNow()
    }

    func updateDrawableState() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.frame = bounds
        metalLayer.contentsScale = window?.backingScaleFactor ?? 2.0
        metalLayer.drawableSize = .init(
            width: max(1, bounds.width * metalLayer.contentsScale),
            height: max(1, bounds.height * metalLayer.contentsScale)
        )
        CATransaction.commit()
    }

    func renderNow() {
        guard bounds.width > 0,
              bounds.height > 0,
              geometry.innerRect.width > 0,
              geometry.innerRect.height > 0
        else {
            return
        }

        let visibleActivityAmplitude = Self.visibleActivityAmplitude(for: activityProgress)
        let effectiveNoiseStrength = Self.minimumNoiseStrength + visibleActivityAmplitude * (1.0 - Self.minimumNoiseStrength)
        let effectiveNoiseAmount = Self.noiseAnimationAmount * visibleActivityAmplitude

        renderer.render(
            metalLayer: metalLayer,
            contentsScale: Double(metalLayer.contentsScale),
            geometry: geometry,
            colors: Self.shaderColors,
            colorPoints: colorSpecklePositions,
            showsNoiseOnly: renderMode == .noiseOnly,
            noiseStrength: effectiveNoiseStrength,
            noisePower: Self.noisePower,
            noiseFrequency: Self.noiseFrequency,
            noiseMinimumAlpha: Self.noiseMinimumAlpha,
            noiseIdleValue: Self.noiseIdleValue,
            noiseAnimationAmount: effectiveNoiseAmount,
            noiseActivity: visibleActivityAmplitude,
            noiseTime: noiseTime
        )
    }
}

@MainActor
private final class ColorfulBorderShaderRenderer {
    struct Uniforms {
        var viewportSize: SIMD2<Float>
        var innerOrigin: SIMD2<Float>
        var innerSize: SIMD2<Float>
        var cornerRadius: Float
        var glowScale: Float
        var noiseFrequency: Float
        var noisePower: Float
        var noiseMinimumAlpha: Float
        var noiseIdleValue: Float
        var noiseStrength: Float
        var noiseAnimationAmount: Float
        var noiseActivity: Float
        var noiseTime: Float
        var colorCount: UInt32
        var showsNoiseOnly: UInt32
        var padding: UInt32 = 0
        var padding2: UInt32 = 0
        var padding3: UInt32 = 0
    }

    let device: MTLDevice?

    private let commandQueue: MTLCommandQueue?
    private let pipelineState: MTLRenderPipelineState?

    init() {
        guard
            let device = MTLCreateSystemDefaultDevice(),
            let commandQueue = device.makeCommandQueue(),
            let library = try? device.makeLibrary(source: Self.shaderSource, options: nil),
            let vertexFunction = library.makeFunction(name: "window_border_vertex"),
            let fragmentFunction = library.makeFunction(name: "window_border_fragment")
        else {
            device = nil
            commandQueue = nil
            pipelineState = nil
            return
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].rgbBlendOperation = .add
        descriptor.colorAttachments[0].alphaBlendOperation = .add
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        self.device = device
        self.commandQueue = commandQueue
        pipelineState = try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    func render(
        metalLayer: CAMetalLayer,
        contentsScale: Double,
        geometry: ColorfulBorderView.Geometry,
        colors: [SIMD4<Float>],
        colorPoints: [SIMD2<Float>],
        showsNoiseOnly: Bool,
        noiseStrength: Double,
        noisePower: Double,
        noiseFrequency: Double,
        noiseMinimumAlpha: Double,
        noiseIdleValue: Double,
        noiseAnimationAmount: Double,
        noiseActivity: Double,
        noiseTime: Double
    ) {
        guard let commandQueue,
              let pipelineState,
              let drawable = metalLayer.nextDrawable()
        else {
            return
        }

        let drawableSize = metalLayer.drawableSize
        guard drawableSize.width > 1, drawableSize.height > 1 else { return }

        var uniforms = Uniforms(
            viewportSize: .init(Float(drawableSize.width), Float(drawableSize.height)),
            innerOrigin: .init(
                Float(geometry.innerRect.minX * contentsScale),
                Float(geometry.innerRect.minY * contentsScale)
            ),
            innerSize: .init(
                Float(geometry.innerRect.width * contentsScale),
                Float(geometry.innerRect.height * contentsScale)
            ),
            cornerRadius: Float(geometry.cornerRadius * contentsScale),
            glowScale: Float(geometry.glowScale * contentsScale),
            noiseFrequency: Float(noiseFrequency),
            noisePower: Float(noisePower),
            noiseMinimumAlpha: Float(noiseMinimumAlpha),
            noiseIdleValue: Float(noiseIdleValue),
            noiseStrength: Float(noiseStrength),
            noiseAnimationAmount: Float(noiseAnimationAmount),
            noiseActivity: Float(noiseActivity),
            noiseTime: Float(noiseTime),
            colorCount: UInt32(colors.count),
            showsNoiseOnly: showsNoiseOnly ? 1 : 0
        )

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = drawable.texture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = .init(red: 0, green: 0, blue: 0, alpha: 0)

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)
        else {
            return
        }

        renderEncoder.setRenderPipelineState(pipelineState)
        renderEncoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        renderEncoder.setFragmentBytes(colors, length: MemoryLayout<SIMD4<Float>>.stride * colors.count, index: 1)
        renderEncoder.setFragmentBytes(colorPoints, length: MemoryLayout<SIMD2<Float>>.stride * colorPoints.count, index: 2)
        renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        renderEncoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private static let shaderSource = """
    #include <metal_stdlib>

    using namespace metal;

    struct Uniforms {
        float2 viewportSize;
        float2 innerOrigin;
        float2 innerSize;
        float cornerRadius;
        float glowScale;
        float noiseFrequency;
        float noisePower;
        float noiseMinimumAlpha;
        float noiseIdleValue;
        float noiseStrength;
        float noiseAnimationAmount;
        float noiseActivity;
        float noiseTime;
        uint colorCount;
        uint showsNoiseOnly;
        uint padding;
        uint padding2;
        uint padding3;
    };

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex VertexOut window_border_vertex(uint vertexID [[vertex_id]]) {
        float2 positions[3] = {
            float2(-1.0, -1.0),
            float2( 3.0, -1.0),
            float2(-1.0,  3.0)
        };

        VertexOut out;
        out.position = float4(positions[vertexID], 0.0, 1.0);
        out.uv = positions[vertexID] * 0.5 + 0.5;
        return out;
    }

    float smoothUnit(float value) {
        float clampedValue = clamp(value, 0.0, 1.0);
        return clampedValue * clampedValue * (3.0 - 2.0 * clampedValue);
    }

    float hash31(float3 value) {
        value = fract(value * 0.1031);
        value += dot(value, value.yzx + 33.33);
        return fract((value.x + value.y) * value.z);
    }

    float valueNoise3(float3 position) {
        float3 cell = floor(position);
        float3 fraction = fract(position);
        float3 weight = float3(
            smoothUnit(fraction.x),
            smoothUnit(fraction.y),
            smoothUnit(fraction.z)
        );

        float n000 = hash31(cell + float3(0.0, 0.0, 0.0));
        float n100 = hash31(cell + float3(1.0, 0.0, 0.0));
        float n010 = hash31(cell + float3(0.0, 1.0, 0.0));
        float n110 = hash31(cell + float3(1.0, 1.0, 0.0));
        float n001 = hash31(cell + float3(0.0, 0.0, 1.0));
        float n101 = hash31(cell + float3(1.0, 0.0, 1.0));
        float n011 = hash31(cell + float3(0.0, 1.0, 1.0));
        float n111 = hash31(cell + float3(1.0, 1.0, 1.0));

        float plane0Top = mix(n000, n100, weight.x);
        float plane0Bottom = mix(n010, n110, weight.x);
        float plane1Top = mix(n001, n101, weight.x);
        float plane1Bottom = mix(n011, n111, weight.x);
        float plane0 = mix(plane0Top, plane0Bottom, weight.y);
        float plane1 = mix(plane1Top, plane1Bottom, weight.y);
        return mix(plane0, plane1, weight.z);
    }

    float fractalNoise3(float3 position) {
        float amplitude = 1.0;
        float frequency = 1.0;
        float accumulatedValue = 0.0;
        float accumulatedAmplitude = 0.0;

        for (int octave = 0; octave < 3; octave++) {
            accumulatedValue += valueNoise3(position * frequency) * amplitude;
            accumulatedAmplitude += amplitude;
            amplitude *= 0.5;
            frequency *= 2.0;
        }

        return accumulatedValue / max(accumulatedAmplitude, 0.0001);
    }

    float signedDistanceToRoundedRect(float2 point, float2 halfSize, float radius) {
        float2 safeHalfSize = max(halfSize, float2(radius + 1.0));
        float2 q = abs(point) - safeHalfSize + radius;
        return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
    }

    float4 sampleBorderColor(
        constant float4 *colors,
        constant float2 *points,
        uint colorCount,
        float2 uv,
        float2 viewportSize
    ) {
        if (colorCount == 0) {
            return float4(1.0);
        }
        if (colorCount == 1) {
            return colors[0];
        }

        float aspect = max(viewportSize.y / max(viewportSize.x, 1.0), 0.0001);
        float2 samplePoint = float2(uv.x, uv.y * aspect);
        float contributionTotal = 0.0;
        float4 accumulatedColor = float4(0.0);

        for (uint index = 0; index < colorCount; index++) {
            float2 point = float2(points[index].x, points[index].y * aspect);
            float distanceToPoint = length(samplePoint - point);
            float contribution = 1.0 / (0.008 + pow(distanceToPoint, 3.6));
            accumulatedColor += colors[index] * contribution;
            contributionTotal += contribution;
        }

        return accumulatedColor / max(contributionTotal, 0.0001);
    }

    fragment float4 window_border_fragment(
        VertexOut in [[stage_in]],
        constant Uniforms &uniforms [[buffer(0)]],
        constant float4 *colors [[buffer(1)]],
        constant float2 *points [[buffer(2)]]
    ) {
        float2 pixel = in.uv * uniforms.viewportSize;

        float3 noiseSamplePoint = float3(
            in.uv.x * uniforms.noiseFrequency + 7.13,
            in.uv.y * uniforms.noiseFrequency + 19.41,
            uniforms.noiseTime
        );
        float rawNoise = fractalNoise3(noiseSamplePoint);
        float shapedNoise = pow(
            smoothstep(0.3, 0.88, rawNoise),
            max(uniforms.noisePower, 0.001)
        );
        float animatedNoise = mix(
            1.0,
            shapedNoise,
            clamp(uniforms.noiseAnimationAmount, 0.0, 1.0)
        );
        float noiseAlpha = uniforms.noiseMinimumAlpha
            + animatedNoise * (1.0 - uniforms.noiseMinimumAlpha);
        float activeNoiseMask = mix(
            1.0,
            noiseAlpha,
            clamp(uniforms.noiseStrength, 0.0, 1.0)
        );
        float noiseMask = mix(
            clamp(uniforms.noiseIdleValue, 0.0, 1.0),
            activeNoiseMask,
            clamp(uniforms.noiseActivity, 0.0, 1.0)
        );

        if (uniforms.showsNoiseOnly > 0u) {
            return float4(noiseMask, noiseMask, noiseMask, noiseMask);
        }

        float2 innerCenter = uniforms.innerOrigin + uniforms.innerSize * 0.5;
        float2 halfSize = uniforms.innerSize * 0.5;
        float cornerRadius = min(
            uniforms.cornerRadius,
            max(0.0, min(halfSize.x, halfSize.y) - 1.0)
        );

        float borderDistance = abs(
            signedDistanceToRoundedRect(pixel - innerCenter, halfSize, cornerRadius)
        );
        float coreWidth = max(1.5, uniforms.glowScale * 1.6);
        float glowRadius = max(8.0, uniforms.glowScale * 24.0);
        float halo = exp(-max(borderDistance - coreWidth, 0.0) / glowRadius);
        float core = 1.0 - smoothstep(0.0, coreWidth, borderDistance);
        float baseGlow = max(core, halo * 0.95);
        float alphaMask = max(noiseMask, \(ColorfulBorderView.minimumBorderAlpha));
        float finalAlpha = clamp(baseGlow * alphaMask, 0.0, 1.0);

        if (finalAlpha < 0.001) {
            return float4(0.0);
        }

        float4 color = sampleBorderColor(
            colors,
            points,
            uniforms.colorCount,
            in.uv,
            uniforms.viewportSize
        );
        float3 premultiplied = color.rgb * finalAlpha;
        return float4(premultiplied, finalAlpha);
    }
    """
}
