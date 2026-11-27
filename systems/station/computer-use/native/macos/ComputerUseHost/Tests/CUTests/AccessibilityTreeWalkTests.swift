import AppKit
import ApplicationServices
import XCTest
@testable import CUBackground

/// `get_app_state` reads a window's accessibility tree on the daemon's main thread. A tree that leads back to an
/// element it already holds, or that has no end, must not keep the thread and grow the daemon's memory without bound.
final class AccessibilityTreeWalkTests: XCTestCase {
    func testTheSameElementReadAgainIsOneElement() {
        let pid = getpid()
        let first = AXUIElementCreateApplication(pid)
        let again = AXUIElementCreateApplication(pid)
        XCTAssertFalse(first === again, "accessibility gives a new object each time")
        XCTAssertEqual(AXElementKey(first), AXElementKey(again))
        XCTAssertEqual(Set([AXElementKey(first), AXElementKey(again)]).count, 1)
    }

    func testATreeThatLeadsBackIsWalkedOnceInOrder() {
        // 0 → 1, 2; 1 → 3, 0 (back to the root); 3 → 1 (back to its parent).
        let children: [Int: [Int]] = [0: [1, 2], 1: [3, 0], 3: [1]]
        var seen: [(Int, Int)] = []
        let cut = ComputerUseCore.walkTree(from: 0, limit: 100, children: { children[$0] ?? [] }) { seen.append(($0, $1)) }
        XCTAssertFalse(cut)
        XCTAssertEqual(seen.map(\.0), [0, 1, 3, 2])
        XCTAssertEqual(seen.map(\.1), [0, 1, 2, 1])
    }

    func testATreeWithNoEndStopsAtTheLimit() {
        var visited = 0
        let cut = ComputerUseCore.walkTree(from: 0, limit: 50, children: { [$0 + 1, $0 + 2] }) { _, _ in visited += 1 }
        XCTAssertTrue(cut)
        XCTAssertEqual(visited, 50)
    }

    func testATreeOfExactlyTheLimitIsWhole() {
        var visited = 0
        let cut = ComputerUseCore.walkTree(from: 0, limit: 3, children: { $0 < 2 ? [$0 + 1] : [] }) { _, _ in visited += 1 }
        XCTAssertFalse(cut)
        XCTAssertEqual(visited, 3)
    }

    func testAWideContainerDoesNotEnqueueChildrenPastTheRemainingLimit() {
        let wideChildren = [1, 1, 2] + Array(3 ... 50000)
        var seen: [(Int, Int)] = []
        let cut = ComputerUseCore.walkTree(
            from: 0,
            limit: 5,
            children: { $0 == 0 ? wideChildren : [] }
        ) { seen.append(($0, $1)) }
        XCTAssertTrue(cut)
        XCTAssertEqual(seen.map(\.0), [0, 1, 2, 3, 4])
        XCTAssertEqual(seen.map(\.1), [0, 1, 1, 1, 1])
    }

    func testAXMessagingTimeoutAppliesToAppElement() {
        let appElement = AXUIElementCreateApplication(getpid())
        XCTAssertEqual(ComputerUseCore.configureAXMessagingTimeout(appElement), .success)
    }

    func testFormattedStateReportsWhenElementsAreCut() {
        let cutLine = "The window has more elements than these"
        XCTAssertTrue(formattedText(nodesCut: true).contains(cutLine))
        XCTAssertFalse(formattedText(nodesCut: false).contains(cutLine))
    }

    private func formattedText(nodesCut: Bool) -> String {
        let element = AXUIElementCreateSystemWide()
        let app = NSRunningApplication.current
        let frame = CGRect(x: 10, y: 20, width: 300, height: 200)
        let snapshot = RuntimeAppSnapshot(
            app: app,
            appElement: element,
            windowElement: element,
            windowID: 42,
            windowLayer: 0,
            windowTitle: "Test Window",
            windowFrame: frame,
            nodes: [],
            focusedElementIndex: nil,
            selectedText: nil,
            screenshotURL: nil,
            screenshotSize: nil,
            fingerprint: "fingerprint",
            nodesCut: nodesCut
        )
        let metadata = ComputerUseSnapshotMetadata(
            id: "snapshot",
            createdAt: Date(timeIntervalSince1970: 0),
            appName: app.localizedName ?? "Tests",
            bundleID: app.bundleIdentifier ?? "tests.bundle",
            pid: app.processIdentifier,
            windowTitle: "Test Window",
            windowID: 42,
            windowFrame: CGRectCodable(frame),
            screenshotPath: nil,
            screenshotSize: nil,
            fingerprint: "fingerprint",
            nodeSignatures: []
        )
        return ComputerUseCore.formattedState(snapshot: snapshot, metadata: metadata).text
    }
}
