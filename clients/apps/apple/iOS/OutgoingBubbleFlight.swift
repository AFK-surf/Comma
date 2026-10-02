import SwiftUI

/// Port of the desktop send motion (`outgoingBubbleMotionModel.ts`, `outgoingBubbleMotion.ts`).
/// The composer surface becomes the sent bubble: width, height and position each follow their own
/// spring, a surface pulse squeezes it once, and the material turns from input white to bubble blue.
enum MessageSendMotion {
    struct Spring {
        var response: Double
        var dampingRatio: Double
        var initialVelocity: Double
        var delayMs: Double
        var maxOvershoot: Double
    }

    /// `motionMessageSend` in `clients/packages/ui/src/tokens/motion.ts`.
    static let width = Spring(response: 0.34, dampingRatio: 0.86, initialVelocity: 3.4, delayMs: 0, maxOvershoot: 0)
    static let position = Spring(response: 0.44, dampingRatio: 0.99, initialVelocity: 0, delayMs: 20, maxOvershoot: 8)
    static let height = Spring(response: 0.38, dampingRatio: 0.96, initialVelocity: 0, delayMs: 0, maxOvershoot: 4)
    static let pulse = Spring(response: 0.76, dampingRatio: 0.93, initialVelocity: 0, delayMs: 0, maxOvershoot: 0)
    static let pulseAmount = 0.3
    /// Material and chrome change over `motionDuration.stateChange`.
    static let materialMs = 150.0

    /// Analytic unit-mass spring: progress and velocity without frame integration.
    static func state(_ spring: Spring, _ time: Double) -> (progress: Double, velocity: Double) {
        let omega = 2 * .pi / spring.response
        let damping = spring.dampingRatio
        let velocity = spring.initialVelocity
        if abs(damping - 1) < 0.00001 {
            let b = omega - velocity
            let decay = exp(-omega * time)
            return (1 - (1 + b * time) * decay, (omega * (1 + b * time) - b) * decay)
        }
        if damping < 1 {
            let a = damping * omega
            let b = omega * (1 - damping * damping).squareRoot()
            let c = (a - velocity) / b
            let decay = exp(-a * time)
            let cosine = cos(b * time), sine = sin(b * time)
            return (1 - decay * (cosine + c * sine), decay * (a * (cosine + c * sine) + b * (sine - c * cosine)))
        }
        let root = (damping * damping - 1).squareRoot()
        let r1 = -omega * (damping - root), r2 = -omega * (damping + root)
        let c1 = (-velocity - r2) / (r1 - r2), c2 = 1 - c1
        return (1 - c1 * exp(r1 * time) - c2 * exp(r2 * time), -c1 * r1 * exp(r1 * time) - c2 * r2 * exp(r2 * time))
    }

    /// Time to rest: progress within 0.001 and velocity within 0.01, sampled at 120 Hz for at most 3s.
    static func settleMs(_ spring: Spring) -> Double {
        for sample in 1...360 {
            let value = state(spring, Double(sample) / 120)
            if abs(1 - value.progress) <= 0.001 && abs(value.velocity) <= 0.01 { return Double(sample) / 120 * 1000 }
        }
        return 3000
    }

    /// Channel progress with the desktop's soft pixel limit on overshoot.
    static func progress(_ spring: Spring, distance: Double, atMs time: Double) -> Double {
        let end = spring.delayMs + settleMs(spring)
        if time <= spring.delayMs { return 0 }
        if time >= end { return 1 }
        let value = state(spring, (time - spring.delayMs) / 1000).progress
        if value <= 1 { return value }
        let limit = spring.maxOvershoot / max(1, abs(distance))
        let overshoot = value - 1
        return 1 + (limit == 0 ? 0 : limit * overshoot / (limit + overshoot))
    }

    static let peakPulseVelocity: Double = (0...360).map { state(pulse, Double($0) / 120).velocity }.max() ?? 1
    static let pulseEndMs = pulse.delayMs + settleMs(pulse)
    static let durationMs = max(width.delayMs + settleMs(width), position.delayMs + settleMs(position),
                                height.delayMs + settleMs(height), pulseEndMs)

    /// The step response's velocity is a damped impulse: squeeze, release, small rebound.
    static func surfaceScale(atMs time: Double) -> Double {
        guard time > pulse.delayMs, time < pulseEndMs else { return 1 }
        return 1 - pulseAmount * state(pulse, (time - pulse.delayMs) / 1000).velocity / peakPulseVelocity
    }
}

/// One send in flight: the composer frame it leaves and the moment it left.
struct OutgoingFlight: Equatable {
    let id: String
    let text: String
    let tail: Bool
    let source: CGRect
    let sourceText: CGPoint
    let sourceRadius: CGFloat
    let start: Date
}

@MainActor @Observable
final class OutgoingFlightController {
    private(set) var flight: OutgoingFlight?
    /// Final bubble frame in the chat coordinate space, measured from the reserved transcript slot.
    var target: CGRect?
    var composerFrame: CGRect = .zero
    var composerTextOrigin: CGPoint = .zero

    func launch(id: String, text: String) {
        target = nil
        flight = OutgoingFlight(id: id, text: text, tail: true, source: composerFrame,
                                sourceText: composerTextOrigin, sourceRadius: 22, start: .now)
        let current = id
        Task {
            try? await Task.sleep(for: .milliseconds(Int(MessageSendMotion.durationMs) + 40))
            if flight?.id == current { flight = nil; target = nil }
        }
    }

    func elapsedMs(_ date: Date) -> Double {
        guard let flight else { return .infinity }
        return max(0, date.timeIntervalSince(flight.start) * 1000)
    }

    func isFlying(_ id: String) -> Bool { flight?.id == id }
}

extension CoordinateSpaceProtocol where Self == NamedCoordinateSpace {
    static var chat: NamedCoordinateSpace { .named("comma.chat") }
}

/// The sent row while its surface flies: it reserves height on the height spring, stays invisible,
/// and reports where the bubble will rest.
struct OutgoingSlot<Bubble: View>: View {
    let controller: OutgoingFlightController
    let id: String
    @ViewBuilder var bubble: Bubble
    @State private var size: CGSize = .zero

    var body: some View {
        TimelineView(.animation(paused: !controller.isFlying(id))) { context in
            let flying = controller.isFlying(id)
            let height = flying ? MessageSendMotion.progress(MessageSendMotion.height, distance: size.height,
                                                             atMs: controller.elapsedMs(context.date)) : 1
            bubble
                .opacity(flying ? 0 : 1)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .chat) } action: { frame in
                    size = frame.size
                    if flying { controller.target = frame }
                }
                .frame(height: flying && size.height > 0 ? max(0, size.height * min(1, height)) : nil, alignment: .bottom)
        }
    }
}

/// The flying surface, drawn above the transcript and composer so neither clips it.
struct OutgoingFlightOverlay: View {
    let controller: OutgoingFlightController

    var body: some View {
        if let flight = controller.flight, let target = controller.target {
            TimelineView(.animation) { context in
                surface(flight, target: target, time: controller.elapsedMs(context.date))
            }
            .allowsHitTesting(false)
        }
    }

    private func surface(_ flight: OutgoingFlight, target: CGRect, time: Double) -> some View {
        let start = flight.source.width > 0 ? flight.source : target
        let dx = start.maxX - target.maxX
        let dy = start.maxY - target.maxY
        let width = MessageSendMotion.progress(MessageSendMotion.width, distance: target.width - start.width, atMs: time)
        let position = MessageSendMotion.progress(MessageSendMotion.position, distance: hypot(dx, dy), atMs: time)
        let height = MessageSendMotion.progress(MessageSendMotion.height, distance: target.height - start.height, atMs: time)
        let scale = MessageSendMotion.surfaceScale(atMs: time)
        let paintedWidth = start.width + (target.width - start.width) * width
        let paintedHeight = start.height + (target.height - start.height) * height
        let radiusProgress = max(0, min(1, width, height))
        let radius = max(0, min(flight.sourceRadius + (CommaTheme.bubbleRadius - flight.sourceRadius) * radiusProgress,
                                paintedWidth / 2, paintedHeight / 2))
        let material = min(1, time / MessageSendMotion.materialMs)
        let fill = CommaTheme.bgPrimary.mix(with: CommaTheme.brandSolid, by: material)
        // Text keeps its final layout from frame zero and travels from the composer glyph.
        let textStart = CGPoint(x: target.minX + dx + CommaTheme.bubblePadding.leading, y: target.minY + dy + CommaTheme.bubblePadding.top)
        let textX = flight.sourceText.x - textStart.x
        let textY = flight.sourceText.y - textStart.y
        let whiteText = time >= MessageSendMotion.materialMs * 0.8
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)

        return Text(flight.text)
            .font(CommaTheme.messageFont)
            .foregroundStyle(whiteText ? Color.white : CommaTheme.textPrimary)
            .padding(CommaTheme.bubblePadding)
            .offset(x: textX * (1 - width), y: textY * (1 - height))
            .frame(width: target.width, height: target.height, alignment: .topLeading)
            .mask(alignment: .bottomTrailing) { shape.frame(width: paintedWidth, height: paintedHeight) }
            .background(alignment: .bottomTrailing) {
                ZStack(alignment: .bottomTrailing) {
                    shape.fill(fill)
                    shape.strokeBorder(CommaTheme.borderPrimary, lineWidth: 1).opacity(1 - material)
                    if flight.tail {
                        Image("MessageTail").renderingMode(.template).resizable()
                            .foregroundStyle(fill)
                            .frame(width: 16, height: 10)
                            .offset(x: -8, y: 7)
                    }
                }
                .frame(width: paintedWidth, height: paintedHeight)
            }
            .scaleEffect(scale, anchor: .bottomTrailing)
            .offset(x: dx * (1 - position), y: dy * (1 - position))
            .position(x: target.midX, y: target.midY)
    }
}
