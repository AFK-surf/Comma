import SwiftUI

/// The Routines with every card cleared: a mark and one line, which stay until a refresh brings new cards. With
/// `celebrate`, the moment the member clears the last card, the mark pops in while the surface around it throws
/// confetti (`RoutineConfetti`). Reduce Motion keeps the line and leaves both out.
struct RoutinesCleared: View {
    let celebrate: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 8) {
            CentralIcon("central-celebrate", size: 24, relativeTo: .subheadline)
                // From half its size, never seen at that size: its opacity follows its scale.
                .keyframeAnimator(initialValue: CGFloat(1), trigger: celebrate && !reduceMotion) { mark, scale in
                    mark.scaleEffect(scale).opacity(min(max((scale - 0.5) / 0.5, 0), 1))
                } keyframes: { _ in
                    MoveKeyframe(RoutineClearedMotion.markScale)
                    SpringKeyframe(1, duration: RoutineClearedMotion.enter, spring: .snappy(extraBounce: 0.2))
                }
            Text("Congrats, routines cleared").font(.subheadline.weight(.medium))
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(CommaTheme.textTertiary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("routinesCleared")
        .anchorPreference(key: RoutinesClearedBounds.self, value: .bounds) { $0 }
    }
}

/// Where the cleared line is, for the surface that throws the confetti over it.
struct RoutinesClearedBounds: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = nextValue() ?? value }
}

/// The cleared Routines' motion, as `motionRoutineCleared` in `clients/packages/ui/src/tokens/motion.ts`: a party
/// popper at each side of the surface throws paper and ribbons up and across it. A throw spends itself against the
/// air, then the pieces drift down, sway and fade. Distances are in points, speeds per second, times in seconds.
enum RoutineClearedMotion {
    static let markScale: CGFloat = 0.5
    static let enter: Double = 0.32
    /// Pieces each popper throws.
    static let pieces = 22
    /// The pieces leave a popper within this long of each other.
    static let delay = 0.0...0.11
    /// A piece's time in the air, from the quickest to the slowest.
    static let flight = 1.8...2.8
    /// Share of its flight a piece stays whole before it fades out.
    static let fadeFrom = 0.62
    /// How fast the air spends a throw: the share of its speed lost a second.
    static let drag = 4.2
    /// How far a throw carries, as a share of the surface's width, and its limit.
    static let reach = 0.5...1.25
    static let reachLimit = 400.0
    /// The throw's angle above the horizontal, in degrees.
    static let angle = 50.0...84.0
    /// How far under the line the poppers stand, so the throw rises past it.
    static let drop = 48.0
    /// How fast a spent piece drifts down.
    static let fall = 70.0...135.0
    /// Side to side sway of a drifting piece: its width and its turns a second.
    static let sway = 3.0...9.0
    static let swayRate = 0.6...1.1
    /// Turns a second a piece spins, and a paper flips over.
    static let spin = 0.4...1.4
    static let flip = 0.9...1.7
    /// The papers' colours, the label palette's.
    static let tones = ["blue", "pink", "warning", "success", "purple", "orange"]
}

/// One piece a popper throws: what it is, and the flight it was given.
struct RoutineConfettiPiece {
    enum Kind { case paper, dot, ribbon }

    let kind: Kind
    let tone: Int
    /// The popper's side: -1 throws from the leading edge, 1 from the trailing one.
    let side: Double
    let delay, flight, reach, angle, fall, sway, swayRate, swayAt, turn, spin, flip, flipAt: Double

    /// What the two poppers throw: paper mostly, with dots and ribbons among it. The same draws every time, so
    /// every burst is the same throw.
    static let burst: [RoutineConfettiPiece] = {
        var draws = SeededDraws(seed: UInt64(RoutineClearedMotion.pieces))
        func within(_ range: ClosedRange<Double>) -> Double { range.lowerBound + (range.upperBound - range.lowerBound) * draws.next() }
        return [-1.0, 1.0].enumerated().flatMap { popper, side in
            (0..<RoutineClearedMotion.pieces).map { index in
                let kind: Kind = index % 4 == 3 ? .ribbon : index % 4 == 1 ? .dot : .paper
                return RoutineConfettiPiece(
                    kind: kind, tone: (index + popper) % RoutineClearedMotion.tones.count, side: side,
                    delay: within(RoutineClearedMotion.delay), flight: within(RoutineClearedMotion.flight),
                    reach: within(RoutineClearedMotion.reach), angle: within(RoutineClearedMotion.angle),
                    fall: within(RoutineClearedMotion.fall), sway: within(RoutineClearedMotion.sway),
                    swayRate: within(RoutineClearedMotion.swayRate), swayAt: draws.next(), turn: draws.next(),
                    spin: within(RoutineClearedMotion.spin) * (draws.next() < 0.5 ? -1 : 1),
                    flip: kind == .paper ? within(RoutineClearedMotion.flip) : 0, flipAt: draws.next())
            }
        }
    }()

    /// The longest any piece is in the air, from the burst's start.
    static let duration = burst.map { $0.delay + $0.flight }.max() ?? 0

    /// Where the piece is `seconds` into its flight across a surface `width` wide, from a popper at `originY` on its
    /// side's edge: the throw loses its speed to the air (an exponential), and from then on the piece drifts down
    /// and sways. Nil before it leaves the popper and once its flight has ended.
    func pose(at seconds: Double, width: Double, originY: Double) -> (center: CGPoint, rotation: Angle, flip: Double, opacity: Double)? {
        guard seconds >= 0, seconds <= flight else { return nil }
        let turn = 2 * Double.pi
        let reach = min(self.reach * width, RoutineClearedMotion.reachLimit)
        let angle = self.angle * .pi / 180
        let spent = 1 - exp(-RoutineClearedMotion.drag * seconds)
        let x = (side < 0 ? 0 : width) - side * cos(angle) * reach * spent
            + sway * spent * sin(turn * (swayRate * seconds + swayAt))
        let y = originY - sin(angle) * reach * spent + fall * seconds
        let progress = seconds / flight
        let fade = RoutineClearedMotion.fadeFrom
        return (CGPoint(x: x, y: y), .radians(turn * (self.turn + spin * seconds)),
                flip == 0 ? 1 : cos(turn * (flip * seconds + flipAt)),
                progress <= fade ? 1 : (1 - progress) / (1 - fade))
    }
}

/// Draws from a seed (SplitMix64), each between 0 and 1.
private struct SeededDraws {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double((mixed ^ (mixed >> 31)) >> 11) / Double(1 << 53)
    }
}

/// The burst over the cleared Routines, drawn each frame from `start`. Its owner takes it away once the last piece
/// has faded (`RoutineConfettiPiece.duration`). The poppers stand `RoutineClearedMotion.drop` under `originY`, the
/// cleared line's lower edge.
struct RoutineConfetti: View {
    let start: Date
    let originY: CGFloat

    private static let paper = CGSize(width: 6, height: 12)
    private static let dot: CGFloat = 6
    /// A curl of ribbon, 32 by 12 points, about its own middle.
    private static let ribbon: Path = {
        var path = Path()
        path.move(to: CGPoint(x: -14, y: 0))
        path.addCurve(to: CGPoint(x: -3.5, y: 0), control1: CGPoint(x: -10.5, y: -6), control2: CGPoint(x: -7, y: -6))
        path.addCurve(to: CGPoint(x: 7, y: 0), control1: CGPoint(x: 0, y: 6), control2: CGPoint(x: 3.5, y: 6))
        path.addCurve(to: CGPoint(x: 14, y: -4), control1: CGPoint(x: 9.3, y: -4), control2: CGPoint(x: 11.7, y: -5.3))
        return path
    }()

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let elapsed = timeline.date.timeIntervalSince(start)
                let origin = originY + RoutineClearedMotion.drop
                for piece in RoutineConfettiPiece.burst {
                    guard let pose = piece.pose(at: elapsed - piece.delay, width: size.width, originY: origin) else { continue }
                    var layer = context
                    layer.opacity = pose.opacity
                    layer.translateBy(x: pose.center.x, y: pose.center.y)
                    layer.rotate(by: pose.rotation)
                    layer.scaleBy(x: 1, y: pose.flip)
                    let color = TaskLabelColor.color(RoutineClearedMotion.tones[piece.tone])
                    switch piece.kind {
                    case .paper:
                        let rect = CGRect(x: -Self.paper.width / 2, y: -Self.paper.height / 2, width: Self.paper.width, height: Self.paper.height)
                        layer.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(color))
                    case .dot:
                        layer.fill(Path(ellipseIn: CGRect(x: -Self.dot / 2, y: -Self.dot / 2, width: Self.dot, height: Self.dot)), with: .color(color))
                    case .ribbon:
                        layer.stroke(Self.ribbon, with: .color(color), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    }
                }
            }
        }
    }
}
