import CoreGraphics
import Foundation

// MARK: - Result types

struct ActionOverlayBezierSample {
    let point: CGPoint
    let theta: CGFloat
}

enum ActionOverlayBezierMode {
    case quartic(handleScale: CGFloat)
    case spiral(rotationDir: CGFloat, d1Scale: CGFloat)
    case degenerate
}

struct ActionOverlayBezierDiagnostics {
    let test: ActionOverlayTurnBoundTest
    let turning: CGFloat
    let pool: ActionOverlayCandidatePool
}

struct ActionOverlayTurnBoundTest {
    let passed: Bool
    let sampleCount: Int
    let violations: Int
    let worstRatio: CGFloat
    let worstWindow: CGFloat
    let worstPair: (i: Int, j: Int)?
    let maxDegPerPx: CGFloat
    let windowPx: CGFloat
}

struct ActionOverlayCandidatePool {
    let total: Int
    let passing: Int
}

struct ActionOverlayBezierPlan {
    let startPoint: CGPoint
    let endPoint: CGPoint
    let startHeading: CGFloat
    let endHeading: CGFloat
    let samples: [ActionOverlayBezierSample]
    let cumLen: [CGFloat]
    let totalLength: CGFloat
    let controlPoints: [CGPoint]
    let mode: ActionOverlayBezierMode
    var diagnostics: ActionOverlayBezierDiagnostics
}

// MARK: - Planner

/// Quartic (degree-4) Bezier path planner with spiral fallback.
///
/// Builds pose→pose curves that satisfy a turn-rate bound and chooses the
/// simplest passing curve from a candidate pool (plain quartic at multiple
/// handle scales; spiral quartic in both rotation directions if needed).
struct ActionOverlayBezierPlanner {
    /// Maximum heading change per pixel travelled (deg/px).
    var turnRate: CGFloat
    /// Bulge magnitude at full heading opposition (fraction of |P4−P0|).
    var bulgeMax: CGFloat
    /// Nominal travel speed (px/s), used for duration estimate.
    var speed: CGFloat
    /// Minimum animation duration (seconds).
    var durationMin: TimeInterval
    /// Maximum animation duration (seconds).
    var durationMax: TimeInterval

    // MARK: - Defaults

    static let `default` = ActionOverlayBezierPlanner(
        turnRate: 2.0,
        bulgeMax: 0.45,
        speed: 300,
        durationMin: 0.26,
        durationMax: 1.8
    )

    // MARK: - Public API

    /// Build the best curve from the candidate pool.
    func buildPlan(
        startPoint: CGPoint,
        startHeading: CGFloat,
        endPoint: CGPoint,
        endHeading: CGFloat
    ) -> ActionOverlayBezierPlan {
        let d = dist(startPoint, endPoint)
        if d < 0.5 {
            return degeneratePlan(
                startPoint: startPoint,
                startHeading: startHeading,
                endPoint: endPoint,
                endHeading: endHeading,
                distance: d
            )
        }

        let maxBulge = max(0, bulgeMax)

        // 1) Try plain quartics first — they always win over spirals in the
        // ranking because their total turning is strictly smaller.
        let quarticCandidates = quarticHandleScaleSweep().map { scale in
            evaluateCandidate(
                buildQuarticPlan(
                    startPoint: startPoint,
                    startHeading: startHeading,
                    endPoint: endPoint,
                    endHeading: endHeading,
                    handleScale: scale,
                    maxBulge: maxBulge
                )
            )
        }
        let quarticPassing = quarticCandidates.filter(\.test.passed)
        if !quarticPassing.isEmpty {
            return finalizePlan(
                rankCandidates(quarticPassing),
                evaluated: quarticCandidates.count,
                passingCount: quarticPassing.count
            )
        }

        // 2) No quartic passes — enumerate spirals and pool everything.
        var spiralCandidates: [Candidate] = []
        for dir in [CGFloat(1), CGFloat(-1)] {
            var v: CGFloat = 0.08
            while v <= 1.6 + 1e-9 {
                let d1s = CGFloat(round(v * 1000) / 1000)
                if let plan = buildSpiralQuarticPlan(
                    startPoint: startPoint,
                    startHeading: startHeading,
                    endPoint: endPoint,
                    endHeading: endHeading,
                    d1Scale: d1s,
                    rotationDir: dir
                ) {
                    spiralCandidates.append(evaluateCandidate(plan))
                }
                v += 0.04
            }
        }

        let all = quarticCandidates + spiralCandidates
        let passing = all.filter(\.test.passed)
        let pool = passing.isEmpty ? all : passing
        return finalizePlan(
            rankCandidates(pool),
            evaluated: all.count,
            passingCount: passing.count
        )
    }

    /// Sample the curve at a given arc-length distance from the start.
    func samplePlan(
        _ plan: ActionOverlayBezierPlan,
        atArcLength arcLength: CGFloat
    ) -> ActionOverlayBezierSample {
        let samples = plan.samples
        let cumLen = plan.cumLen
        let n = samples.count
        if arcLength <= 0 { return samples[0] }
        if arcLength >= plan.totalLength {
            return ActionOverlayBezierSample(point: plan.endPoint, theta: plan.endHeading)
        }

        var lo = 0
        var hi = n - 1
        while lo + 1 < hi {
            let mid = (lo + hi) >> 1
            if cumLen[mid] <= arcLength {
                lo = mid
            } else {
                hi = mid
            }
        }
        let span = cumLen[hi] - cumLen[lo]
        let t = span > 0 ? (arcLength - cumLen[lo]) / span : 0
        let a = samples[lo]
        let b = samples[hi]
        return ActionOverlayBezierSample(
            point: CGPoint(
                x: a.point.x + (b.point.x - a.point.x) * t,
                y: a.point.y + (b.point.y - a.point.y) * t
            ),
            theta: wrapAngle(
                a.theta + shortestAngleDelta(a.theta, b.theta) * t
            )
        )
    }

    /// Clamp curve duration to [durationMin, durationMax].
    func planDuration(_ plan: ActionOverlayBezierPlan) -> TimeInterval {
        let sec = plan.totalLength / speed
        return max(durationMin, min(durationMax, TimeInterval(sec)))
    }

    // MARK: - Internal types

    private struct Candidate {
        let plan: ActionOverlayBezierPlan
        let test: ActionOverlayTurnBoundTest
        let turning: CGFloat
    }

    // MARK: - Constants

    private static let baseHandleScale: CGFloat = 0.4
    private static let maxHandleScale: CGFloat = 4.0
    private static let handleScaleGrowth: CGFloat = 1.4
    private static let turnBoundWindowPx: CGFloat = 10
    private static let turnToleranceRad: CGFloat = 0.02 // ~1°

    // MARK: - Quartic Bezier

    private func buildQuarticPlan(
        startPoint: CGPoint,
        startHeading: CGFloat,
        endPoint: CGPoint,
        endHeading: CGFloat,
        handleScale: CGFloat,
        maxBulge: CGFloat
    ) -> ActionOverlayBezierPlan {
        let T1 = CGPoint(x: cos(startHeading), y: sin(startHeading))
        let T2 = CGPoint(x: cos(endHeading), y: sin(endHeading))

        let d = dist(startPoint, endPoint)
        let h = d * handleScale

        let P0 = startPoint
        let P4 = endPoint
        let P1 = CGPoint(x: P0.x + h * T1.x, y: P0.y + h * T1.y)
        let P3 = CGPoint(x: P4.x - h * T2.x, y: P4.y - h * T2.y)

        let directX = (P4.x - P0.x) / d
        let directY = (P4.y - P0.y) / d
        let normalX = -directY
        let normalY = directX
        let crossSum = (T1.x + T2.x) * directY - (T1.y + T2.y) * directX
        let sign: CGFloat = crossSum >= 0 ? 1 : -1

        let alignment = T1.x * directX + T1.y * directY
        let bulgeFactor = (1 - alignment) * 0.5
        let bulge = d * maxBulge * bulgeFactor * sign

        let midX = 0.5 * (P1.x + P3.x)
        let midY = 0.5 * (P1.y + P3.y)
        let P2 = CGPoint(x: midX + normalX * bulge, y: midY + normalY * bulge)

        let approxLen = d + abs(bulge) * 2 + h * 2
        let N = clamp(ceil(approxLen / 2), 120, 1600)
        let samples = buildQuarticSamples(
            P0: P0, P1: P1, P2: P2, P3: P3, P4: P4,
            count: Int(N),
            startHeading: startHeading,
            endHeading: endHeading
        )

        var cumLen = [CGFloat](repeating: 0, count: samples.count)
        for i in 1 ..< samples.count {
            cumLen[i] = cumLen[i - 1] + dist(samples[i - 1].point, samples[i].point)
        }

        return ActionOverlayBezierPlan(
            startPoint: startPoint,
            endPoint: endPoint,
            startHeading: startHeading,
            endHeading: endHeading,
            samples: samples,
            cumLen: cumLen,
            totalLength: cumLen.last ?? 0,
            controlPoints: [P0, P1, P2, P3, P4],
            mode: .quartic(handleScale: handleScale),
            diagnostics: ActionOverlayBezierDiagnostics(
                test: verifyTurnBound(samples: samples),
                turning: totalTurning(samples),
                pool: ActionOverlayCandidatePool(total: 0, passing: 0)
            )
        )
    }

    private func buildQuarticSamples(
        P0: CGPoint, P1: CGPoint, P2: CGPoint, P3: CGPoint, P4: CGPoint,
        count: Int,
        startHeading: CGFloat,
        endHeading: CGFloat
    ) -> [ActionOverlayBezierSample] {
        let N = count
        var samples = [ActionOverlayBezierSample]()
        samples.reserveCapacity(N + 1)

        for i in 0 ... N {
            let t = CGFloat(i) / CGFloat(N)
            let v = evalQuartic(P0: P0, P1: P1, P2: P2, P3: P3, P4: P4, t: t)
            let mag = hypot(v.dx, v.dy)
            let theta: CGFloat = if mag < 1e-6 {
                if i == 0 {
                    startHeading
                } else if i == N {
                    endHeading
                } else {
                    samples[i - 1].theta
                }
            } else {
                atan2(v.dy, v.dx)
            }
            samples.append(ActionOverlayBezierSample(
                point: CGPoint(x: v.x, y: v.y),
                theta: theta
            ))
        }
        samples[0] = ActionOverlayBezierSample(point: P0, theta: startHeading)
        samples[N] = ActionOverlayBezierSample(point: P4, theta: endHeading)
        return samples
    }

    private func evalQuartic(
        P0: CGPoint, P1: CGPoint, P2: CGPoint, P3: CGPoint, P4: CGPoint,
        t: CGFloat
    ) -> (x: CGFloat, y: CGFloat, dx: CGFloat, dy: CGFloat) {
        let u = 1 - t
        let u4 = u * u * u * u
        let u3t = u * u * u * t
        let u2t2 = u * u * t * t
        let ut3 = u * t * t * t
        let t4 = t * t * t * t

        let x = u4 * P0.x + 4 * u3t * P1.x + 6 * u2t2 * P2.x + 4 * ut3 * P3.x + t4 * P4.x
        let y = u4 * P0.y + 4 * u3t * P1.y + 6 * u2t2 * P2.y + 4 * ut3 * P3.y + t4 * P4.y

        let u3 = u * u * u
        let u2t = u * u * t
        let ut2 = u * t * t
        let t3 = t * t * t
        let dx = 4 * (
            u3 * (P1.x - P0.x) +
                3 * u2t * (P2.x - P1.x) +
                3 * ut2 * (P3.x - P2.x) +
                t3 * (P4.x - P3.x)
        )
        let dy = 4 * (
            u3 * (P1.y - P0.y) +
                3 * u2t * (P2.y - P1.y) +
                3 * ut2 * (P3.y - P2.y) +
                t3 * (P4.y - P3.y)
        )
        return (x, y, dx, dy)
    }

    // MARK: - Spiral quartic

    private func buildSpiralQuarticPlan(
        startPoint: CGPoint,
        startHeading: CGFloat,
        endPoint: CGPoint,
        endHeading: CGFloat,
        d1Scale: CGFloat,
        rotationDir: CGFloat
    ) -> ActionOverlayBezierPlan? {
        let d = dist(startPoint, endPoint)
        if d < 0.5 { return nil }

        let α0 = startHeading
        let shortest = shortestAngleDelta(α0, endHeading)
        let totalRotation = shortest + rotationDir * 2 * .pi
        let δ = totalRotation / 3
        let α1 = α0 + δ
        let α2 = α0 + 2 * δ
        let α3 = α0 + 3 * δ

        let u0 = CGPoint(x: cos(α0), y: sin(α0))
        let u1 = CGPoint(x: cos(α1), y: sin(α1))
        let u2 = CGPoint(x: cos(α2), y: sin(α2))
        let u3 = CGPoint(x: cos(α3), y: sin(α3))

        let d1 = d * d1Scale
        let d4 = d1
        let Rx = (endPoint.x - startPoint.x) - d1 * u0.x - d4 * u3.x
        let Ry = (endPoint.y - startPoint.y) - d1 * u0.y - d4 * u3.y
        let det = u1.x * u2.y - u1.y * u2.x
        if abs(det) < 1e-6 { return nil }
        let d2 = (Rx * u2.y - Ry * u2.x) / det
        let d3 = (u1.x * Ry - u1.y * Rx) / det
        if d2 <= 0 || d3 <= 0 { return nil }

        let P0 = startPoint
        let P1 = CGPoint(x: P0.x + d1 * u0.x, y: P0.y + d1 * u0.y)
        let P2 = CGPoint(x: P1.x + d2 * u1.x, y: P1.y + d2 * u1.y)
        let P3 = CGPoint(x: P2.x + d3 * u2.x, y: P2.y + d3 * u2.y)
        let P4 = endPoint

        let approxLen = d1 + d2 + d3 + d4
        let N = clamp(ceil(approxLen / 1.5), 200, 2400)
        let samples = buildQuarticSamples(
            P0: P0, P1: P1, P2: P2, P3: P3, P4: P4,
            count: Int(N),
            startHeading: startHeading,
            endHeading: endHeading
        )

        var cumLen = [CGFloat](repeating: 0, count: samples.count)
        for i in 1 ..< samples.count {
            cumLen[i] = cumLen[i - 1] + dist(samples[i - 1].point, samples[i].point)
        }

        return ActionOverlayBezierPlan(
            startPoint: startPoint,
            endPoint: endPoint,
            startHeading: startHeading,
            endHeading: endHeading,
            samples: samples,
            cumLen: cumLen,
            totalLength: cumLen.last ?? 0,
            controlPoints: [P0, P1, P2, P3, P4],
            mode: .spiral(rotationDir: rotationDir, d1Scale: d1Scale),
            diagnostics: ActionOverlayBezierDiagnostics(
                test: verifyTurnBound(samples: samples),
                turning: totalTurning(samples),
                pool: ActionOverlayCandidatePool(total: 0, passing: 0)
            )
        )
    }

    // MARK: - Turn-bound test

    private func verifyTurnBound(
        samples: [ActionOverlayBezierSample]
    ) -> ActionOverlayTurnBoundTest {
        let n = samples.count
        if n < 2 {
            return ActionOverlayTurnBoundTest(
                passed: true, sampleCount: n, violations: 0,
                worstRatio: 0, worstWindow: 0, worstPair: nil,
                maxDegPerPx: turnRate, windowPx: Self.turnBoundWindowPx
            )
        }

        var cumLen = [CGFloat](repeating: 0, count: n)
        for i in 1 ..< n {
            cumLen[i] = cumLen[i - 1] + dist(samples[i - 1].point, samples[i].point)
        }

        let maxRadPerPx = (turnRate * .pi) / 180
        let tol: CGFloat = 1.002
        var worstRatio: CGFloat = 0
        var worstWindow: CGFloat = 0
        var worstPair: (i: Int, j: Int)?
        var violations = 0

        var j = 0
        for i in 0 ..< n {
            if j < i { j = i }
            while j < n, cumLen[j] - cumLen[i] <= Self.turnBoundWindowPx {
                let arcLen = cumLen[j] - cumLen[i]
                if arcLen > 1e-6 {
                    let dTheta = abs(shortestAngleDelta(samples[i].theta, samples[j].theta))
                    let allowed = maxRadPerPx * arcLen
                    if dTheta > allowed * tol { violations += 1 }
                    let ratio = dTheta / allowed
                    if ratio > worstRatio {
                        worstRatio = ratio
                        worstWindow = arcLen
                        worstPair = (i, j)
                    }
                }
                j += 1
            }
        }

        return ActionOverlayTurnBoundTest(
            passed: violations == 0,
            sampleCount: n,
            violations: violations,
            worstRatio: worstRatio,
            worstWindow: worstWindow,
            worstPair: worstPair,
            maxDegPerPx: turnRate,
            windowPx: Self.turnBoundWindowPx
        )
    }

    // MARK: - Candidate helpers

    private func quarticHandleScaleSweep() -> [CGFloat] {
        var scales: [CGFloat] = [Self.baseHandleScale]
        var s = Self.baseHandleScale
        while s < Self.maxHandleScale {
            s = min(s * Self.handleScaleGrowth, Self.maxHandleScale)
            scales.append(s)
            if s >= Self.maxHandleScale - 1e-6 { break }
        }
        return scales
    }

    private func evaluateCandidate(_ plan: ActionOverlayBezierPlan) -> Candidate {
        let test = verifyTurnBound(samples: plan.samples)
        return Candidate(
            plan: plan,
            test: test,
            turning: totalTurning(plan.samples)
        )
    }

    private func rankCandidates(_ pool: [Candidate]) -> Candidate {
        pool.sorted { a, b in
            if a.test.passed != b.test.passed { return a.test.passed }
            let turnDiff = a.turning - b.turning
            if abs(turnDiff) > Self.turnToleranceRad { return turnDiff < 0 }
            return a.plan.totalLength < b.plan.totalLength
        }[0]
    }

    private func finalizePlan(
        _ winner: Candidate,
        evaluated: Int,
        passingCount: Int
    ) -> ActionOverlayBezierPlan {
        var plan = winner.plan
        plan.diagnostics = ActionOverlayBezierDiagnostics(
            test: winner.test,
            turning: winner.turning,
            pool: ActionOverlayCandidatePool(
                total: evaluated,
                passing: passingCount
            )
        )
        return plan
    }

    private func degeneratePlan(
        startPoint: CGPoint,
        startHeading: CGFloat,
        endPoint: CGPoint,
        endHeading: CGFloat,
        distance: CGFloat
    ) -> ActionOverlayBezierPlan {
        let samples = [
            ActionOverlayBezierSample(point: startPoint, theta: startHeading),
            ActionOverlayBezierSample(point: endPoint, theta: endHeading),
        ]
        return ActionOverlayBezierPlan(
            startPoint: startPoint,
            endPoint: endPoint,
            startHeading: startHeading,
            endHeading: endHeading,
            samples: samples,
            cumLen: [0, distance],
            totalLength: distance,
            controlPoints: [startPoint, startPoint, startPoint, endPoint, endPoint],
            mode: .degenerate,
            diagnostics: ActionOverlayBezierDiagnostics(
                test: ActionOverlayTurnBoundTest(
                    passed: true, sampleCount: 2, violations: 0,
                    worstRatio: 0, worstWindow: 0, worstPair: nil,
                    maxDegPerPx: turnRate, windowPx: Self.turnBoundWindowPx
                ),
                turning: 0,
                pool: ActionOverlayCandidatePool(total: 1, passing: 1)
            )
        )
    }

    private func totalTurning(_ samples: [ActionOverlayBezierSample]) -> CGFloat {
        var sum: CGFloat = 0
        for i in 1 ..< samples.count {
            sum += abs(shortestAngleDelta(samples[i - 1].theta, samples[i].theta))
        }
        return sum
    }

    // MARK: - Geometry utilities

    private func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(b.x - a.x, b.y - a.y)
    }

    private func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        min(hi, max(lo, v))
    }

    private func wrapAngle(_ a: CGFloat) -> CGFloat {
        var v = a
        while v > .pi {
            v -= 2 * .pi
        }
        while v <= -.pi {
            v += 2 * .pi
        }
        return v
    }

    private func shortestAngleDelta(_ from: CGFloat, _ to: CGFloat) -> CGFloat {
        wrapAngle(to - from)
    }
}
