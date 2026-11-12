import CoreGraphics
@testable import CUShared
import Testing

/// The agent cursor's approach holds every action back: across a whole display, with a reversed heading, it stays
/// within 0.3 s (it was up to 1.8 s, most of a background click's time).
@Test
func cursorApproachAcrossTheDisplayStaysShort() {
    let planner = ActionOverlayBezierPlanner.default
    let plan = planner.buildPlan(
        startPoint: CGPoint(x: 0, y: 0),
        startHeading: .pi,
        endPoint: CGPoint(x: 2560, y: 1440),
        endHeading: 0
    )
    #expect(planner.planDuration(plan) <= 0.3)
}
