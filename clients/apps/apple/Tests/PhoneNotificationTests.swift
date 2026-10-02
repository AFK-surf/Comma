import XCTest
import CommaCore
import UserNotifications
@testable import Comma

@MainActor final class PhoneNotificationTests: XCTestCase {
    func testPushEnvironmentUsesInfoContractAndRejectsUnknownRatherThanSandboxFallback() throws {
        XCTAssertEqual(try AppConfiguration.pushEnvironment(value: "development"), .sandbox)
        XCTAssertEqual(try AppConfiguration.pushEnvironment(value: "sandbox"), .sandbox)
        XCTAssertEqual(try AppConfiguration.pushEnvironment(value: "production"), .production)
        XCTAssertThrowsError(try AppConfiguration.pushEnvironment(value: nil))
        XCTAssertThrowsError(try AppConfiguration.pushEnvironment(value: "typo"))
    }

    func testQuietPresentationRequiresProvisionalOrVerifiedNotificationCenterOnly() {
        let normal = PhoneNotificationSystem.permission(authorization: .authorized, alert: .enabled, lockScreen: .enabled, center: .enabled)
        XCTAssertEqual(normal.authorization, .allowed)
        XCTAssertFalse(normal.quiet, "Muted sounds or Focus are not inputs to quiet classification")
        let centerOnly = PhoneNotificationSystem.permission(authorization: .authorized, alert: .disabled, lockScreen: .disabled, center: .enabled)
        XCTAssertTrue(centerOnly.quiet)
        let lockScreen = PhoneNotificationSystem.permission(authorization: .authorized, alert: .disabled, lockScreen: .enabled, center: .enabled)
        XCTAssertFalse(lockScreen.quiet)
        let provisional = PhoneNotificationSystem.permission(authorization: .provisional, alert: .disabled, lockScreen: .disabled, center: .enabled)
        XCTAssertTrue(provisional.quiet)
        let denied = PhoneNotificationSystem.permission(authorization: .denied, alert: .disabled, lockScreen: .disabled, center: .disabled)
        XCTAssertEqual(denied.authorization, .denied)
    }

    func testTokenAcquisitionTimeoutSettlesAndAnotherExplicitAttemptCanRetry() async {
        var acquisitions = 0
        let system = PhoneNotificationSystem(acquisitionTimeout: .milliseconds(1), acquire: { acquisitions += 1 })
        for _ in 0..<2 {
            do { _ = try await system.deviceToken(); XCTFail("Missing APNs callback must time out") }
            catch { XCTAssertEqual(error as? CommaError, .transport) }
        }
        XCTAssertEqual(acquisitions, 2)
    }
}
