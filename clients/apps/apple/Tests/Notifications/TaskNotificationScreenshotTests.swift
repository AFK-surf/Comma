#if os(iOS)
import XCTest
import SwiftUI
import UIKit
import CommaCore
@testable import Comma

/// UI evidence for the production section, not APNs delivery or real-device permission evidence.
/// All consent transitions use the controller API; the only injected dependencies are test doubles.
@MainActor final class TaskNotificationScreenshotTests: XCTestCase {
    func testProductionTaskAlertsSettingsScreenshotsInEnglishAndSimplifiedChinese() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)

        for language in ["en", "zh-Hans"] {
            let strings = try localizedBundle(language: language)
            // Exercise the compiled app catalog, rather than reading or duplicating xcstrings source.
            for key in ["Settings", "Message notifications", "Task updates", "Retry",
                        "Task alerts won’t show task titles or content. Router replies appear as message alerts."] {
                let value = strings.localizedString(forKey: key, value: nil, table: "Localizable")
                XCTAssertFalse(value.isEmpty)
                if language == "zh-Hans" { XCTAssertNotEqual(value, key, "Missing catalog translation: \(key)") }
            }

            for state in TaskAlertsScreenshotState.allCases {
                let fixture = TaskAlertsScreenshotFixture(language: language)
                await fixture.prepare(state)
                assertState(state, fixture: fixture)
                do {
                    try await capture(state, language: language, strings: strings, fixture: fixture, scene: scene)
                } catch {
                    // A suspended DELETE must not outlive the test, even if hosting/capture fails.
                    await fixture.transport.releaseRetirement()
                    await fixture.controller.settle()
                    throw error
                }
                await fixture.transport.releaseRetirement()
                await fixture.controller.settle()
                if state == .unknownLoading {
                    XCTAssertEqual(fixture.controller.status, .off, "OFF requires the authenticated DELETE acknowledgement")
                    XCTAssertEqual(fixture.controller.record?.intent, false)
                }
                XCTAssertEqual(fixture.system.authorizationRequests, 0, "Fixtures must never request iOS permission")
            }
        }
    }

    func testScopeFailureDarkAndAccessibilityLargeScreenshotsInEnglishAndSimplifiedChinese() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let variations: [(name: String, appearance: ColorScheme, size: DynamicTypeSize)] = [
            ("dark-default", .dark, .large),
            ("light-accessibility-large", .light, .accessibility2),
            ("dark-accessibility-large", .dark, .accessibility2)
        ]
        for language in ["en", "zh-Hans"] {
            let strings = try localizedBundle(language: language)
            for variation in variations {
                let fixture = TaskAlertsScreenshotFixture(language: language)
                await fixture.prepare(.scopeFailed)
                try await capture(.scopeFailed, language: language, strings: strings, fixture: fixture, scene: scene,
                                  appearance: variation.appearance, textSize: variation.size,
                                  captureScrolledFooter: variation.size.isAccessibilitySize, nameSuffix: variation.name)
                await fixture.controller.settle()
                XCTAssertEqual(fixture.system.authorizationRequests, 0)
            }
        }
    }

    private func localizedBundle(language: String) throws -> Bundle {
        let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"),
                                "The app test host must contain the compiled \(language) Localizable catalog")
        return try XCTUnwrap(Bundle(path: path))
    }

    func assertState(_ state: TaskAlertsScreenshotState, fixture: TaskAlertsScreenshotFixture) {
        let controller = fixture.controller
        XCTAssertEqual(controller.status, state.status, state.caption)
        XCTAssertEqual(controller.intent, state.expectsOn, state.caption)
        XCTAssertEqual(controller.busy, state == .unknownLoading)
        XCTAssertEqual(controller.canToggle, state != .unknownLoading)
        XCTAssertEqual(controller.canPresent, state == .quiet)
        XCTAssertEqual(controller.hasFailure, [.registrationFailed, .scopeFailed, .disableFailed].contains(state))
        switch state {
        case .off:
            XCTAssertEqual(controller.record, TaskNotificationRecord(intent: false))
            XCTAssertEqual(fixture.preferences.records.count, 1)
            XCTAssertEqual(fixture.system.tokenRequests, 0)
        case .registrationFailed, .denied:
            XCTAssertEqual(controller.record?.intent, true)
            XCTAssertNil(controller.record?.registrationID)
        case .quiet:
            XCTAssertTrue(controller.permission.quiet)
            XCTAssertEqual(controller.record?.workspaceID, fixture.originalWorkspace.id)
            XCTAssertNotNil(controller.record?.registrationID)
        case .scopeFailed:
            XCTAssertEqual(controller.workspace?.id, fixture.otherWorkspace.id)
            XCTAssertEqual(controller.record?.workspaceID, fixture.originalWorkspace.id,
                           "A failed replacement must retain the acknowledged old registration")
            XCTAssertNotNil(controller.record?.registrationID)
        case .disableFailed:
            XCTAssertEqual(controller.record?.intent, true, "Failed DELETE must preserve confirmed ON")
            XCTAssertEqual(controller.record?.retirementRequested, true)
            XCTAssertNotNil(controller.record?.registrationID)
        case .unknownLoading:
            XCTAssertNil(controller.record, "Unknown consent is not confirmed OFF")
            XCTAssertTrue(fixture.preferences.records.isEmpty, "Do not persist OFF before DELETE acknowledgement")
            XCTAssertEqual(fixture.system.tokenRequests, 0)
        }
    }
}
#endif
