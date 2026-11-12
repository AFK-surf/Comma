import XCTest
import CUShared
@testable import CommaComputerUseDaemon

final class PermissionAuthorizationTests: XCTestCase {
    func testInstallsOutsideContainingAppAndUpdatesWithoutChangingIdentity() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? files.removeItem(at: root) }
        let source = root.appendingPathComponent("Comma.app/Contents/Resources/Comma Computer Use.app")
        let directory = root.appendingPathComponent("Application Support/Computer Use")
        let codeFiles = ["Contents/MacOS/CommaComputerUseDaemon", "Contents/Info.plist",
                         "Contents/_CodeSignature/CodeResources"]
        for path in codeFiles {
            let file = source.appendingPathComponent(path)
            try files.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("original".utf8).write(to: file)
        }
        XCTAssertTrue(StandaloneApplication.isNested(source))
        let installed = try StandaloneApplication.install(source: source, directory: directory)
        XCTAssertFalse(StandaloneApplication.isNested(installed))
        XCTAssertEqual(try Data(contentsOf: installed.appendingPathComponent(codeFiles[0])), Data("original".utf8))
        let before = try files.attributesOfItem(atPath: installed.path)[.modificationDate] as? Date
        XCTAssertEqual(try StandaloneApplication.install(source: source, directory: directory), installed)
        XCTAssertEqual(try files.attributesOfItem(atPath: installed.path)[.modificationDate] as? Date, before)

        let unrelated = directory.appendingPathComponent("user-data")
        try Data("retained".utf8).write(to: unrelated)
        try Data("updated".utf8).write(to: source.appendingPathComponent(codeFiles[0]))
        XCTAssertEqual(try StandaloneApplication.install(source: source, directory: directory), installed)
        XCTAssertEqual(try Data(contentsOf: installed.appendingPathComponent(codeFiles[0])), Data("updated".utf8))
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("retained".utf8))

        try files.removeItem(at: source)
        XCTAssertThrowsError(try StandaloneApplication.install(source: source, directory: directory))
        XCTAssertEqual(try Data(contentsOf: installed.appendingPathComponent(codeFiles[0])), Data("updated".utf8))
    }

    @MainActor
    func testAdvancesOnlyAfterTheRequestedPermissionIsGranted() {
        var accessibility = false
        var screenshots = false
        let model = PermissionAuthViewModel { pane in
            pane == .accessibility ? accessibility : screenshots
        }
        var snapshots: [[Bool]] = []
        model.onRowsChanged = { snapshots.append($0.map(\.granted)) }
        var opened: [PermissionPane] = []
        model.onAuthorize = { opened.append($0) }
        model.refresh()
        XCTAssertTrue(opened.isEmpty)
        model.beginAuthorization(.accessibility)
        model.refresh()
        XCTAssertEqual(opened, [.accessibility])
        accessibility = true
        model.refresh()
        model.refresh()
        XCTAssertEqual(opened, [.accessibility, .screenRecording])
        screenshots = true
        model.refresh()
        XCTAssertTrue(model.allGranted)
        XCTAssertEqual(snapshots, [[true, false], [true, true]])
        XCTAssertEqual(opened, [.accessibility, .screenRecording])
        model.stopPolling()
    }

    @MainActor
    func testClosingStopsAutomaticProgression() {
        var granted = false
        let model = PermissionAuthViewModel { $0 == .accessibility && granted }
        var opened: [PermissionPane] = []
        model.onAuthorize = { opened.append($0) }
        model.beginAuthorization(.accessibility)
        model.stopPolling()
        granted = true
        model.refresh()
        XCTAssertEqual(opened, [.accessibility])
        model.stopPolling()
    }
}
