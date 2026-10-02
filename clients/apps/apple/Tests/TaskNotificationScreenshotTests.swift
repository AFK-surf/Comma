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
            for key in ["Settings", "Task notifications", "Task updates", "Retry",
                        "Task notifications won’t show task titles or content."] {
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

    private func assertState(_ state: TaskAlertsScreenshotState, fixture: TaskAlertsScreenshotFixture) {
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

    private func capture(_ state: TaskAlertsScreenshotState, language: String, strings: Bundle,
                         fixture: TaskAlertsScreenshotFixture, scene: UIWindowScene,
                         appearance: ColorScheme = .light, textSize: DynamicTypeSize = .large,
                         captureScrolledFooter: Bool = false, nameSuffix: String? = nil) async throws {
        let originalWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.overrideUserInterfaceStyle = appearance == .dark ? .dark : .light
        let host = UIHostingController(rootView: TaskAlertsScreenshotForm(controller: fixture.controller)
            .environment(\.locale, Locale(identifier: language))
            .environment(\.colorScheme, appearance)
            .environment(\.dynamicTypeSize, textSize))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            originalWindow?.makeKeyAndVisible()
        }

        let expectedTitle = strings.localizedString(forKey: "Settings", value: nil, table: "Localizable")
        // Wait for the actual Form/navigation hierarchy, not a fabricated image or a shared preview.
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            window.layoutIfNeeded()
            host.view.layoutIfNeeded()
            if firstSubview(UINavigationBar.self, in: host.view)?.topItem?.title == expectedTitle,
               let form = firstSubview(UIScrollView.self, in: host.view), form.contentSize.height > 0 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        // The production section refreshes in .task. Settle that refresh before asserting/capturing,
        // except for the deliberately suspended unknown-consent DELETE.
        if state != .unknownLoading { await fixture.controller.settle() }
        try await Task.sleep(for: .milliseconds(100))
        window.layoutIfNeeded()
        host.view.layoutIfNeeded()
        assertState(state, fixture: fixture)
        XCTAssertEqual(firstSubview(UINavigationBar.self, in: host.view)?.topItem?.title, expectedTitle,
                       "Navigation title should honor the SwiftUI locale")
        let form = try XCTUnwrap(firstSubview(UIScrollView.self, in: host.view), "Production Form must be mounted")
        XCTAssertGreaterThan(form.bounds.width, 0)
        XCTAssertGreaterThan(form.bounds.height, 0)
        XCTAssertTrue(window.bounds.intersects(form.convert(form.bounds, to: window)))
        XCTAssertEqual(host.view.bounds.size, window.bounds.size)
        if let toggle = firstSubview(UISwitch.self, in: host.view) {
            XCTAssertNotEqual(state, .unknownLoading, "Unknown consent must not be shown as an OFF switch")
            XCTAssertEqual(toggle.isOn, state.expectsOn, "Rendered intent must match the controller")
        }
        if let collection = form as? UICollectionView {
            // Default-sized evidence includes the whole section. Accessibility-sized evidence
            // instead checks native content bounds and scrolls the real Form to its footer.
            let content = CGRect(origin: .zero, size: collection.contentSize)
            let visible = collection.bounds.inset(by: collection.adjustedContentInset)
            let attributes = collection.collectionViewLayout.layoutAttributesForElements(in: content) ?? []
            for item in attributes where item.representedElementCategory != .decorationView {
                if captureScrolledFooter {
                    XCTAssertGreaterThanOrEqual(item.frame.minY, -1)
                    XCTAssertLessThanOrEqual(item.frame.maxY, content.maxY + 1, "Native layout must contain the wrapped content")
                    XCTAssertGreaterThanOrEqual(item.frame.minX, visible.minX - 1)
                    XCTAssertLessThanOrEqual(item.frame.maxX, visible.maxX + 1, "Large text must wrap, not overflow horizontally")
                } else {
                    XCTAssertGreaterThanOrEqual(item.frame.minY, visible.minY - 1, "Form content starts outside the screenshot")
                    XCTAssertLessThanOrEqual(item.frame.maxY, visible.maxY + 1,
                                             "Full production warning/privacy footer must fit; use a taller test destination, not shorter copy")
                }
            }
            if captureScrolledFooter {
                let rows = attributes.filter { $0.representedElementCategory == .cell }.sorted { $0.frame.minY < $1.frame.minY }
                XCTAssertGreaterThanOrEqual(rows.count, 3, "Toggle, full warning and Retry must have native rows")
                if rows.count >= 3 {
                    XCTAssertGreaterThan(rows[1].frame.height, 44, "The full scope warning must wrap at accessibility-large")
                    XCTAssertGreaterThanOrEqual(rows[2].frame.height, 44, "Retry must retain its accessible touch target")
                    XCTAssertLessThanOrEqual(rows[1].frame.maxY, rows[2].frame.minY + 1, "Wrapped warning must not overlap Retry")
                    XCTAssertLessThanOrEqual(rows[2].frame.maxY, visible.maxY + 1,
                                             "The top native capture must include the full warning and Retry")
                }
            }
        }

        let name = "testProductionTaskAlertsSettingsScreenshots-\(language)-\(state.rawValue)-\(state.caption)"
            + (nameSuffix.map { "-" + $0 } ?? "")
        try attachWindow(window, name: name + (captureScrolledFooter ? "-top" : ""))
        if captureScrolledFooter {
            let topVisible = form.bounds.inset(by: form.adjustedContentInset)
            // Self-sizing supplementary footers can settle after scrolling; use bounded native
            // scroll/layout passes, never enlarge the window or modify the production content.
            for _ in 0..<3 {
                let bottom = max(-form.adjustedContentInset.top,
                                 form.contentSize.height - form.bounds.height + form.adjustedContentInset.bottom)
                form.setContentOffset(CGPoint(x: form.contentOffset.x, y: bottom), animated: false)
                try await Task.sleep(for: .milliseconds(100))
                window.layoutIfNeeded()
                host.view.layoutIfNeeded()
            }
            let bottomVisible = form.bounds.inset(by: form.adjustedContentInset)
            XCTAssertLessThanOrEqual(bottomVisible.minY, topVisible.maxY + 1,
                                     "Top and footer captures must cover the full section without a missing middle")
            if let collection = form as? UICollectionView {
                let content = CGRect(origin: .zero, size: collection.contentSize)
                let attributes = collection.collectionViewLayout.layoutAttributesForElements(in: content) ?? []
                let footer = try XCTUnwrap(attributes.filter { $0.representedElementCategory != .decorationView }
                    .max { $0.frame.maxY < $1.frame.maxY }, "Production footer must have native layout bounds")
                XCTAssertTrue(bottomVisible.intersects(footer.frame), "Footer must be reachable by native scrolling")
                XCTAssertLessThanOrEqual(footer.frame.maxY, bottomVisible.maxY + 1, "Privacy footer must reach the visible bottom")
            }
            XCTAssertEqual(window.frame.size, scene.coordinateSpace.bounds.size, "Never use a tall fake screenshot viewport")
            assertState(state, fixture: fixture)
            try attachWindow(window, name: name + "-bottom-native-scroll-footer")
        }

        let events = await fixture.transport.events
        XCTAssertEqual(events.first, "DELETE:fixture-session", "Every fixture starts with authenticated default retirement")
        if state == .off || state == .unknownLoading {
            XCTAssertFalse(events.contains { $0.hasPrefix("POST:") })
        }
        if state == .disableFailed { XCTAssertEqual(events.last, "DELETE:fixture-session") }
    }

    private func attachWindow(_ window: UIWindow, name: String) throws {
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        var drewHierarchy = false
        let image = renderer.image { _ in
            drewHierarchy = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        XCTAssertTrue(drewHierarchy, "The screenshot must capture the live UIKit/SwiftUI hierarchy")
        let png = try XCTUnwrap(image.pngData())
        XCTAssertGreaterThan(png.count, 0)
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func firstSubview<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for child in view.subviews {
            if let match = firstSubview(type, in: child) { return match }
        }
        return nil
    }
}

/// Only the container is test-owned; controls, status copy, actions and privacy footer are production.
private struct TaskAlertsScreenshotForm: View {
    let controller: TaskNotificationController
    var body: some View {
        NavigationStack {
            Form {
                TaskAlertsSettingsSection(notifications: controller, hasWorkspaces: true)
            }
            .tint(CommaTheme.brandSolid)
            .scrollContentBackground(.hidden)
            .background(CommaTheme.bgWindow)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private enum TaskAlertsScreenshotState: String, CaseIterable {
    case off, registrationFailed, denied, quiet, scopeFailed, disableFailed, unknownLoading
    var expectsOn: Bool { self != .off && self != .unknownLoading }
    var status: TaskNotificationController.Status {
        switch self {
        case .off: .off
        case .registrationFailed: .enableFailed
        case .denied: .denied
        case .quiet: .quiet
        case .scopeFailed: .scopeFailed
        case .disableFailed: .disableFailed
        case .unknownLoading: .loading
        }
    }
    var caption: String {
        switch self {
        case .off: "OFF-default-DELETE-acknowledged"
        case .registrationFailed: "ON-registration-failed"
        case .denied: "ON-iOS-permission-denied"
        case .quiet: "ON-deliver-quietly"
        case .scopeFailed: "ON-current-workspace-failed-old-registration-retained"
        case .disableFailed: "ON-disable-DELETE-failed"
        case .unknownLoading: "unknown-awaiting-DELETE-not-confirmed-OFF"
        }
    }
}

@MainActor private final class TaskAlertsScreenshotFixture {
    let preferences = TaskAlertsScreenshotPreferences()
    let system = TaskAlertsScreenshotSystem()
    let transport = TaskAlertsScreenshotTransport()
    let originalWorkspace = Workspace(id: "fixture-workspace", groupID: "fixture-default-group", name: "Fixture workspace")
    let otherWorkspace = Workspace(id: "fixture-other-workspace", groupID: "fixture-other-default-group", name: "Other fixture workspace")
    let controller: TaskNotificationController

    init(language: String) {
        controller = TaskNotificationController(origin: "https://notifications.example.invalid",
            bundleID: "surf.comma.ios.dev", environment: .sandbox, locale: language == "en" ? "en-US" : language,
            preferences: preferences, system: system)
    }

    func prepare(_ state: TaskAlertsScreenshotState) async {
        if state == .unknownLoading { await transport.pauseRetirement() }
        controller.setContext(sessionID: transport.sessionID, accountID: transport.accountID, workspace: originalWorkspace)
        controller.attach(transport)
        if state == .unknownLoading {
            await transport.waitForRetirement()
            return
        }
        await controller.settle()
        // No private-variable mutation or hard-coded preference key: use the acknowledged default
        // OFF record generated by the controller, including its account-scoped persistence key.
        guard state != .off else { return }
        switch state {
        case .registrationFailed: await transport.failRegistration()
        case .denied: system.permission = .init(authorization: .denied)
        case .quiet: system.permission = .init(authorization: .allowed, quiet: true)
        default: break
        }
        controller.intent = true
        await controller.settle()
        if state == .scopeFailed {
            await transport.failRegistration()
            controller.setContext(sessionID: transport.sessionID, accountID: transport.accountID, workspace: otherWorkspace)
            await controller.settle()
        } else if state == .disableFailed {
            await transport.failRetirement()
            controller.intent = false
            await controller.settle()
        }
    }
}

@MainActor private final class TaskAlertsScreenshotPreferences: TaskNotificationPreferences {
    private(set) var records: [String: TaskNotificationRecord] = [:]
    func load(key: String) throws -> TaskNotificationRecord? { records[key] }
    func save(_ record: TaskNotificationRecord, key: String) throws { records[key] = record }
    func remove(key: String) throws { records.removeValue(forKey: key) }
}

@MainActor private final class TaskAlertsScreenshotSystem: TaskNotificationSystem {
    var permission = TaskNotificationPermission(authorization: .allowed)
    private(set) var authorizationRequests = 0
    private(set) var tokenRequests = 0
    func settings() async -> TaskNotificationPermission { permission }
    func requestAuthorization() async throws -> TaskNotificationPermission {
        authorizationRequests += 1
        return permission
    }
    func deviceToken() async throws -> String {
        tokenRequests += 1
        return "test-only-not-an-apns-token"
    }
}

/// Actor isolation satisfies the transport's Sendable contract without main-actor conformance tricks.
private actor TaskAlertsScreenshotTransport: DeviceNotificationTransport {
    nonisolated let sessionID = "fixture-session"
    nonisolated let accountID = "fixture-account"
    private(set) var events: [String] = []
    private var registrationFails = false
    private var retirementFails = false
    private var retirementPaused = false
    private var retirementContinuation: CheckedContinuation<Void, Never>?
    private var retirementWaiter: CheckedContinuation<Void, Never>?

    func failRegistration() { registrationFails = true }
    func failRetirement() { retirementFails = true }
    func pauseRetirement() { retirementPaused = true }
    func waitForRetirement() async {
        if retirementContinuation != nil { return }
        await withCheckedContinuation { retirementWaiter = $0 }
    }
    func releaseRetirement() {
        retirementPaused = false
        retirementContinuation?.resume()
        retirementContinuation = nil
    }
    func retire() async throws {
        events.append("DELETE:" + sessionID)
        if retirementPaused {
            await withCheckedContinuation { continuation in
                retirementContinuation = continuation
                retirementWaiter?.resume()
                retirementWaiter = nil
            }
        }
        if retirementFails { throw CommaError.transport }
    }
    func register(token: String, environment: PushEnvironment, workspace: Workspace,
                  bundleID: String, locale: String) async throws -> NotificationRegistration {
        events.append("POST:" + workspace.id)
        if registrationFails { throw CommaError.transport }
        return try JSONDecoder().decode(NotificationRegistration.self,
            from: Data("{\"id\":\"fixture-registration\",\"status\":\"active\"}".utf8))
    }
}
#endif
