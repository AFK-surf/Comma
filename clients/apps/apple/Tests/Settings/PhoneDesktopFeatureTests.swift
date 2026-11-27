import Foundation
import SwiftUI
import UIKit
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

    private func colabNotice(_ id: Int, attempt: String, operation: String = "install", error: String? = nil) -> CoreJSON {
        var setup: [String: Any] = ["key": "GOOGLE_COLAB_AUTH_CODE", "label": "Authorization code",
                                    "helpUrl": "https://accounts.google.com/o/oauth2/v2/auth?state=\(attempt)",
                                    "format": "oauth_code", "attemptId": attempt]
        if let error { setup["error"] = error }
        var configuration: [String: Any] = ["workspace": "w1", "plugin": ["id": "google-colab", "name": "Google Colab"],
                                            "operation": operation, "setup": setup]
        if operation == "reauthorize" {
            configuration["connectionId"] = "google-colab-oauth"; configuration["bindingId"] = "colab_acc_1"
        }
        return CoreJSON(value: ["id": id, "kind": "configure", "workspace": "w1", "plugin": "google-colab",
                                "origin": "plugins", "configuration": configuration])
    }

    private func colab(installed: Bool) throws -> PhonePlugin {
        var json = PhoneFeatureFixtures.plugin("google-colab", installed: installed)
        json["name"] = "Google Colab"; json["brand"] = "google-colab"
        return try XCTUnwrap(PhonePlugin(json as NSDictionary))
    }

    func testAGoogleSignInFormComesFromTheConfigureNoticeAndARejectedCodeKeepsItsAttempt() async throws {
        let harness = try StoreHarness(); await harness.start()
        let model = PhonePluginsModel(store: harness.store, workspace: try XCTUnwrap(harness.store.workspace))
        harness.core.on("plugin.notice.claim") { _ in true }
        let plugin = try colab(installed: false)
        // The catalog lists no credential form for it: the sign-in link and attempt come only with the notice.
        XCTAssertNil(plugin.credentialKey)
        await model.receiveNotice(colabNotice(1, attempt: "colab_att_1"))
        let form = try XCTUnwrap(model.configuration(for: plugin))
        XCTAssertTrue(form.oauthCode)
        XCTAssertEqual(form.helpURL?.host, "accounts.google.com")
        XCTAssertEqual(form.attemptID, "colab_att_1")

        harness.core.on("plugin.install") { _ in ["failure": "credential_rejected"] }
        _ = await model.install(plugin, credential: "4/0Abc")
        let sent = try XCTUnwrap(harness.core.calls("plugin.install").last)
        XCTAssertEqual((sent["configValues"] as? [String: String])?["GOOGLE_COLAB_AUTH_CODE"], "4/0Abc")
        XCTAssertEqual(sent["attemptId"] as? String, "colab_att_1")
        XCTAssertTrue(harness.core.calls("plugin.reauthorize").isEmpty)
        XCTAssertNotNil(model.formError, "A rejected code is said in the form")
        XCTAssertNil(model.scope.error)
        XCTAssertEqual(model.configuration(for: plugin)?.attemptID, "colab_att_1", "A rejected code keeps the sign-in it belongs to")

        // The server's words for a code from another Google account reach the form as they are.
        let wrongAccount = "Sign in with alice@gmail.com, the account this workspace connected."
        harness.core.on("plugin.install") { _ in ["failure": "credential_rejected", "message": wrongAccount] }
        _ = await model.install(plugin, credential: "4/0Other")
        XCTAssertEqual(model.formError, wrongAccount)
        XCTAssertEqual(model.configuration(for: plugin)?.attemptID, "colab_att_1")

        // An expired sign-in comes back as a fresh link and attempt, which replaces the form in place.
        await model.receiveNotice(colabNotice(2, attempt: "colab_att_2", error: "The sign-in expired. Sign in again."))
        XCTAssertEqual(model.configuration(for: plugin)?.attemptID, "colab_att_2")
        XCTAssertEqual(model.configuration(for: plugin)?.error, "The sign-in expired. Sign in again.")
        XCTAssertNil(model.formError)

        harness.core.on("plugin.install") { _ in [String: Any]() }
        _ = await model.install(plugin, credential: "4/0Def")
        XCTAssertEqual(harness.core.calls("plugin.install").last?["attemptId"] as? String, "colab_att_2")
        XCTAssertNil(model.configuration, "A connected account puts the form away")
    }

    func testAColabReconnectNamesItsAccountAndSendsTheCodeToTheReconnect() async throws {
        let harness = try StoreHarness(); await harness.start()
        let model = PhonePluginsModel(store: harness.store, workspace: try XCTUnwrap(harness.store.workspace))
        harness.core.on("plugin.notice.claim") { _ in true }
        harness.core.on("plugin.reauthorize") { _ in [String: Any]() }
        let plugin = try colab(installed: true)
        _ = await model.install(plugin, connection: "google-colab-oauth", binding: "colab_acc_1")
        let started = try XCTUnwrap(harness.core.calls("plugin.reauthorize").last)
        XCTAssertEqual(started["connection"] as? String, "google-colab-oauth")
        XCTAssertEqual(started["bindingId"] as? String, "colab_acc_1")
        XCTAssertNil(started["configValues"])

        await model.receiveNotice(colabNotice(3, attempt: "colab_att_3", operation: "reauthorize"))
        XCTAssertEqual(model.configuration(for: plugin)?.operation, .reauthorize)
        _ = await model.install(plugin, credential: "4/0Ghi")
        let sent = try XCTUnwrap(harness.core.calls("plugin.reauthorize").last)
        XCTAssertEqual(sent["attemptId"] as? String, "colab_att_3")
        XCTAssertEqual(sent["bindingId"] as? String, "colab_acc_1")
        XCTAssertEqual(sent["connection"] as? String, "google-colab-oauth")
        XCTAssertEqual((sent["configValues"] as? [String: String])?["GOOGLE_COLAB_AUTH_CODE"], "4/0Ghi")
        XCTAssertTrue(harness.core.calls("plugin.install").isEmpty, "A reconnect's code never installs a second account")
    }

    func testMonoidShowConfigurationDoesNotRequireCredentialInputAndDisplaysConnectLine() async throws {
        let harness = try StoreHarness(); await harness.start()
        let model = PhonePluginsModel(store: harness.store, workspace: try XCTUnwrap(harness.store.workspace))
        harness.core.on("plugin.notice.claim") { _ in true }
        harness.core.on("plugin.install") { _ in [String: Any]() }

        var json = PhoneFeatureFixtures.plugin("stillfail", installed: false)
        json["name"] = "Monoid"; json["brand"] = "stillfail"; json["stations"] = true
        json["credentialSetup"] = [
            "key": "STILLFAIL_CONNECT_LINE", "label": "Connect line",
            "helpUrl": "https://still.fail/docs", "format": "show",
        ]
        let plugin = try XCTUnwrap(PhonePlugin(json as NSDictionary))
        XCTAssertTrue(plugin.stations)
        XCTAssertEqual(plugin.credentialFormat, "show")
        XCTAssertFalse(plugin.requiresCredentialInput, "A show credentialSetup must not be treated as a manual API key input")

        _ = await model.install(plugin)
        let installCall = try XCTUnwrap(harness.core.calls("plugin.install").last)
        XCTAssertEqual(installCall["plugin"] as? String, "stillfail")
        XCTAssertNil(installCall["configValues"])

        let notice = CoreJSON(value: [
            "id": 42, "kind": "configure", "workspace": "w1", "plugin": "stillfail", "origin": "plugins",
            "configuration": [
                "workspace": "w1", "plugin": ["id": "stillfail", "name": "Monoid"], "operation": "install",
                "setup": [
                    "key": "STILLFAIL_CONNECT_LINE", "label": "Connect line",
                    "helpUrl": "https://still.fail/docs", "format": "show",
                    "value": "comma https://salix.comma.surf tok_monoid_123",
                ],
            ],
        ])
        await model.receiveNotice(notice)
        let form = try XCTUnwrap(model.configuration(for: plugin))
        XCTAssertTrue(form.showsValue)
        XCTAssertEqual(form.value, "comma https://salix.comma.surf tok_monoid_123")
        model.dismissConfiguration()
        XCTAssertNil(model.configuration(for: plugin))
    }

    func testMonoidStationsModelSubscribesDisconnectsAndUpdatesNotificationLevel() async throws {
        let harness = try StoreHarness(); await harness.start()
        let scope = WorkspaceSettingsScope(store: harness.store, workspace: try XCTUnwrap(harness.store.workspace))
        harness.core.serve("pluginStations") { _ in
            [
                "stations": [
                    [
                        "id": "st-1", "name": "Core · studio-0", "workspace": "Core", "emoji": "🚀",
                        "station": "tokyo-mac-studio-0", "stationCount": 3, "connected": true,
                        "connectedAt": "2026-11-25T01:00:00Z",
                    ],
                    [
                        "id": "st-2", "name": "Lab · mini-1", "workspace": "Lab", "emoji": NSNull(),
                        "station": "office-mini-1", "stationCount": 1, "connected": false,
                        "connectedAt": "2026-11-24T22:00:00Z",
                    ],
                ],
                "notificationLevel": "issues",
                "notificationPending": false,
                "pending": NSNull(),
                "error": NSNull(),
            ]
        }
        harness.core.on("plugin.station.disconnect") { _ in NSNull() }
        harness.core.on("plugin.station.notificationLevel.set") { _ in NSNull() }

        let stations = PhonePluginStationsModel(scope: scope, plugin: "stillfail")
        let task = Task { await stations.follow() }
        defer { task.cancel() }
        await until { stations.stations != nil }

        XCTAssertEqual(harness.core.topics("pluginStations").first?["plugin"] as? String, "stillfail")
        XCTAssertEqual(stations.stations?.count, 2)
        XCTAssertEqual(stations.stations?.first?.workspace, "Core")
        XCTAssertEqual(stations.stations?.first?.emoji, "🚀")
        XCTAssertEqual(stations.stations?.first?.stationCount, 3)
        XCTAssertTrue(stations.hasOfflineConnectedStation)
        XCTAssertEqual(stations.notificationLevel, .issues)

        let disconnected = await stations.disconnect(try XCTUnwrap(stations.stations?.first))
        XCTAssertTrue(disconnected)
        let disconnectCall = try XCTUnwrap(harness.core.calls("plugin.station.disconnect").last)
        XCTAssertEqual(disconnectCall["plugin"] as? String, "stillfail")
        XCTAssertEqual(disconnectCall["station"] as? String, "st-1")

        // No-op when selecting the already-active notification level.
        let unchanged = await stations.setNotificationLevel(.issues)
        XCTAssertFalse(unchanged)
        XCTAssertTrue(harness.core.calls("plugin.station.notificationLevel.set").isEmpty)

        let updated = await stations.setNotificationLevel(.all)
        XCTAssertTrue(updated)
        let levelCall = try XCTUnwrap(harness.core.calls("plugin.station.notificationLevel.set").last)
        XCTAssertEqual(levelCall["plugin"] as? String, "stillfail")
        XCTAssertEqual(levelCall["level"] as? String, "all")

        // Failure surfaces feedback instead of failing silently.
        harness.core.on("plugin.station.notificationLevel.set") { _ in throw CoreError(code: "failed", message: "Server error", status: 500) }
        let failed = await stations.setNotificationLevel(.off)
        XCTAssertFalse(failed)
        XCTAssertNotNil(stations.notificationError)
        XCTAssertNil(stations.actionError, "A failed level save is shown with the levels, not under the workspaces")

        // While a save is already pending, further level changes are ignored.
        harness.core.serve("pluginStations") { _ in
            [
                "stations": [],
                "notificationLevel": "all",
                "notificationPending": true,
                "pending": NSNull(),
                "error": NSNull(),
            ]
        }
        let pendingStations = PhonePluginStationsModel(scope: scope, plugin: "stillfail")
        let pendingTask = Task { await pendingStations.follow() }
        defer { pendingTask.cancel() }
        await until { pendingStations.notificationPending }
        let callsBefore = harness.core.calls("plugin.station.notificationLevel.set").count
        let blocked = await pendingStations.setNotificationLevel(.off)
        XCTAssertFalse(blocked)
        XCTAssertEqual(harness.core.calls("plugin.station.notificationLevel.set").count, callsBefore)
    }

    func testARoutersPluginInstallRequestReadsAsAnAddCardAndItsEnding() throws {
        let pending = try XCTUnwrap(AgentRequest([
            "id": "cap-9", "type": "plugin_install", "status": "pending", "expiresAt": 2_000_000, "sourceMessageId": "m1",
            "plugin": ["id": "google-colab", "name": "Google Colab", "reason": "Rendering needs a GPU.",
                       "brand": "google-colab", "workspace": "w1"],
        ] as NSDictionary))
        XCTAssertEqual(pending.plugin, AgentRequest.Plugin(id: "google-colab", name: "Google Colab", brand: "google-colab", workspace: "w1"))
        XCTAssertEqual(pending.reason, "Rendering needs a GPU.")
        XCTAssertEqual(pending.markKey, "google-colab")
        XCTAssertNil(pending.authorizationURL)
        XCTAssertTrue(pending.isOpen(at: 1_000_000))

        let installed = try XCTUnwrap(AgentRequest([
            "id": "cap-9", "type": "plugin_install", "status": "completed", "outcome": "installed",
            "plugin": ["id": "google-colab", "name": "Google Colab", "reason": "", "brand": NSNull(), "workspace": "w1"],
        ] as NSDictionary))
        XCTAssertEqual(installed.outcome, .installed)
        XCTAssertEqual(installed.markKey, "google-colab", "With no brand the plugin's id picks the mark")
        XCTAssertNil(AgentRequest(["id": "cap-10", "type": "plugin_install", "status": "pending",
                                   "plugin": ["id": "google-colab", "name": "Google Colab", "reason": ""]] as NSDictionary),
                     "A request that names no Workspace has nowhere to install")
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

    func testPluginDetailKeepsFollowingCatalogAndNoticesAfterPushFromList() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let original = scene.windows.first(where: \.isKeyWindow)
        let harness = try StoreHarness()
        harness.core.serve("plugins") { _ in
            ["status": "ready", "workspace": "w1", "plugins": [PhoneFeatureFixtures.plugin("linear", installed: false)], "installed": [], "categories": []]
        }
        harness.core.serve("pluginSources") { _ in ["sources": []] }
        harness.core.serve("pluginToolGroups") { _ in ["groups": []] }
        harness.core.serve("pluginNotices") { _ in ["notices": []] }
        harness.core.on("plugin.install") { _ in ["authorizationUrl": "https://linear.app/oauth/authorize"] }
        harness.core.on("plugin.notice.claim") { _ in true }
        await harness.start()

        let model = PhonePluginsModel(store: harness.store, workspace: try XCTUnwrap(harness.store.workspace))
        final class NavState: ObservableObject { @Published var pushed = false }
        struct HostView: View {
            let model: PhonePluginsModel
            @ObservedObject var nav: NavState
            var body: some View {
                NavigationStack {
                    PhonePluginsView(model: model)
                        .navigationDestination(isPresented: $nav.pushed) {
                            PhonePluginDetailView(model: model, pluginID: "linear")
                        }
                }
            }
        }
        let nav = NavState()
        let host = UIHostingController(rootView: HostView(model: model, nav: nav))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            original?.makeKeyAndVisible()
        }

        await until { model.loaded }
        XCTAssertEqual(harness.core.topics("plugins").count, 1)
        XCTAssertEqual(harness.core.topics("pluginNotices").count, 1)

        // Push the plugin detail page over PhonePluginsView, just as tapping a plugin row does.
        nav.pushed = true
        try await Task.sleep(for: .milliseconds(700))

        XCTAssertEqual(harness.core.topics("plugins").count, 1, "Detail page must keep the plugins subscription alive without duplicating it")
        XCTAssertEqual(harness.core.topics("pluginNotices").count, 1, "Detail page must keep the notices subscription alive without duplicating it")

        let linear = try XCTUnwrap(model.plugins.first { $0.id == "linear" })
        let url = await model.install(linear)
        XCTAssertEqual(url?.host, "linear.app")
        XCTAssertEqual(model.authorizationPlugin, "linear")

        // The core finishes OAuth and publishes the installed plugin while the detail page is still open.
        harness.core.publish("plugins", [
            "status": "ready", "workspace": "w1",
            "plugins": [PhoneFeatureFixtures.plugin("linear", installed: true)],
            "installed": ["linear"], "categories": []
        ])
        await until { model.plugins.first(where: { $0.id == "linear" })?.installed == true }
        XCTAssertTrue(model.plugins.first(where: { $0.id == "linear" })?.installed == true)
        XCTAssertNil(model.authorizationURL)
        XCTAssertNil(model.authorizationPlugin)

        // Notices arriving while on the detail page are still claimed and surfaced.
        harness.core.publish("pluginNotices", [
            "notices": [["id": 9, "kind": "authorization_timed_out", "workspace": "w1", "plugin": "linear"]]
        ])
        await until { model.scope.error != nil }
        XCTAssertEqual(harness.core.calls("plugin.notice.claim").last?["id"] as? Int, 9)

        // Cancelling clears local authorization state even if no catalog update follows.
        let retryURL = await model.install(linear)
        XCTAssertNotNil(retryURL)
        await model.cancel(linear)
        XCTAssertNil(model.authorizationURL)
        XCTAssertNil(model.authorizationPlugin)
        XCTAssertEqual(harness.core.calls("plugin.cancel").last?["plugin"] as? String, "linear")

        // Popping back to the list keeps one shared subscription; closing the stack releases both.
        nav.pushed = false
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(harness.core.topics("plugins").count, 1)
        XCTAssertEqual(harness.core.topics("pluginNotices").count, 1)

        window.isHidden = true
        window.rootViewController = nil
        let deadline = ContinuousClock.now + .seconds(5)
        while (!harness.core.topics("plugins").isEmpty || !harness.core.topics("pluginNotices").isEmpty),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(harness.core.topics("plugins").isEmpty)
        XCTAssertTrue(harness.core.topics("pluginNotices").isEmpty)
    }
}
