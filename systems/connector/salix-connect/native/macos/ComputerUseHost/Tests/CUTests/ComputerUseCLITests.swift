import AppKit
import ApplicationServices
import CoreGraphics
@testable import CUBackground
@testable import CUShared
import Testing

@Test
func parsesGetAppStateCommand() throws {
    let command = try ComputerUseCLI.parse(arguments: [
        "get-app-state",
        "--app", "Finder",
        "--window-title", "Recents",
    ])

    #expect(command == .getAppState(app: "Finder", windowTitle: "Recents"))
}

@Test
func parsesClickCommandWithCoordinates() throws {
    let command = try ComputerUseCLI.parse(arguments: [
        "click",
        "--snapshot-id", "abc",
        "--x", "1432",
        "--y", "378",
    ])

    #expect(command == .click(snapshotID: "abc", elementIndex: nil, x: 1432, y: 378))
}

@Test
func parsesScrollCommandWithPages() throws {
    let command = try ComputerUseCLI.parse(arguments: [
        "scroll",
        "--snapshot-id", "snap",
        "--element-index", "32",
        "--direction", "down",
        "--pages", "2",
    ])

    #expect(command == .scroll(snapshotID: "snap", elementIndex: 32, direction: "down", pages: 2))
}

@Test
func rejectsInvalidIntegerFlag() throws {
    #expect(throws: ComputerUseCLIError.invalidInteger(flag: "--element-index", value: "x")) {
        try ComputerUseCLI.parse(arguments: [
            "set-value",
            "--snapshot-id", "snap",
            "--element-index", "x",
            "--value", "hello",
        ])
    }
}

@Test
func screenshotCoordinatesConvertToWindowLocalSpace() {
    let point = windowLocalPoint(
        fromScreenshotPixel: CGPoint(x: 250, y: 200),
        screenshotSize: CGSize(width: 1000, height: 800),
        windowFrame: CGRect(x: 262, y: 104, width: 500, height: 400)
    )

    #expect(point == CGPoint(x: 125, y: 300))
}

@Test
func actionDisplayNamesStripAXPrefixAndByPage() {
    #expect(displayName(forAction: "AXScrollDownByPage") == "Scroll Down")
    #expect(displayName(forAction: "AXRaise") == "Raise")
}

@Test
func formattedStateIncludesScreenshotSizeWhenAvailable() {
    let element = AXUIElementCreateSystemWide()
    let app = NSRunningApplication.current
    let snapshot = RuntimeAppSnapshot(
        app: app,
        appElement: element,
        windowElement: element,
        windowID: 42,
        windowLayer: 0,
        windowTitle: "Test Window",
        windowFrame: CGRect(x: 10, y: 20, width: 300, height: 200),
        nodes: [],
        focusedElementIndex: nil,
        selectedText: nil,
        screenshotURL: nil,
        screenshotSize: CGSize(width: 1994, height: 1374),
        fingerprint: "fingerprint"
    )
    let metadata = ComputerUseSnapshotMetadata(
        id: "snapshot",
        createdAt: Date(timeIntervalSince1970: 0),
        appName: app.localizedName ?? "Tests",
        bundleID: app.bundleIdentifier ?? "tests.bundle",
        pid: app.processIdentifier,
        windowTitle: "Test Window",
        windowID: 42,
        windowFrame: CGRectCodable(CGRect(x: 10, y: 20, width: 300, height: 200)),
        screenshotPath: "/tmp/test.png",
        screenshotSize: CGSizeCodable(CGSize(width: 1994, height: 1374)),
        fingerprint: "fingerprint",
        nodeSignatures: []
    )

    let output = ComputerUseCore.formattedState(snapshot: snapshot, metadata: metadata)
    #expect(output.text.contains("Screenshot: /tmp/test.png"))
    #expect(output.text.contains("ScreenshotSize: 1994x1374"))
}

@Test
func overlayOriginCentersCursorAroundTargetPoint() {
    let origin = overlayOrigin(
        for: CGPoint(x: 120, y: 80),
        size: CGSize(width: 34, height: 34)
    )

    #expect(origin == CGPoint(x: 103, y: 63))
}

@Test
func dragUsesApproachAnimation() {
    #expect(ActionOverlayKind.drag(button: .left).usesApproachAnimation)
}

@Test
func dragStrokeDurationDefaultsTo300ms() {
    #expect(ActionOverlayTiming.dragDuration == 0.3)
}

@Test
func appKitScreenRoundTripPreservesWindowLocalPoint() {
    guard
        let screen = NSScreen.screens.first,
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    else {
        return
    }

    let displayID = CGDirectDisplayID(number.uint32Value)
    let axFrame = CGDisplayBounds(displayID)
    let windowFrame = CGRect(
        x: axFrame.minX + 160,
        y: axFrame.minY + 120,
        width: 640,
        height: 480
    )
    let localPoint = CGPoint(x: 180, y: 180)

    let appKitPoint = overlayScreenPointForLocalPoint(
        windowLocalPoint: localPoint,
        windowFrame: windowFrame
    )
    let roundTripped = translatedWindowLocalPoint(
        fromAppKitScreenPoint: appKitPoint,
        windowFrame: windowFrame
    )

    #expect(abs(roundTripped.x - localPoint.x) < 0.001)
    #expect(abs(roundTripped.y - localPoint.y) < 0.001)
}

@Test
func mergeAXWindowCandidatesFallsBackToFocusedAndMainWindows() {
    let focused = AXUIElementCreateApplication(1001)
    let duplicateFocused = AXUIElementCreateApplication(1001)
    let main = AXUIElementCreateApplication(1002)

    let merged = mergeAXWindowCandidates(
        listedWindows: [],
        focusedWindow: focused,
        mainWindow: duplicateFocused
    )
    let withDistinctMain = mergeAXWindowCandidates(
        listedWindows: [],
        focusedWindow: focused,
        mainWindow: main
    )

    #expect(merged.count == 1)
    #expect(CFEqual(merged[0], focused))
    #expect(withDistinctMain.count == 2)
}
