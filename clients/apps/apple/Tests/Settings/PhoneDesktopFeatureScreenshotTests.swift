import XCTest
import SwiftUI
import UIKit
import CommaCore
@testable import Comma

/// Native screenshots of the production pages with synthetic core values. No real accounts or services are used.
@MainActor final class PhoneDesktopFeatureScreenshotTests: XCTestCase {
    func testRouterSettingsScreenshot() async throws {
        let harness = try StoreHarness()
        PhoneFeatureFixtures.configure(harness.core)
        await harness.start()
        let router = PhoneRouterSettingsModel(store: harness.store, workspace: try XCTUnwrap(harness.store.workspace))
        try await capture("07-router-settings", view: PhoneRouterSettingsView(model: router)) { router.loaded }
    }

    func testAcceptanceScreenshots() async throws {
        let harness = try StoreHarness()
        PhoneFeatureFixtures.configure(harness.core)
        await harness.start()
        let workspace = try XCTUnwrap(harness.store.workspace)
        try await capture("00-settings-entry-points", view: SettingsView(store: harness.store)
            .environment(AppNavigation(tab: .settings))) { true }
        let plugins = PhonePluginsModel(store: harness.store, workspace: workspace)
        let catalog = Task { await plugins.follow() }
        await until { plugins.loaded }
        catalog.cancel()
        try await capture("01-plugins", view: PhonePluginsView(model: plugins)) { plugins.loaded }
        try await capture("02-plugin-accounts-and-tools", view: PhonePluginDetailView(model: plugins, pluginID: "github")) {
            !harness.core.topics("pluginSources").isEmpty && !harness.core.topics("pluginToolGroups").isEmpty
        }
        plugins.authorizationURL = URL(string: "https://provider.test/authorize")
        plugins.authorizationPlugin = "google-workspace"
        try await capture("03-plugin-authorization", view: PhonePluginDetailView(model: plugins, pluginID: "google-workspace")) { true }
        let models = PhoneModelsModel(store: harness.store, workspace: workspace)
        let modelUpdates = Task { await models.follow() }
        await until { models.loaded }
        modelUpdates.cancel()
        try await capture("04-models", view: PhoneModelsView(model: models)) { models.loaded }
        try await capture("05-router-model-choice", view: PhoneModelSelectionView(model: models, task: false)) { true }
        try await capture("06-model-account", view: PhoneModelAccountView(model: models, profileID: "profile-1")) { true }
        try await capture("12-api-account", view: PhoneModelAccountView(model: models, profileID: "profile-key")) { true }
        try await capture("13-add-model-account", view: PhoneAddModelAccountView(model: models)) { true }
        try await capture("14-reconnect-subscription", view: PhoneAddModelAccountView(model: models, renewing: CoreJSON(value: PhoneFeatureFixtures.profile))) { true }
        let router = PhoneRouterSettingsModel(store: harness.store, workspace: workspace)
        try await capture("07-router-settings", view: PhoneRouterSettingsView(model: router)) { router.loaded }
        await router.loadInstructions()
        try await capture("08-custom-instructions", view: PhoneRouterInstructionsView(model: router)) { router.savedInstructions != nil }
        let pane = ConversationPane(kind: .task("task-1"), workspace: workspace, conversationID: "task-1", store: harness.store)
        let files = PhoneTaskFilesModel(store: harness.store, pane: pane)
        try await capture("09-task-files", view: PhoneTaskFilesView(model: files)) { files.loaded }
        try await capture("10-models-dark", view: PhoneModelsView(model: models), dark: true) { models.loaded }
        try await capture("11-plugin-large-text", view: PhonePluginDetailView(model: plugins, pluginID: "github"), textSize: .accessibility2) { true }
        router.instructions = "Keep this edit while I review the other device’s changes."
        harness.core.on("systemFiles.instructions") { _ in ["content": "Use examples when explaining a decision.", "hash": "instructions-v2"] }
        harness.core.on("systemFiles.writeInstructions") { _ in throw CoreError(code: "changed", message: "Changed", status: 409) }
        let saved = await router.saveInstructions(router.instructions)
        XCTAssertFalse(saved)
        try await capture("15-instructions-conflict", view: PhoneRouterInstructionsView(model: router)) { router.instructionsChanged }
    }

    private func capture<V: View>(_ name: String, view: V, dark: Bool = false, textSize: DynamicTypeSize = .large,
                                  ready: @escaping @MainActor () -> Bool) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let original = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        let controller = UIHostingController(rootView: NavigationStack { view }.id(name)
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.dynamicTypeSize, textSize))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; original?.makeKeyAndVisible() }
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            window.layoutIfNeeded(); controller.view.layoutIfNeeded()
            if ready(), controller.view.bounds.height > 0 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(ready(), "The production page must finish loading before capture")
        try await Task.sleep(for: .milliseconds(250))
        window.layoutIfNeeded(); controller.view.layoutIfNeeded()
        XCTAssertEqual(window.bounds.size, controller.view.bounds.size)
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ios-feature-sync-evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent(name + ".png"))
    }
}
