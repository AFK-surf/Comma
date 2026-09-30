import Testing

@testable import NotchHost

@Test func logoAnimationInterpolatesUsingTheSourceBezier() {
    // x(t) = 2.785t³ - 4.095t² + 2.31t. Its root at x=0.5 is
    // t=0.5643355196807716; y(t)=3t²-2t³=0.5959707024857342 (not linear).
    let expectedProgress = 0.5959707024857342
    let frame = CommaNotchLogoAnimationValues.animationFrame(elapsed: 1)
    #expect(abs((frame.zoom - 1) / (2.7756653992 - 1) - expectedProgress) < 0.000_02)
    #expect(abs(frame.translationX / -1140.7984790875 - expectedProgress) < 0.000_02)
    #expect(abs(frame.translationY / -1118.5931558935 - expectedProgress) < 0.000_02)
    #expect(frame.nestedScale > 0.5)
    #expect(frame.nestedScale < expectedProgress)
}

@Test func logoAnimationApproachesTheHoldContinuouslyAndMonotonically() {
    let final = CommaNotchLogoAnimationValues.animationFrame(elapsed: 2)
    let almost = CommaNotchLogoAnimationValues.animationFrame(elapsed: 1.999)
    #expect(almost.zoom < final.zoom)
    #expect(final.zoom - almost.zoom < 0.000_01)
    #expect(almost.nestedScale < final.nestedScale)
    #expect(final.nestedScale - almost.nestedScale < 0.000_01)

    var previous = CommaNotchLogoAnimationValues.animationFrame(elapsed: 0)
    for step in 1...200 {
        let current = CommaNotchLogoAnimationValues.animationFrame(elapsed: Double(step) / 100)
        #expect(current.zoom > previous.zoom)
        #expect(current.translationX < previous.translationX)
        #expect(current.translationY < previous.translationY)
        #expect(current.nestedScale >= previous.nestedScale)
        #expect(current.zoom <= final.zoom)
        #expect(current.nestedScale <= 1)
        previous = current
    }
    #expect(CommaNotchLogoAnimationValues.animationFrame(elapsed: 0.02).nestedScale == 0.001)
    #expect(CommaNotchLogoAnimationValues.animationFrame(elapsed: 0.03).nestedScale > 0.001)
}

@Test func logoAnimationZoomsHoldsAndLoops() {
    let initial = CommaNotchLogoAnimationValues.animationFrame(elapsed: 0)
    #expect(initial.zoom == 1)
    #expect(initial.translationX == 0)
    #expect(initial.translationY == 0)
    #expect(initial.nestedScale == 0.001)

    let zoomed = CommaNotchLogoAnimationValues.animationFrame(elapsed: 2)
    #expect(zoomed.zoom == 2.7756653992)
    #expect(zoomed.translationX == -1140.7984790875)
    #expect(zoomed.translationY == -1118.5931558935)
    #expect(zoomed.nestedScale == 1)

    let held = CommaNotchLogoAnimationValues.animationFrame(elapsed: 3)
    #expect(held.zoom == zoomed.zoom)
    #expect(held.translationX == zoomed.translationX)
    #expect(held.translationY == zoomed.translationY)
    #expect(held.nestedScale == zoomed.nestedScale)

    let looped = CommaNotchLogoAnimationValues.animationFrame(elapsed: 3.4)
    #expect(abs(looped.zoom - initial.zoom) < 0.000_001)
    #expect(abs(looped.translationX - initial.translationX) < 0.000_001)
    #expect(abs(looped.translationY - initial.translationY) < 0.000_001)
    #expect(abs(looped.nestedScale - initial.nestedScale) < 0.000_001)
}

@Test func logoAnimationFadesTheOutgoingRingBeforeItThinsToALine() {
    #expect(CommaNotchLogoAnimationValues.animationFrame(elapsed: 0).ringOpacity == 1)
    #expect(CommaNotchLogoAnimationValues.animationFrame(elapsed: 0.8).ringOpacity == 1)
    let fading = CommaNotchLogoAnimationValues.animationFrame(elapsed: 0.9).ringOpacity
    #expect(fading > 0 && fading < 1)
    // From here the ring is a crescent a few points thick and closing.
    #expect(CommaNotchLogoAnimationValues.animationFrame(elapsed: 0.97).ringOpacity == 0)
    #expect(CommaNotchLogoAnimationValues.animationFrame(elapsed: 3).ringOpacity == 0)
    // The loop starts on the whole logo again, and a static logo keeps its ring.
    #expect(abs(CommaNotchLogoAnimationValues.animationFrame(elapsed: 3.4).ringOpacity - 1) < 0.000_001)
    #expect(CommaNotchLogoAnimationValues().ringOpacity == 1)
}
