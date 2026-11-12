import CoreGraphics
@testable import CUShared
import Testing

@Test
func backgroundDispatchFlagUsesCommandMask() {
    #expect(backgroundDispatchFlag == .maskCommand)
    #expect(backgroundDispatchFlag.rawValue == 0x0010_0000)
    #expect(backgroundDispatchFlag != .maskNonCoalesced)
}

@Test
func backgroundDispatchFlagsAddCommandBitForBackgroundTargets() {
    let flags = backgroundDispatchFlags(
        modifierFlags: .maskShift,
        isTargetActive: false
    )

    #expect(flags.contains(.maskShift))
    #expect(flags.contains(.maskCommand))
}

@Test
func backgroundDispatchFlagsLeaveActiveTargetsUntouched() {
    let flags = backgroundDispatchFlags(
        modifierFlags: .maskAlternate,
        isTargetActive: true
    )

    #expect(flags == .maskAlternate)
}

@Test
func coordinateTransformsRoundTripBetweenWindowAndScreenSpace() {
    let windowFrame = CGRect(x: 262, y: 104, width: 500, height: 532)
    let localPoint = CGPoint(x: 125, y: 100)

    let screenPoint = translatedScreenPoint(
        windowLocalPoint: localPoint,
        windowFrame: windowFrame
    )
    let reconstructedLocalPoint = translatedWindowLocalPoint(
        screenPoint: screenPoint,
        windowFrame: windowFrame
    )

    #expect(screenPoint == CGPoint(x: 387, y: 536))
    #expect(reconstructedLocalPoint == localPoint)
}

@Test
func backgroundClickFieldConstantsMatchCoreGraphicsDefinitions() {
    #expect(buttonNumberField.rawValue == 3)
    #expect(mouseSubtypeField.rawValue == 7)
    #expect(CGEventField(rawValue: 91)?.rawValue == 91)
    #expect(CGEventField(rawValue: 92)?.rawValue == 92)
}
