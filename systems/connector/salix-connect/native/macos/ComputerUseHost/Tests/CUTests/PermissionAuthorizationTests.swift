import XCTest
import CUShared
@testable import CommaComputerUseDaemon

final class PermissionAuthorizationTests: XCTestCase {
    func testNestedHelperGuidesScreenRecordingToTheContainingApp() {
        let app = URL(fileURLWithPath: "/Applications/Comma.app")
        let helper = app.appendingPathComponent(
            "Contents/Resources/native/darwin/arm64/native/macos/Comma Computer Use.app"
        )
        XCTAssertEqual(permissionAuthorizationAppURL(for: .accessibility, helperBundleURL: helper), helper)
        XCTAssertEqual(permissionAuthorizationAppURL(for: .screenRecording, helperBundleURL: helper).path, app.path)
    }

    func testStandaloneHelperGuidesBothPermissionsToItself() {
        let helper = URL(fileURLWithPath: "/Applications/Comma Computer Use.app")
        XCTAssertEqual(permissionAuthorizationAppURL(for: .accessibility, helperBundleURL: helper), helper)
        XCTAssertEqual(permissionAuthorizationAppURL(for: .screenRecording, helperBundleURL: helper), helper)
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
