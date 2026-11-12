import Foundation
import XCTest
import CommaCore
@testable import Comma

@MainActor final class PhoneDesktopFeatureTests: XCTestCase {
    func testAnotherWorkspacesNoticeCannotContinueTheSamePluginsAuthorization() async throws {
        let harness = try StoreHarness(); await harness.start()
        let model = PhonePluginsModel(store: harness.store, workspace: try XCTUnwrap(harness.store.workspace))
        harness.core.on("plugin.notice.claim") { _ in true }
        await model.receiveNotice(CoreJSON(value: ["id": 1, "kind": "authorize", "workspace": "other", "plugin": "github", "url": "https://other.test/authorize"]))
        XCTAssertNil(model.authorizationURL)
        XCTAssertTrue(harness.core.calls("plugin.notice.claim").isEmpty)
        await model.receiveNotice(CoreJSON(value: ["id": 2, "kind": "authorize", "workspace": "w1", "plugin": "github", "url": "https://current.test/authorize"]))
        XCTAssertEqual(model.authorizationURL?.host, "current.test")
        XCTAssertEqual(harness.core.calls("plugin.notice.claim").first?["id"] as? Int, 2)
    }

    func testAnUnavailableWorkspaceShowsAFailureInsteadOfAnotherWorkspacesSettings() async throws {
        let harness = try StoreHarness(); await harness.start()
        harness.core.serve("plugins") { _ in ["status": "ready", "workspace": "other", "plugins": [PhoneFeatureFixtures.plugin()]] }
        let plugins = PhonePluginsModel(store: harness.store, workspace: try XCTUnwrap(harness.store.workspace))
        let catalog = Task { await plugins.follow() }; defer { catalog.cancel() }
        await until { plugins.loaded }
        XCTAssertTrue(plugins.plugins.isEmpty); XCTAssertNotNil(plugins.scope.error)
        harness.core.serve("models") { _ in ["workspace": "other", "error": true] }
        let models = PhoneModelsModel(store: harness.store, workspace: try XCTUnwrap(harness.store.workspace))
        let settings = Task { await models.follow() }; defer { settings.cancel() }
        await until { models.loaded }
        XCTAssertTrue(models.profiles.isEmpty); XCTAssertNotNil(models.scope.error)
        let router = PhoneRouterSettingsModel(store: harness.store, workspace: try XCTUnwrap(harness.store.workspace))
        let identity = Task { await router.follow() }; defer { identity.cancel() }
        await until { router.scope.error != nil }
        XCTAssertFalse(router.loaded)
    }

    func testPluginCatalogReadsDetailsOnlyForThePluginTheMemberOpens() async throws {
        let harness = try StoreHarness()
        PhoneFeatureFixtures.configure(harness.core)
        await harness.start()
        let model = PhonePluginsModel(store: harness.store, workspace: try XCTUnwrap(harness.store.workspace))
        let list = Task { await model.follow() }
        defer { list.cancel() }
        await until { model.loaded }
        XCTAssertEqual(model.plugins.map(\.id), ["github", "google-workspace"])
        XCTAssertTrue(harness.core.topics("pluginSources").isEmpty)
        XCTAssertTrue(harness.core.topics("pluginToolGroups").isEmpty)
        let sources = PhonePluginSourcesModel(scope: model.scope, plugin: "github")
        let detail = Task { await sources.followSources() }
        defer { detail.cancel() }
        await until { !sources.sources.isEmpty }
        XCTAssertEqual(harness.core.topics("pluginSources").count, 1)
        XCTAssertEqual(harness.core.topics("pluginSources").first?["plugin"] as? String, "github")
        await sources.run("plugin.sources.prepare", ["toolkit": "github", "account": "me@example.com"])
        XCTAssertEqual(harness.core.calls("plugin.sources.prepare").first?["account"] as? String, "me@example.com")
        XCTAssertTrue(harness.core.calls("plugin.sources.confirm").isEmpty, "Preparing must not confirm an account")
        await sources.run("plugin.sources.confirm")
        await sources.run("plugin.toolGroup.set", ["group": "repos", "enabled": false])
        XCTAssertEqual(harness.core.calls("plugin.toolGroup.set").first?["enabled"] as? Bool, false)
    }

    func testPluginAuthorizationAndCredentialFailureLeaveAVisibleRetry() async throws {
        let harness = try StoreHarness(); await harness.start()
        let model = PhonePluginsModel(store: harness.store, workspace: try XCTUnwrap(harness.store.workspace))
        var json = PhoneFeatureFixtures.plugin(installed: false)
        json["credentialSetup"] = ["key": "api_key", "label": "API key", "helpUrl": "https://provider.test/help"]
        let plugin = try XCTUnwrap(PhonePlugin(json as NSDictionary))
        harness.core.on("plugin.install") { _ in ["failure": "credential_rejected"] }
        let failed = await model.install(plugin, credential: "test-key")
        XCTAssertNil(failed); XCTAssertNotNil(model.scope.error)
        XCTAssertEqual((harness.core.calls("plugin.install").first?["configValues"] as? [String: String])?["api_key"], "test-key")
        harness.core.on("plugin.install") { _ in ["authorizationUrl": "https://provider.test/authorize"] }
        let url = await model.install(plugin, credential: "replacement")
        XCTAssertEqual(url?.host, "provider.test"); XCTAssertNil(model.scope.error)
        XCTAssertEqual(model.authorizationPlugin, "github")
    }

    func testDefaultTaskAndRouterChoicesAreIndependentAndPreserveThePaidAccountChoice() async throws {
        let harness = try StoreHarness(); PhoneFeatureFixtures.configure(harness.core); await harness.start()
        let model = PhoneModelsModel(store: harness.store, workspace: try XCTUnwrap(harness.store.workspace))
        let following = Task { await model.follow() }; defer { following.cancel() }
        await until { model.loaded }
        var selection = model.routerSelection
        selection.effort = "medium"; selection.profile = "profile-1"
        let saved = await model.saveSelection(selection, task: false)
        XCTAssertTrue(saved)
        let router = try XCTUnwrap(harness.core.calls("models.setAgentModel").first)
        XCTAssertEqual(router["agent"] as? String, "router-agent")
        let choice = try XCTUnwrap(router["selection"] as? [String: Any])
        XCTAssertEqual(choice["allow_paid"] as? Bool, false)
        XCTAssertEqual(choice["profile_id"] as? String, "profile-1")
        XCTAssertEqual(choice["reasoning_effort"] as? String, "medium")
        XCTAssertTrue(harness.core.calls("models.setTaskModel").isEmpty)
        _ = await model.saveSelection(PhoneModelSelection(), task: true)
        XCTAssertEqual((harness.core.calls("models.setTaskModel").first?["selection"] as? [String: String])?["kind"], "builtin")
    }

    func testRetiredWorkspaceSettingsCannotMutateTheNewWorkspace() async throws {
        let harness = try StoreHarness(); await harness.start()
        let scope = WorkspaceSettingsScope(store: harness.store, workspace: try XCTUnwrap(harness.store.workspace))
        harness.core.on("chat.resolveWorkspaceChat") { _ in ["status": "ready", "workspaceId": "w2", "groupId": "g2", "conversationId": "other-router"] }
        await harness.store.chooseWorkspace(Workspace(id: "w2", groupID: "g2", name: "Other"))
        XCTAssertFalse(scope.current)
        let result = await scope.perform("plugin.uninstall", ["plugin": "github"])
        XCTAssertNil(result)
        XCTAssertTrue(harness.core.calls("plugin.uninstall").isEmpty)
    }

    func testInstructionsConflictKeepsTheMembersDraftAndRequiresAnotherExplicitSave() async throws {
        let harness = try StoreHarness(); PhoneFeatureFixtures.configure(harness.core); await harness.start()
        let model = PhoneRouterSettingsModel(store: harness.store, workspace: try XCTUnwrap(harness.store.workspace))
        await model.loadInstructions()
        model.instructions = "My unsaved edit"
        harness.core.on("systemFiles.instructions") { _ in ["content": "New text from desktop", "hash": "instructions-v2"] }
        harness.core.on("systemFiles.writeInstructions") { _ in throw CoreError(code: "changed", message: "Changed", status: 409) }
        let saved = await model.saveInstructions(model.instructions)
        XCTAssertFalse(saved)
        XCTAssertEqual(model.instructions, "My unsaved edit")
        XCTAssertEqual(model.savedInstructions, "New text from desktop")
        XCTAssertTrue(model.instructionsChanged)
        XCTAssertEqual(harness.core.calls("systemFiles.writeInstructions").count, 1, "A conflict cannot retry a write automatically")
        XCTAssertEqual(harness.core.calls("systemFiles.writeInstructions").first?["expectedHash"] as? String, "instructions-v1")
        harness.core.on("systemFiles.writeInstructions") { params in ["content": params["content"] as? String ?? "", "hash": "instructions-v3"] }
        let retried = await model.saveInstructions(model.instructions)
        XCTAssertTrue(retried)
        XCTAssertEqual(harness.core.calls("systemFiles.writeInstructions").last?["expectedHash"] as? String, "instructions-v2")
    }

    func testTaskFilesPageDeduplicatesAndKeepsPreviouslyReadFilesAfterAFailure() async throws {
        let harness = try StoreHarness(); await harness.start()
        let pane = ConversationPane(kind: .task("task-1"), workspace: try XCTUnwrap(harness.store.workspace), conversationID: "task-1", store: harness.store)
        let model = PhoneTaskFilesModel(store: harness.store, pane: pane)
        harness.core.on("taskFiles.list") { params in
            if params["cursor"] as? String == "next" {
                return ["status": "ready", "files": [PhoneFeatureFixtures.file(), PhoneFeatureFixtures.file("Chart.png", index: 1)], "nextCursor": NSNull()]
            }
            return ["status": "ready", "files": [PhoneFeatureFixtures.file()], "nextCursor": "next"]
        }
        await model.load()
        XCTAssertEqual(model.files.count, 1)
        await model.load(more: true)
        XCTAssertEqual(model.files.count, 2)
        XCTAssertEqual(harness.core.calls("taskFiles.list").last?["conversation"] as? String, "task-1")
        harness.core.on("taskFiles.list") { _ in ["status": "error", "files": [], "nextCursor": NSNull()] }
        await model.load()
        XCTAssertEqual(model.files.count, 2)
        XCTAssertNotNil(model.scope.error)
        pane.draftText = "Keep this draft"
        let attached = await model.attach(try XCTUnwrap(model.files.first))
        XCTAssertTrue(attached)
        XCTAssertEqual(pane.draftText, "Keep this draft")
        let attachment = try XCTUnwrap((harness.core.calls("chatView.attachConversationFiles").first?["files"] as? [[String: Any]])?.first)
        XCTAssertEqual(attachment["messageId"] as? String, "files-message")
        XCTAssertEqual(attachment["index"] as? Int, 0)
        XCTAssertNil(attachment["bytes"], "Add to context must use the server reference")
        pane.close()
        let afterClose = await model.attach(model.files[0])
        XCTAssertFalse(afterClose)
        XCTAssertEqual(harness.core.calls("chatView.attachConversationFiles").count, 1)
    }
}
