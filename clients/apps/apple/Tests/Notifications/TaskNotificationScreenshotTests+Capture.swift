#if os(iOS)
import XCTest
import SwiftUI
import UIKit
import CommaCore
@testable import Comma

// Hosts the production section in a real window, checks its native layout, and attaches PNG evidence.
extension TaskNotificationScreenshotTests {
    func capture(_ state: TaskAlertsScreenshotState, language: String, strings: Bundle,
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
        } else if captureScrolledFooter {
            // Settings draws its own groups on a scroll view. At accessibility sizes the wrapped warning and Retry
            // must still be reachable: the page scrolls rather than clipping them.
            let visible = form.bounds.inset(by: form.adjustedContentInset)
            XCTAssertGreaterThan(form.contentSize.height, visible.height, "Large text must make the section scroll, not clip")
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

/// Only the container is test-owned; the page, controls, status copy, actions and privacy footer are production.
private struct TaskAlertsScreenshotForm: View {
    let controller: TaskNotificationController
    var body: some View {
        NavigationStack {
            SettingsPage {
                TaskAlertsSettingsSection(notifications: controller, hasWorkspaces: true)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
#endif
