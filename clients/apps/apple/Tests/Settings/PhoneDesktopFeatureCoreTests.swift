import Foundation
import XCTest
import CommaCore
@testable import Comma

/// Production Swift models -> Hermes client core -> native credential gate and URL loading -> in-process API.
/// Business actions use model methods. No UI drives them and no real network is used.
@MainActor final class PhoneDesktopFeatureCoreTests: XCTestCase {
    private var runtime: CoreRuntime?
    private var directory: URL?

    override func tearDown() async throws {
        await runtime?.core.closed()
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func start(_ server: FakeServer) async throws -> CommaStore {
        server.on("GET", "/v1/comma/auth/session", json: ["expires_at": 4_102_444_800, "session_id": "feature-session",
            "user": ["id": "feature-user", "email": "features@example.com", "status": "active"]])
        let workspace: [String: Any] = ["id": "w1", "group_id": "g1", "name": "Feature tests", "status": "ready"]
        server.on("POST", "/v1/comma/me/bootstrap", json: ["status": "ready", "workspace": workspace])
        server.on("GET", "/v1/comma/workspaces", json: ["data": [workspace]])
        server.on("POST", "/v1/comma/groups/g1/assistant-chat", json: ["id": "router-chat", "group_id": "g1", "title": "Comma", "status": "active", "kind": "user_chat"])
        server.on("GET", "/v1/comma/workspaces/w1/agent-models", json: PhoneFeatureFixtures.agents)
        let custody = try SessionCustody(record: MemoryRecord(), apiOrigin: server.origin)
        custody.adoptEarlier(StoredBearer(token: "feature-bearer", audience: server.origin, sessionId: "feature-session",
                                          userId: "feature-user", email: "features@example.com", expiresAtEpochSeconds: 4_102_444_800))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        self.directory = directory
        let downloads = directory.appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let runtime = try CoreRuntime.make(custody: custody, dataDirectory: directory.appendingPathComponent("core"),
                                           downloadRoot: downloads, configuration: server.configuration)
        self.runtime = runtime
        let store = CommaStore(configuration: AppConfiguration(baseURL: URL(string: server.origin)!, credentialService: "PhoneDesktopFeatureCoreTests"),
                               runtime: runtime, workspacePreferences: UserDefaults(suiteName: UUID().uuidString)!)
        await store.start()
        try await ready { store.workspace?.id == "w1" }
        return store
    }

    func testPluginInstallationRunsThroughTheCoreAndUsesNativeCredentialCustody() async throws {
        let server = FakeServer()
        server.on("GET", "/v1/comma/workspaces/w1/plugins", json: ["data": [PhoneFeatureFixtures.plugin(installed: false)]])
        server.on("POST", "/v1/comma/workspaces/w1/plugins/github/install", json: ["plugin": PhoneFeatureFixtures.plugin(), "authorization": NSNull()])
        let store = try await start(server)
        let model = PhonePluginsModel(store: store, workspace: try XCTUnwrap(store.workspace))
        let follow = Task { await model.follow() }; defer { follow.cancel() }
        try await ready { model.loaded }
        let plugin = try XCTUnwrap(model.plugins.first)
        XCTAssertFalse(plugin.installed)
        _ = await model.install(plugin)
        XCTAssertNil(model.scope.error)
        try await ready { model.plugins.first?.installed == true }
        let request = try XCTUnwrap(server.requests("POST", "/v1/comma/workspaces/w1/plugins/github/install").first)
        XCTAssertEqual(request.authorization, "Bearer feature-bearer")
        XCTAssertEqual(request.body["contract"] as? String, "unified_v1")
    }

    func testRouterSettingsRemainUsableWhenTheModelCatalogAndProfilesAreUnavailable() async throws {
        let server = FakeServer()
        server.on("GET", "/v1/comma/model-catalog", status: 503, json: ["error": "unavailable"])
        server.on("GET", "/v1/comma/workspaces/w1/subscription-accounts", status: 503, json: ["error": "unavailable"])
        server.on("PATCH", "/v1/comma/workspaces/w1/agents/router-agent", json: [:])
        let store = try await start(server)
        let model = PhoneRouterSettingsModel(store: store, workspace: try XCTUnwrap(store.workspace))
        let follow = Task { await model.follow() }; defer { follow.cancel() }
        try await ready { model.loaded }
        XCTAssertNil(model.scope.error)
        let saved = await model.scope.perform("models.renameAgent", ["name": "Companion"])
        XCTAssertNotNil(saved)
        try await ready { model.name == "Companion" }
        XCTAssertEqual(server.requests("PATCH", "/v1/comma/workspaces/w1/agents/router-agent").first?.body["name"] as? String, "Companion")
    }

    func testModelSelectionAndInstructionsUseTheSharedCoreContracts() async throws {
        let server = FakeServer()
        server.on("GET", "/v1/comma/model-catalog", json: PhoneFeatureFixtures.catalog)
        server.on("GET", "/v1/comma/workspaces/w1/subscription-accounts", json: ["accounts": [PhoneFeatureFixtures.profile], "next": ""])
        server.on("PUT", "/v1/comma/workspaces/w1/task-model") { request in (200, ["selection": request.body["selection"] ?? [:]]) }
        server.on("PUT", "/v1/comma/workspaces/w1/agents/router-agent/model", json: [:])
        server.on("GET", "/v1/comma/groups/g1/system-files/instructions", json: ["content": "Original", "hash": "version-one"])
        server.on("PUT", "/v1/comma/groups/g1/system-files/instructions") { request in
            (200, ["content": request.body["content"] as? String ?? "", "hash": "version-two"])
        }
        let store = try await start(server)
        let workspace = try XCTUnwrap(store.workspace)
        let models = PhoneModelsModel(store: store, workspace: workspace)
        let follow = Task { await models.follow() }; defer { follow.cancel() }
        try await ready { models.loaded }
        XCTAssertNil(models.scope.error)
        var selection = models.routerSelection
        selection.profile = "profile-1"; selection.effort = "medium"
        let taskSaved = await models.saveSelection(selection, task: true)
        let routerSaved = await models.saveSelection(selection, task: false)
        XCTAssertTrue(taskSaved); XCTAssertTrue(routerSaved)
        let body = try XCTUnwrap(server.requests("PUT", "/v1/comma/workspaces/w1/task-model").first?.body["selection"] as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "gpt-5.5")
        XCTAssertEqual(body["allow_paid"] as? Bool, false)
        XCTAssertEqual(body["profile_id"] as? String, "profile-1")
        let router = PhoneRouterSettingsModel(store: store, workspace: workspace)
        await router.loadInstructions()
        let saved = await router.saveInstructions("Prefer concrete examples.")
        XCTAssertTrue(saved)
        let instructions = try XCTUnwrap(server.requests("PUT", "/v1/comma/groups/g1/system-files/instructions").first)
        XCTAssertEqual(instructions.authorization, "Bearer feature-bearer")
        XCTAssertEqual(instructions.body["expected_hash"] as? String, "version-one")
    }

    func testTaskFileListingAndDownloadUseTheCanonicalAttachmentThroughTheCore() async throws {
        let server = FakeServer()
        server.on("GET", "/v1/comma/groups/g1/task-files", json: ["data": [PhoneFeatureFixtures.file()], "next_cursor": NSNull()])
        let bytes = Data("%PDF-1.4\nfixture attachment\n%%EOF".utf8)
        server.on("GET", "/v1/comma/groups/g1/conversations/task-1/messages/files-message/attachments/0", json: bytes)
        server.on("GET", "/v1/comma/groups/g1/conversations/task-1", json: ["id": "task-1", "group_id": "g1", "title": "Prepare the launch", "status": "active", "kind": "agent_task"])
        server.on("GET", "/v1/comma/groups/g1/conversations/task-1/messages", json: ["data": []])
        let attachmentPath = "/v1/comma/groups/g1/conversations/task-1/messages/files-message/attachments/0/workspace-file"
        server.on("POST", attachmentPath, json: ["path": "/imports/launch-brief.pdf", "name": "Launch brief.pdf", "size": bytes.count])
        let store = try await start(server)
        let pane = ConversationPane(kind: .task("task-1"), workspace: try XCTUnwrap(store.workspace), conversationID: "task-1", store: store)
        let model = PhoneTaskFilesModel(store: store, pane: pane)
        await model.load()
        XCTAssertNil(model.scope.error)
        let file = try XCTUnwrap(model.files.first)
        let prepared = await model.prepare(file)
        let url = try XCTUnwrap(prepared)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        let request = try XCTUnwrap(server.requests("GET", "/v1/comma/groups/g1/conversations/task-1/messages/files-message/attachments/0").first)
        XCTAssertEqual(request.authorization, "Bearer feature-bearer")
        pane.open()
        defer { pane.close() }
        try await ready { pane.state.loaded }
        pane.draftText = "Keep my draft"
        let attached = await model.attach(file)
        XCTAssertTrue(attached)
        try await ready { pane.state.attachments.first?.status == .uploaded }
        XCTAssertEqual(pane.draftText, "Keep my draft")
        XCTAssertEqual(pane.state.attachments.first?.path, "/imports/launch-brief.pdf")
        XCTAssertEqual(server.requests("POST", attachmentPath).count, 1)
        XCTAssertTrue(server.requests("POST", "/v1/comma/groups/g1/conversations/task-1/messages").isEmpty,
                      "Add to context must stage a file without sending the member's draft")
    }

    func testRoutinesSettingsAndProactiveChangesReachTheirExistingOwnersThroughTheCore() async throws {
        let server = FakeServer()
        server.on("GET", "/v1/comma/workspaces/w1/recommendations", json: PhoneRoutineUsageFixtures.envelope)
        server.on("PATCH", "/v1/comma/workspaces/w1/recommendations/settings") { request in
            var envelope = PhoneRoutineUsageFixtures.envelope
            var settings = envelope["settings"] as! [String: Any]
            if let enabled = request.body["autoEnableNewSources"] { settings["autoEnableNewSources"] = enabled }
            envelope["settings"] = settings
            return (200, envelope)
        }
        server.on("GET", "/v1/comma/groups/g1/proactive", json: ["enabled": true])
        server.on("PUT", "/v1/comma/groups/g1/proactive") { request in (200, ["enabled": request.body["enabled"] ?? true]) }
        let store = try await start(server)
        let model = PhoneRoutinesSettingsModel(store: store, workspace: try XCTUnwrap(store.workspace))
        let sources = Task { await model.follow() }; let proactive = Task { await model.followProactive() }
        defer { sources.cancel(); proactive.cancel() }
        try await ready { model.loaded && model.proactive.object?.string("kind") == "ready" }
        XCTAssertEqual(model.sources.count, 3)
        await model.save(["autoEnableNewSources": false])
        try await ready { !model.autoEnable }
        let patch = try XCTUnwrap(server.requests("PATCH", "/v1/comma/workspaces/w1/recommendations/settings").first)
        XCTAssertEqual(patch.authorization, "Bearer feature-bearer")
        XCTAssertEqual(patch.body.count, 1)
        await model.setProactive(false)
        try await ready { model.proactive.object?.bool("enabled") == false }
        XCTAssertEqual(server.requests("PUT", "/v1/comma/groups/g1/proactive").first?.body["enabled"] as? Bool, false)
    }

    func testUsageUsesTheCoreCycleCalculationAndOnlyRefreshesTheOpenWorkspace() async throws {
        let server = FakeServer()
        server.on("GET", "/v1/comma/billing/plans", json: ["data": [PhoneRoutineUsageFixtures.plan]])
        server.on("GET", "/v1/comma/workspaces/w1/billing/summary", json: PhoneRoutineUsageFixtures.summary)
        let store = try await start(server)
        let model = PhoneUsageModel(store: store, workspace: try XCTUnwrap(store.workspace))
        let follow = Task { await model.follow() }; defer { follow.cancel() }
        try await ready { model.status == "ready" }
        XCTAssertEqual(model.credits, 12_500_000)
        XCTAssertEqual(model.usage?.int("usedPercent"), 40)
        XCTAssertEqual(model.usage?.int("otherCredits"), 500_000)
        XCTAssertNotNil(model.resetsAt)
        await model.refresh()
        XCTAssertEqual(server.requests("GET", "/v1/comma/workspaces/w1/billing/summary").last?.authorization, "Bearer feature-bearer")
        XCTAssertTrue(server.requests("POST", "/v1/comma/workspaces/w1/billing/checkout").isEmpty)
    }

    func testSuggestedReplyKeepsTheNativeDraftAcrossTheCoreSend() async throws {
        let server = FakeServer()
        let path = "/v1/comma/groups/g1/conversations/task-1"
        server.on("GET", path, json: ["id": "task-1", "group_id": "g1", "title": "Release", "status": "active", "kind": "agent_task",
            "messages": [["message_id": "answer-1", "seq": 1, "kind": "message", "actor_type": "agent", "content": [["type": "text", "text": "Ready for the next step."]]]]])
        server.on("GET", path + "/messages", json: ["data": [["message_id": "answer-1", "conversation_id": "task-1", "group_id": "g1",
            "seq": 1, "kind": "message", "actor_type": "agent", "content": [["type": "text", "text": "Ready for the next step."]]]]])
        server.on("POST", path + "/suggestions", json: ["data": PhoneRoutineUsageFixtures.suggestions])
        server.on("POST", path + "/messages/file-message/attachments/0/workspace-file", json: ["path": "/imports/notes.txt", "name": "notes.txt", "size": 10])
        server.on("POST", path + "/messages", json: ["id": "task-1", "group_id": "g1", "title": "Release", "status": "active", "kind": "agent_task"])
        let store = try await start(server)
        let pane = ConversationPane(kind: .task("task-1"), workspace: try XCTUnwrap(store.workspace), conversationID: "task-1", store: store)
        pane.open(); defer { pane.close() }
        pane.setSuggestionsVisible(true)
        try await ready { !pane.suggestions.isEmpty }
        _ = try await pane.call("attachConversationFiles", ["files": [["conversationId": "task-1", "messageId": "file-message", "index": 0, "name": "notes.txt", "size": 10]]])
        try await ready { pane.state.attachments.first?.status == .uploaded }
        pane.draftText = "Do not send this draft"
        let suggestion = try XCTUnwrap(pane.suggestions.first)
        let attempt = try XCTUnwrap(pane.enqueueSuggestion(suggestion))
        await pane.deliver(attempt)
        try await ready { !server.requests("POST", path + "/messages").isEmpty }
        XCTAssertEqual(pane.draftText, "Do not send this draft")
        XCTAssertEqual(pane.state.attachments.first?.path, "/imports/notes.txt")
        XCTAssertNil(pane.error)
        let sent = try XCTUnwrap(server.requests("POST", path + "/messages").first)
        XCTAssertFalse(String(data: sent.raw, encoding: .utf8)!.contains("Do not send this draft"))
        XCTAssertEqual((sent.body["message"] as? [String: Any])?["text"] as? String, "整理下一步")
        XCTAssertEqual(sent.authorization, "Bearer feature-bearer")
    }


    func testCodeReviewMergeAndMemoryEditsReachTheirOwnersThroughHermes() async throws {
        let server = FakeServer()
        let base = "/v1/comma/workspaces/w1/coding/sessions/code-1"
        let head = String(repeating: "a", count: 40)
        let pr: [String: Any] = ["url": "https://github.com/fixture/ios/pull/42", "number": 42, "title": "Duo settings", "body": "Align headings", "head_sha": head, "state": "open", "mergeable": "mergeable"]
        server.on("GET", base, json: ["repo": ["owner": "fixture", "name": "ios", "base_ref": "main", "branch": "codex/duo"], "state": "ready"])
        server.on("GET", base + "/changes", json: ["source": "sandbox", "base": "main", "branch": "codex/duo", "files": [["path": "Settings.swift", "status": "modified", "additions": 1, "deletions": 1, "patch": "+ alignment: .leading"]], "pull_request": pr])
        server.on("POST", base + "/pull-request/merge", json: ["method": "squash", "pull_request": pr.merging(["state": "merged"], uniquingKeysWith: { _, next in next })])
        server.on("GET", "/v1/comma/groups/g1/system-files/content", json: ["path": "/memory/scoped/project.md", "content": "Original", "size": 8, "hash": "current-memory-version"])
        server.on("PUT", "/v1/comma/groups/g1/system-files/content", json: ["path": "/memory/scoped/project.md", "size": 7, "hash": "saved-memory-version"])
        let store = try await start(server), workspace = try XCTUnwrap(store.workspace)
        let review = PhoneCodingModel(store: store, workspace: workspace, task: "code-1")
        await review.load()
        XCTAssertEqual(review.session.object?.object("repo")?.string("baseRef"), "main")
        XCTAssertEqual(review.files.first?.string("patch"), "+ alignment: .leading")
        await review.merge(number: 42, head: try XCTUnwrap(review.pr?.string("headSha")))
        XCTAssertNil(review.scope.error)
        let merge = try XCTUnwrap(server.requests("POST", base + "/pull-request/merge").first)
        XCTAssertEqual(merge.body["head_sha"] as? String, head)
        XCTAssertEqual(merge.authorization, "Bearer feature-bearer")
        let document = PhoneDriveDocument(scope: WorkspaceSettingsScope(store: store, workspace: workspace), file: PhoneDriveFile(PhoneMigrationFixtures.driveFile as NSDictionary))
        await document.load(); document.text = "Changed"
        let saved = await document.save(); XCTAssertTrue(saved)
        let write = try XCTUnwrap(server.requests("PUT", "/v1/comma/groups/g1/system-files/content").first)
        XCTAssertEqual(write.body["expected_hash"] as? String, "current-memory-version")
        XCTAssertEqual(write.body["content"] as? String, "Changed")
        XCTAssertEqual(write.authorization, "Bearer feature-bearer")
    }

    func testRequestsAndVoicePreferenceActionsUseSharedContractsAndNativeCustody() async throws {
        let server = FakeServer()
        let path = "/v1/comma/workspaces/w1/task-requests/request-1/accept"
        var accepted = PhoneMigrationFixtures.request
        accepted["status"] = "accepted"; accepted["decline_reason"] = NSNull(); accepted["task"] = ["group_id": "g1", "id": "accepted-task"]
        server.on("POST", path, json: accepted)
        let voicePath = "/v1/comma/workspaces/w1/integrations/voice"
        server.on("PUT", voicePath + "/preferences", json: PhoneMigrationFixtures.voice["integration"]!)
        let store = try await start(server), workspace = try XCTUnwrap(store.workspace)
        let requests = PhoneTaskRequestsModel(store: store, workspace: workspace)
        let result = await requests.scope.perform("taskRequests.accept", ["request": "request-1", "title": "Edited title", "content": "Edited brief", "to": "task"])
        XCTAssertEqual(result?.object?.object("task")?.string("id"), "accepted-task")
        let accept = try XCTUnwrap(server.requests("POST", path).first)
        XCTAssertEqual(accept.body["content"] as? String, "Edited brief")
        XCTAssertEqual(accept.authorization, "Bearer feature-bearer")
        let voice = PhoneVoiceModel(store: store, workspace: workspace)
        _ = await voice.scope.perform("voice.setPreferences", ["voice": voice.choice("sage"), "routerCalls": false])
        XCTAssertNil(voice.scope.error)
        let changed = try XCTUnwrap(server.requests("PUT", voicePath + "/preferences").first)
        XCTAssertEqual((changed.body["voice"] as? [String: Any])?["name"] as? String, "sage")
        XCTAssertEqual(changed.body["router_calls"] as? Bool, false)
    }

    func testAnInvitationIsAcceptedOnlyAfterItsPreviewInThisWorkspace() async throws {
        let server = FakeServer()
        let token = String(repeating: "a", count: 43)
        let path = "/v1/comma/task-request-invites/\(token)"
        server.on("GET", path, json: ["workspace": ["id": "w2", "name": "Sam's", "owner": NSNull()], "own": false, "back": ["workspace": ["id": "w1", "name": "Mine"], "mode": "review"], "expires_at": 1_790_800_000])
        server.on("POST", path + "/accept", json: ["grant_id": "g1", "workspace": ["id": "w2", "name": "Sam's", "owner": NSNull()], "mode": "review", "daily_limit": 20, "pending_limit": 10, "sent_today": 0, "pending": 0, "reciprocal": true])
        let store = try await start(server), workspace = try XCTUnwrap(store.workspace)
        let requests = PhoneTaskRequestsModel(store: store, workspace: workspace)
        let accepted = await requests.acceptInvitation(token)
        XCTAssertFalse(accepted)
        XCTAssertTrue(server.requests("POST", path + "/accept").isEmpty)
        await requests.previewInvitation(token)
        XCTAssertEqual(requests.invitePreview.object?.object("back")?.string("mode"), "review")
        let previewed = await requests.acceptInvitation(token)
        XCTAssertTrue(previewed, requests.scope.error ?? "")
        XCTAssertEqual(server.requests("POST", path + "/accept").first?.body["workspace_id"] as? String, workspace.id)
    }

    private func ready(_ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "The production core did not publish the expected state")
    }
}
