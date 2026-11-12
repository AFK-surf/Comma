import XCTest
import AVFAudio
import CommaCore
@testable import Comma

@MainActor final class PhoneMigrationTests: XCTestCase {
    func testVoicePreviewUsesNativeMediaSessionAndPlaysWAVToCompletion() async throws {
        let h = try StoreHarness(); PhoneMigrationFixtures.configure(h.core); await h.start()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 12_000))
        buffer.frameLength = buffer.frameCapacity
        let samples = try XCTUnwrap(buffer.int16ChannelData)[0]
        for index in 0..<Int(buffer.frameLength) {
            samples[index] = Int16(sin(Double(index) * 2 * .pi * 440 / format.sampleRate) * 1000)
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
            try file.write(from: buffer)
        }
        let wav = try Data(contentsOf: url).base64EncodedString()
        h.core.on("voice.preview") { _ in ["audio": wav, "contentType": "audio/wav"] }
        let session = AVAudioSession.sharedInstance()
        let previous = (session.category, session.mode, session.categoryOptions)
        let model = PhoneVoiceModel(store: h.store, workspace: try XCTUnwrap(h.store.workspace))
        defer {
            model.stop()
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            try? session.setCategory(previous.0, mode: previous.1, options: previous.2)
        }
        try session.setActive(false)
        try session.setCategory(.soloAmbient, mode: .default)
        await model.preview("quartz")
        XCTAssertEqual(session.category, .playback, "Explicit preview must use media playback, which is audible with the Silent switch on")
        XCTAssertEqual(session.mode, .default)
        XCTAssertEqual(model.preview, .playing("quartz"))
        try await ready { model.preview == nil }
        XCTAssertNil(model.previewError, "The real AVAudioPlayer must decode and finish the local WAV")
        try session.setCategory(.playAndRecord, mode: .voiceChat)
        await model.preview("quartz")
        XCTAssertEqual(session.category, .playback, "A finished call's audio category must not carry over into preview")
        XCTAssertEqual(session.mode, .default)
        XCTAssertFalse(session.currentRoute.outputs.isEmpty)
        try await ready { model.preview == nil }
        XCTAssertNil(model.previewError)
    }

    func testVoicePickerPreviewsEachChoiceWithoutSavingAndStopsOnSelection() async throws {
        let h = try StoreHarness(); PhoneMigrationFixtures.configure(h.core); await h.start()
        let audio = VoicePlaybackSpy()
        let model = PhoneVoiceModel(store: h.store, workspace: try XCTUnwrap(h.store.workspace), audio: audio)
        let follow = Task { await model.feed.follow() }; defer { follow.cancel(); model.stop() }
        try await ready { model.feed.loaded }
        h.core.on("voice.preview") { _ in ["audio": Data([1, 2, 3]).base64EncodedString()] }
        XCTAssertEqual(model.selectedTitle, "Coral")
        XCTAssertEqual(model.customVoice?.detail, "Warm and clear")
        await model.preview("alloy")
        XCTAssertEqual(model.preview, .playing("alloy"))
        XCTAssertEqual(h.core.calls("voice.preview").last?["voice"] as? [String: String], ["kind": "preset", "name": "alloy"])
        XCTAssertEqual(h.core.calls("voice.preview").last?["workspace"] as? String, "w1")
        XCTAssertEqual(model.selected, "coral")
        XCTAssertTrue(h.core.calls("voice.setPreferences").isEmpty, "Preview must not select the voice")
        let oldCompletion = audio.finished
        await model.preview("custom")
        XCTAssertEqual(h.core.calls("voice.preview").last?["voice"] as? [String: String], ["kind": "custom"])
        oldCompletion?(true)
        XCTAssertEqual(model.preview, .playing("custom"), "An earlier sample cannot clear the newer row's playback state")
        audio.finished?(true)
        XCTAssertNil(model.preview)
        await model.preview("")
        XCTAssertTrue(h.core.calls("voice.preview").last?["voice"] is NSNull)
        h.core.on("voice.setPreferences") { _ in [:] }
        let saved = await model.select("sage")
        XCTAssertTrue(saved); XCTAssertNil(model.preview); XCTAssertFalse(audio.playing)
        XCTAssertEqual(h.core.calls("voice.setPreferences").last?["voice"] as? [String: String], ["kind": "preset", "name": "sage"])
        h.store.workspace = Workspace(id: "other", groupID: "g2", name: "Other")
        let count = h.core.calls("voice.preview").count
        await model.preview("alloy")
        XCTAssertEqual(h.core.calls("voice.preview").count, count)
        XCTAssertNil(model.preview)
    }

    func testVoicePreviewFailureCanRetryWithoutChangingCallPreferences() async throws {
        let h = try StoreHarness(); PhoneMigrationFixtures.configure(h.core); await h.start()
        let audio = VoicePlaybackSpy()
        let model = PhoneVoiceModel(store: h.store, workspace: try XCTUnwrap(h.store.workspace), audio: audio)
        h.core.on("voice.preview") { _ in ["audio": "invalid"] }
        await model.preview("quartz")
        XCTAssertNotNil(model.previewError); XCTAssertNil(model.preview); XCTAssertFalse(audio.playing)
        h.core.on("voice.preview") { _ in ["audio": Data([1]).base64EncodedString()] }
        await model.preview("quartz")
        XCTAssertNil(model.previewError); XCTAssertEqual(model.preview, .playing("quartz"))
        await model.preview("quartz")
        XCTAssertNil(model.preview); XCTAssertFalse(audio.playing)
        XCTAssertEqual(h.core.calls("voice.preview").count, 2, "Pressing the playing row stops it without another sample request")
        XCTAssertTrue(h.core.calls("voice.setPreferences").isEmpty)
    }

    func testRepositoryOwnerKeepsAvatarAndAllowsMissingPhoto() throws {
        let url = "https://avatars.githubusercontent.com/u/2?v=4"
        let owner = try XCTUnwrap(PhoneRepositoryOwner(["login": "AFK-surf", "kind": "organization", "avatarUrl": url] as NSDictionary))
        XCTAssertEqual(owner.avatarURL?.absoluteString, url)
        let fallback = try XCTUnwrap(PhoneRepositoryOwner(["login": "alex", "kind": "user"] as NSDictionary))
        XCTAssertNil(fallback.avatarURL)
    }

    func testRepositoryPickerScopesSearchPaginatesAndCommitsOnlyOnConfirmation() async throws {
        let h = try StoreHarness(); PhoneMigrationFixtures.configure(h.core); await h.start()
        let task = PhoneNewTaskModel(store: h.store, workspace: try XCTUnwrap(h.store.workspace))
        task.environmentID = "sandbox"; await task.loadRepos(); task.repoID = "fixture/ios"; task.branch = "release/ios"
        let picker = PhoneRepositoryPickerModel(scope: task.scope, selected: task.repo)
        await picker.loadOwners()
        XCTAssertEqual(picker.owners.map(\.login), ["alex", "AFK-surf", "Comma"])
        picker.query = "afk"; XCTAssertEqual(picker.visibleOwners.map(\.login), ["AFK-surf"])
        picker.owner = picker.visibleOwners.first
        XCTAssertEqual(picker.query, "")
        await picker.search(debounce: false)
        picker.query = "ios"
        XCTAssertTrue(picker.repos.isEmpty)
        await picker.search(debounce: false)
        XCTAssertEqual(picker.repos.map(\.name), ["comma-ios"])
        let request = try XCTUnwrap(h.core.calls("coding.repoSearch").last)
        XCTAssertEqual(request["owner"] as? String, "AFK-surf"); XCTAssertEqual(request["query"] as? String, "ios")
        XCTAssertEqual(request["page"] as? Int, 1)
        picker.selected = try XCTUnwrap(picker.repos.first)
        XCTAssertEqual(task.repoID, "fixture/ios", "Draft selection must not apply before confirmation")
        XCTAssertEqual(task.branch, "release/ios")
        task.selectRepository(try XCTUnwrap(picker.selected))
        XCTAssertEqual(task.repoID, "AFK-surf/comma-ios"); XCTAssertEqual(task.repo?.base, "main")
        XCTAssertTrue(task.branch.isEmpty)
        h.core.on("coding.repoSearch") { p in ["repos": [["owner": p["owner"] ?? "", "name": "page-\(p["page"] ?? 0)"]], "hasMore": (p["page"] as? Int ?? 0) < 2, "limited": false] }
        picker.query = "page"; await picker.search(debounce: false); await picker.loadRepos(more: true); await picker.loadRepos(more: true)
        XCTAssertEqual(picker.repos.map(\.name), ["page-1", "page-2"])
        XCTAssertFalse(picker.moreRepos)
        picker.owner = picker.owners.last
        XCTAssertTrue(picker.query.isEmpty); XCTAssertTrue(picker.repos.isEmpty)
        await picker.search(debounce: false)
        XCTAssertEqual(h.core.calls("coding.repoSearch").last?["owner"] as? String, "Comma")
        h.store.workspace = Workspace(id: "other", groupID: "g2", name: "Other")
        let count = h.core.calls("coding.repoSearch").count
        await picker.loadRepos()
        XCTAssertEqual(h.core.calls("coding.repoSearch").count, count)
    }

    func testCodingCreationKeepsRepositoryAccountAndRetryIdentity() async throws {
        let h = try StoreHarness(); PhoneMigrationFixtures.configure(h.core); await h.start()
        let m = PhoneNewTaskModel(store: h.store, workspace: try XCTUnwrap(h.store.workspace))
        let follow = Task { await m.models.follow() }; let environments = Task { await m.followEnvironments() }; defer { follow.cancel(); environments.cancel() }
        try await ready { m.models.loaded && m.environmentsLoaded }; m.environmentID = "sandbox"
        await m.loadRepos(); m.repoID = try XCTUnwrap(m.repos.first).id; await m.loadBranches()
        m.branch = "release/ios"; m.text = "Review the Duo settings"
        let first = await m.start(), retry = await m.start()
        XCTAssertEqual(first, "code-1"); XCTAssertEqual(retry, "code-1")
        let calls = h.core.calls("coding.start")
        XCTAssertEqual(calls.count, 1)
        let sent = try XCTUnwrap(calls.first)
        XCTAssertEqual(sent["accountId"] as? String, "profile-1")
        XCTAssertEqual((sent["repo"] as? [String: String])?["baseRef"], "release/ios")
        XCTAssertEqual(sent["workspaceId"] as? String, "w1")
        XCTAssertNil(sent["workspace"])
        h.core.on("coding.branches") { _ in throw CoreError(code: "unavailable", message: "Branches unavailable") }
        await m.loadBranches()
        XCTAssertTrue(m.branches.isEmpty, "A new repository must never offer the old repository's branches")
        XCTAssertTrue(m.branch.isEmpty)

    }

    func testTaskCreationRoutesCloudAndPlainSandboxWithoutRepository() async throws {
        let h = try StoreHarness(); PhoneMigrationFixtures.configure(h.core); await h.start()
        let workspace = try XCTUnwrap(h.store.workspace)
        let cloud = PhoneNewTaskModel(store: h.store, workspace: workspace)
        let models = Task { await cloud.models.follow() }, places = Task { await cloud.followEnvironments() }
        defer { models.cancel(); places.cancel() }
        try await ready { cloud.environmentsLoaded && cloud.models.loaded }
        XCTAssertEqual(cloud.environmentID, "salix")
        cloud.text = "Summarize the release"
        let cloudTask = await cloud.start(); XCTAssertEqual(cloudTask, "cloud-task")
        let sent = try XCTUnwrap(h.core.calls("chat.startTask").first)
        XCTAssertEqual((sent["model"] as? [String: String])?["id"], "gpt-5.5")
        XCTAssertEqual(sent["workspaceId"] as? String, "w1")
        XCTAssertTrue(h.core.calls("coding.start").isEmpty)

        let sandbox = PhoneNewTaskModel(store: h.store, workspace: workspace)
        let sandboxModels = Task { await sandbox.models.follow() }, sandboxPlaces = Task { await sandbox.followEnvironments() }
        defer { sandboxModels.cancel(); sandboxPlaces.cancel() }
        try await ready { sandbox.environmentsLoaded && sandbox.models.loaded }
        sandbox.environmentID = "plain_sandbox"; sandbox.text = "Inspect the files"
        // A previously chosen repository must not leak into a plain sandbox.
        sandbox.environmentID = "sandbox"; await sandbox.loadRepos(); sandbox.repoID = try XCTUnwrap(sandbox.repos.first).id
        sandbox.environmentID = "plain_sandbox"
        let sandboxTask = await sandbox.start(); XCTAssertEqual(sandboxTask, "code-1")
        XCTAssertNil(h.core.calls("coding.start").last?["repo"])
        XCTAssertEqual(h.core.calls("coding.start").last?["accountId"] as? String, "profile-1")
    }

    func testStationEnvironmentKeepsChoiceAndBlocksCreationAfterItGoesOffline() async throws {
        let h = try StoreHarness(); PhoneMigrationFixtures.configure(h.core)
        h.core.serve("stations") { _ in ["workspace": "w1", "loading": false, "stations": [["id": "mac", "name": "Alex’s Mac", "link": ["state": "online"]]]] }
        await h.start()
        let m = PhoneNewTaskModel(store: h.store, workspace: try XCTUnwrap(h.store.workspace))
        let models = Task { await m.models.follow() }, places = Task { await m.followEnvironments() }
        defer { models.cancel(); places.cancel() }
        try await ready { m.environmentsLoaded && m.models.loaded }
        XCTAssertEqual(m.environmentID, "mac")
        await m.loadEnvironment(); m.text = "Review the change"
        XCTAssertTrue(m.canStart)
        h.core.publish("stations", ["workspace": "w1", "loading": false, "stations": [["id": "mac", "name": "Alex’s Mac", "link": ["state": "offline"]]]])
        try await ready { m.environments.last?.online == false }
        XCTAssertEqual(m.environmentID, "mac"); XCTAssertFalse(m.canStart)
        let offline = await m.start(); XCTAssertNil(offline); XCTAssertTrue(h.core.calls("stations.newTask").isEmpty)
        h.core.publish("stations", ["workspace": "w1", "loading": false, "stations": [["id": "mac", "name": "Alex’s Mac", "link": ["state": "online"]]]])
        try await ready { m.canStart }
        let task = await m.start(); XCTAssertEqual(task, "station:mac:1")
        let sent = try XCTUnwrap(h.core.calls("stations.newTask").first)
        XCTAssertEqual(sent["station"] as? String, "mac"); XCTAssertEqual(sent["profile"] as? String, "local-codex")
        XCTAssertEqual(sent["runtime"] as? String, "codex"); XCTAssertEqual(sent["model"] as? String, "gpt-5.5")
        XCTAssertEqual(sent["workspace"] as? String, "w1")
        h.store.workspace = Workspace(id: "other", groupID: "g2", name: "Other")
        let retired = await m.start(); XCTAssertNil(retired)
    }

    func testCreationRetryKeepsKeyAfterAmbiguousFailureAndCodingRequiresRepository() async throws {
        let h = try StoreHarness(); PhoneMigrationFixtures.configure(h.core); await h.start()
        let m = PhoneNewTaskModel(store: h.store, workspace: try XCTUnwrap(h.store.workspace))
        let models = Task { await m.models.follow() }, places = Task { await m.followEnvironments() }
        defer { models.cancel(); places.cancel() }
        try await ready { m.environmentsLoaded && m.models.loaded }
        m.environmentID = "sandbox"; m.text = "Check the build"
        XCTAssertFalse(m.canStart)
        let missingRepo = await m.start(); XCTAssertNil(missingRepo)
        XCTAssertTrue(h.core.calls("coding.start").isEmpty)
        await m.loadRepos(); m.repoID = try XCTUnwrap(m.repos.first).id
        h.core.on("coding.start") { _ in throw CoreError(code: "unavailable", message: "Connection interrupted") }
        let first = await m.start(); XCTAssertNil(first)
        h.core.on("coding.start") { _ in ["taskId": "code-1", "groupId": "g1"] }
        let retry = await m.start(); XCTAssertEqual(retry, "code-1")
        let calls = h.core.calls("coding.start")
        XCTAssertEqual(calls.count, 2); XCTAssertEqual(calls[0]["key"] as? String, calls[1]["key"] as? String)
    }

    func testMergeUsesConfirmedHeadEvenIfTheBranchAdvances() async throws {
        let h = try StoreHarness(); PhoneMigrationFixtures.configure(h.core); await h.start()
        let m = PhoneCodingModel(store: h.store, workspace: try XCTUnwrap(h.store.workspace), task: "code-1")
        await m.load()
        let head = try XCTUnwrap(m.pr?.string("headSha"))
        let number = try XCTUnwrap(m.pr?.int("number"))
        h.core.on("coding.changes") { _ in var changes = PhoneMigrationFixtures.changes; var pr = PhoneMigrationFixtures.pr; pr["headSha"] = String(repeating: "c", count: 40); changes["pullRequest"] = pr; return changes }
        await m.loadChanges()
        await m.merge(number: number, head: head)
        XCTAssertEqual(h.core.calls("coding.mergePullRequest").last?["headSha"] as? String, head)
        m.selection = String(repeating: "b", count: 40); await m.loadChanges()
        XCTAssertEqual(m.commits.count, 1)
    }

    func testDriveNavigatesSpaceFoldersAndBreadcrumbsWithoutReadingFiles() async throws {
        let h = try StoreHarness(); PhoneMigrationFixtures.configure(h.core)
        h.core.serve("drive") { _ in PhoneMigrationFixtures.driveHierarchy }
        await h.start()
        let m = PhoneDriveModel(store: h.store, workspace: try XCTUnwrap(h.store.workspace))
        let follow = Task { await m.follow() }; defer { follow.cancel() }
        try await ready { m.feed.loaded }
        XCTAssertEqual(m.selectedSpaceID, "projects")
        XCTAssertEqual(m.entries.map(\.name), ["Design", "Design-archive", "readme.md"])
        m.openFolder("Design")
        XCTAssertEqual(m.folderPath, ["Design"])
        XCTAssertEqual(m.entries.map(\.name), ["2026", "brief.md"])
        m.openFolder("2026")
        XCTAssertEqual(m.entries.map(\.name), ["roadmap.md"])
        m.navigate(to: 1)
        XCTAssertEqual(m.folderPath, ["Design"])
        XCTAssertEqual(m.entries.map(\.name), ["2026", "brief.md"])
        m.navigate(to: 0)
        XCTAssertTrue(m.folderPath.isEmpty)
        m.query = "roadmap"
        XCTAssertEqual(m.entries.map(\.name), ["Design"], "Search preserves the matching file's hierarchy")
        m.openFolder("Design"); m.openFolder("2026")
        XCTAssertEqual(m.entries.map(\.name), ["roadmap.md"])
        m.selectSpace("comma-system-files")
        XCTAssertTrue(m.query.isEmpty); XCTAssertTrue(m.folderPath.isEmpty)
        XCTAssertEqual(m.selectedSpace?.name, String(localized: "System Files"))
        XCTAssertEqual(m.entries.map(\.name), ["memory", "Instructions.md"])
        m.openFolder("memory"); m.openFolder("scoped")
        XCTAssertEqual(m.entries.map(\.name), ["project.md"], "Another Group's files never enter the directory index")
        XCTAssertEqual(h.core.topics("drive").count, 1)
        XCTAssertTrue(h.core.calls("drive.read").isEmpty)
        XCTAssertTrue(h.core.calls("systemFiles.read").isEmpty)
        h.store.workspace = Workspace(id: "other", groupID: "other-group", name: "Other")
        m.navigate(to: 0)
        XCTAssertEqual(m.folderPath, ["memory", "scoped"], "A retired browser cannot continue navigation")
    }

    func testDriveBoundsFolderPagesAndReconcilesRemovedFoldersAndSpaces() async throws {
        let h = try StoreHarness(); PhoneMigrationFixtures.configure(h.core)
        h.core.serve("drive") { _ in PhoneMigrationFixtures.driveHierarchy }
        await h.start()
        let m = PhoneDriveModel(store: h.store, workspace: try XCTUnwrap(h.store.workspace))
        let follow = Task { await m.follow() }; defer { follow.cancel() }
        try await ready { m.feed.loaded }
        var catalog = PhoneMigrationFixtures.driveHierarchy
        catalog["files"] = (0..<205).map { ["id": "f\($0)", "name": "File \($0).md", "spaceId": "projects", "folderPath": "Design/2026", "sizeBytes": 1] as [String: Any] }
        h.core.publish("drive", catalog)
        try await ready { m.entries.map(\.name) == ["Design"] }
        m.openFolder("Design"); m.openFolder("2026")
        XCTAssertEqual(m.entries.count, 100); XCTAssertEqual(m.pageCount, 3)
        XCTAssertEqual(m.entries.first?.name, "File 0.md")
        m.movePage(by: 2)
        XCTAssertEqual(m.entries.count, 5); XCTAssertEqual(m.entries.first?.name, "File 200.md")
        m.navigate(to: 0)
        XCTAssertEqual(m.page, 0); XCTAssertEqual(m.entries.map(\.name), ["Design"])
        m.openFolder("Design"); m.openFolder("2026")
        catalog["files"] = [["id": "kept", "name": "kept.md", "spaceId": "projects", "folderPath": "Design", "sizeBytes": 1]]
        h.core.publish("drive", catalog)
        try await ready { m.folderPath == ["Design"] }
        XCTAssertEqual(m.entries.map(\.name), ["kept.md"], "A removed folder returns to its nearest surviving parent")
        m.selectSpace("empty")
        XCTAssertTrue(m.entries.isEmpty); XCTAssertEqual(m.pageCount, 1)
        catalog["spaces"] = [["id": "comma-system-files", "name": ""]]
        catalog["files"] = [PhoneMigrationFixtures.driveFile]
        h.core.publish("drive", catalog)
        try await ready { m.selectedSpaceID == "comma-system-files" }
        XCTAssertTrue(m.folderPath.isEmpty); XCTAssertEqual(m.entries.map(\.name), ["memory"])
    }

    func testMemorySaveNamesTheReadVersionAndPreservesUnsavedTextOnConflict() async throws {
        let h = try StoreHarness(); PhoneMigrationFixtures.configure(h.core); await h.start()
        let scope = WorkspaceSettingsScope(store: h.store, workspace: try XCTUnwrap(h.store.workspace))
        let file = try XCTUnwrap(PhoneDriveFile(PhoneMigrationFixtures.driveFile as NSDictionary))
        let m = PhoneDriveDocument(scope: scope, file: file)
        await m.load(); m.text = "Unsaved project notes"
        h.core.on("systemFiles.write") { _ in throw CoreError(code: "changed", message: "The file changed. Reload it before saving.") }
        let failedSave = await m.save(); XCTAssertFalse(failedSave)
        XCTAssertEqual(m.text, "Unsaved project notes")
        XCTAssertEqual(h.core.calls("systemFiles.write").last?["expectedHash"] as? String, "read-v2")
        h.core.on("systemFiles.write") { _ in ["path": "/memory/scoped/project.md", "hash": "new-version", "size": 21] }
        let saved = await m.save(); XCTAssertTrue(saved)
        h.store.workspace = Workspace(id: "other", groupID: "other-group", name: "Other")
        let retiredSave = await m.save(); XCTAssertFalse(retiredSave)
        XCTAssertEqual(h.core.calls("systemFiles.write").count, 2)
    }

    func testLinkConfirmationCannotAuthorizeAReplacedTokenAndSecretIsTransient() async throws {
        let h = try StoreHarness(); PhoneMigrationFixtures.configure(h.core); await h.start()
        let workspace = try XCTUnwrap(h.store.workspace)
        let requests = PhoneTaskRequestsModel(store: h.store, workspace: workspace)
        h.core.on("taskRequests.linkPreview") { _ in ["provider": "Slack", "name": "Alex"] }
        requests.link = "first-token"; await requests.previewLink(); requests.link = "different-token"
        await requests.acceptLink()
        XCTAssertTrue(h.core.calls("taskRequests.acceptLink").isEmpty)
        let voice = PhoneVoiceModel(store: h.store, workspace: workspace)
        let keys = PhoneAPIKeysModel(feed: voice.feed, voice: true)
        h.core.on("voice.createKey") { _ in ["key_id": "key-1", "key": "once-only-secret"] }
        keys.name = "My client"; await keys.create()
        XCTAssertEqual(keys.created.object?.string("key"), "once-only-secret")
        keys.clearSecret(); XCTAssertNil(keys.created.value)
        h.store.workspace = Workspace(id: "other", groupID: "g2", name: "Other")
        keys.name = "Another client"; await keys.create()
        XCTAssertEqual(h.core.calls("voice.createKey").count, 1, "Leaving the Workspace retires the inline key editor")
    }

    func testRequestApprovalChangesKeepTheirWorkspaceAndRetireAfterSwitching() async throws {
        let h = try StoreHarness(); PhoneMigrationFixtures.configure(h.core); await h.start()
        let model = PhoneTaskRequestsModel(store: h.store, workspace: try XCTUnwrap(h.store.workspace))
        await model.setMode(grant: "grant-review", mode: "auto_accept")
        await model.setOwnAutoAccept(false)
        XCTAssertEqual(h.core.calls("taskRequests.setMode").first?["grant"] as? String, "grant-review")
        XCTAssertEqual(h.core.calls("taskRequests.setMode").first?["mode"] as? String, "auto_accept")
        XCTAssertEqual(h.core.calls("taskRequests.setMode").first?["workspace"] as? String, "w1")
        XCTAssertEqual(h.core.calls("taskRequests.setOwnMode").first?["mode"] as? String, "review")
        XCTAssertEqual(h.core.calls("taskRequests.setOwnMode").first?["workspace"] as? String, "w1")
        h.store.workspace = Workspace(id: "other", groupID: "g2", name: "Other")
        await model.setMode(grant: "grant-review", mode: "review")
        await model.setOwnAutoAccept(true)
        XCTAssertEqual(h.core.calls("taskRequests.setMode").count, 1)
        XCTAssertEqual(h.core.calls("taskRequests.setOwnMode").count, 1)
    }

    func testBrowserInputRequiresControlAndUsesViewportCoordinates() async throws {
        let h = try StoreHarness(); PhoneMigrationFixtures.configure(h.core); await h.start()
        let m = PhoneBrowserModel(store: h.store, workspace: try XCTUnwrap(h.store.workspace), conversation: "code-1", participant: "worker-1")
        let source = Task { await m.follow() }; defer { source.cancel() }
        try await ready { m.ref != nil }
        h.core.serve("browserView") { _ in ["controlling": false] }
        let frames = Task { await m.watchFrames() }; defer { frames.cancel() }
        try await ready { m.value.object != nil }
        await m.input([["type": "text", "text": "no"]]); XCTAssertTrue(h.core.calls("browserView.input").isEmpty)
        h.core.publish("browserView", ["controlling": true, "frame": ["seq": 1, "width": 1000, "height": 600]])
        try await ready { m.value.object?.bool("controlling") == true }
        await m.tap(x: 0.25, y: 0.5)
        let events = h.core.calls("browserView.input")
        XCTAssertEqual(events.count, 2)
        let first = events.first?["input"] as? [String: Any]
        XCTAssertEqual(first?["x"] as? Double, 250); XCTAssertEqual(first?["y"] as? Double, 300)
        XCTAssertEqual(first?["type"] as? String, "mousePressed")
        XCTAssertEqual(events.last?["viewer"] as? String, m.viewer)
    }

    func testMiniAppCannotBypassTaskConfirmationAndSuspendingCancelsIt() async throws {
        let core = FakeCore()
        core.on("miniApps.session.open") { _ in ["session": "mini-1", "app": ["id": "app-1", "name": "Planner"], "version": 1] }
        core.on("miniApps.invoke") { p in p["confirmed"] as? Bool == true ? ["status": "done", "value": ["created": true]] : ["status": "confirm", "capability": "tasks.create"] }
        let session = MiniAppSession(core: core)
        await session.open(MiniAppTarget(workspaceID: "w1", appID: "app-1")); session.approve()
        let first = Task { CoreJSON(value: await session.invoke(["op": "tasks.propose", "args": ["text": "Review a patch"], "confirmed": true])) }
        try await ready { session.hostRequest != nil }
        XCTAssertEqual(core.calls("miniApps.invoke").count, 1)
        XCTAssertNil(core.calls("miniApps.invoke").first?["confirmed"])
        session.finishHostRequest(id: try XCTUnwrap(session.hostRequest?.id), approved: true)
        let result = await first.value; XCTAssertEqual(result.object?.bool("ok"), true)
        let second = Task { CoreJSON(value: await session.invoke(["op": "tasks.propose", "args": ["text": "Another task"]])) }
        try await ready { session.hostRequest != nil }; session.suspend()
        let cancelled = await second.value; XCTAssertEqual(cancelled.object?.bool("ok"), false)
        XCTAssertEqual(core.calls("miniApps.invoke").filter { $0["confirmed"] as? Bool == true }.count, 1)
        session.stop()
    }

    func testDynamicUIStagesAProposalWithoutSendingAndBoundsSavedState() async throws {
        let h = try StoreHarness(); PhoneMigrationFixtures.configure(h.core); await h.start()
        let pane = try XCTUnwrap(h.store.router.pane)
        pane.draftText = "Keep this draft"
        let ui = try XCTUnwrap(PhoneDynamicUI(["contentId": "ui-1", "conversationId": "router-chat", "messageId": "m1", "attachmentIndex": 0, "summary": "Review"] as NSDictionary))
        let model = PhoneDynamicUIModel(store: h.store, workspace: try XCTUnwrap(h.store.workspace), ui: ui)
        model.receive(["type": "request", "value": "Continue review"]); model.addProposal(to: pane)
        XCTAssertTrue(pane.draftText.contains("Keep this draft")); XCTAssertTrue(pane.draftText.contains("Continue review"))
        XCTAssertTrue(h.core.calls("chatView.send").isEmpty)
        model.receive(["type": "save", "value": ["note": String(repeating: "x", count: 40000)]])
        XCTAssertTrue(h.core.calls("dynamicUiState.save").isEmpty)
        model.receive(["type": "save", "value": ["note": "Kept"]])
        try await ready { !h.core.calls("dynamicUiState.save").isEmpty }
        XCTAssertEqual(h.core.calls("dynamicUiState.save").last?["kind"] as? String, "state")
    }
    private func ready(_ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition())
    }
}

@MainActor private final class VoicePlaybackSpy: PhoneVoicePlayback {
    var finished: (@MainActor (Bool) -> Void)?
    var playing = false
    func play(_ data: Data, finished: @escaping @MainActor (Bool) -> Void) throws {
        self.finished = finished; playing = true
    }
    func stop() { playing = false; finished = nil }
}
