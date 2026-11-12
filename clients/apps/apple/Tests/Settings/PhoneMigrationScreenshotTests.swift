import SwiftUI
import XCTest
import CommaCore
@testable import Comma

@MainActor final class PhoneMigrationScreenshotTests: XCTestCase {
    func testVoicePickerSheetLayout() async throws {
        let h = try StoreHarness(); PhoneMigrationFixtures.configure(h.core)
        h.core.serve("voice") { _ in
            var value = PhoneMigrationFixtures.voice
            var integration = value["integration"] as! [String: Any]
            integration["voices"] = ["quartz", "ripple", "vesper", "willow", "brise", "harema", "noeul"]
            value["integration"] = integration
            return value
        }
        await h.start()
        let model = PhoneVoiceModel(store: h.store, workspace: try XCTUnwrap(h.store.workspace))
        let view = PhoneVoiceSettingsView(model: model).sheet(isPresented: .constant(true)) {
            NavigationStack { PhoneVoicePickerView(model: model).sheetCloseButton {} }.commaSheet([.large])
        }
        try await capture("voice-picker-sheet", view: view) { model.feed.loaded }
    }

    func testChannelsOverviewReadsConnectionStatuses() async throws {
        let h = try StoreHarness(); PhoneMigrationFixtures.configure(h.core)
        h.core.serve("wechat") { _ in ["state": ["connection": ["connection_active": false]], "error": false] }
        h.core.serve("imessage") { _ in ["state": ["connection_active": true, "link": ["sender_handle": "alex@example.com"]], "error": true] }
        await h.start()
        try await capture("channels-overview", view: PhoneChannelsView(store: h.store, workspace: try XCTUnwrap(h.store.workspace)), inspect: { _ in
            for channel in PhoneChannel.allCases {
                let topics = h.core.topics(channel.rawValue)
                XCTAssertEqual(topics.count, 1, "Each channel has one status subscription while the overview is visible")
                if channel != .telegram { XCTAssertEqual(topics.first?["workspace"] as? String, "w1") }
            }
        }) { PhoneChannel.allCases.allSatisfy { h.core.topics($0.rawValue).count == 1 } }
    }

    func testVoiceSettingsDesktopLayout() async throws {
        let h = try StoreHarness(); PhoneMigrationFixtures.configure(h.core); await h.start()
        let model = PhoneVoiceModel(store: h.store, workspace: try XCTUnwrap(h.store.workspace))
        try await capture("voice-01-numbers-calls", view: PhoneVoiceSettingsView(model: model), inspect: { window in
            XCTAssertEqual(h.core.topics("voice").count, 1, "Inline keys share the voice page's subscription")
            func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
            let scrolls = views(window).compactMap { $0 as? UIScrollView }
                .filter { !($0 is UITextView) && $0.bounds.width > 0 && $0.contentSize.height > $0.bounds.height }
            XCTAssertEqual(scrolls.count, 1, "Phone numbers, calls, keys, and status use one scroll view")
            let scroll = try XCTUnwrap(scrolls.first)
            let travel = max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            for (fraction, name) in [(0.5, "voice-02-calls-keys"), (1.0, "voice-03-keys-status")] {
                scroll.setContentOffset(CGPoint(x: 0, y: travel * fraction), animated: false)
                window.layoutIfNeeded(); self.save(window, name)
            }
        }) { model.feed.loaded }
    }

    func testDriveToolbarAcceptanceScreenshots() async throws {
        let scene = try scene()
        let h = try StoreHarness(); PhoneMigrationFixtures.configure(h.core); await h.start()
        h.store.tasksLoaded = true; h.store.profileRead = true
        let navigation = AppNavigation(tab: .settings)
        let root = UIHostingController(rootView: ShellTabs(store: h.store, activity: TaskActivityCoordinator(), query: HomeTaskQuery())
            .environment(navigation).providingInbox(store: h.store))
        let original = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .light
        let container = UIViewController()
        window.rootViewController = container
        container.addChild(root); container.view.addSubview(root.view); root.didMove(toParent: container)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; original?.makeKeyAndVisible() }
        let wide = window.bounds.width >= ShellTabs.minimumColumnWidth * 2
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: wide ? .landscapeLeft : .portrait))
        root.view.frame = window.bounds
        navigation.settingsPath = [.drive]
        let deadline = ContinuousClock.now + .seconds(5)
        while h.core.topics("drive").isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(1100)); window.layoutIfNeeded()
        save(window, wide ? "drive-duo-navigation" : "drive-iphone-navigation")
        XCTAssertFalse(h.core.topics("drive").isEmpty, "The screenshot renders the live Drive page against the local test Core")
    }

    func testTaskRequestsUsesOneScrollingPage() async throws {
        let h = try StoreHarness(); PhoneMigrationFixtures.configure(h.core)
        h.core.serve("taskRequests") { _ in PhoneMigrationFixtures.requestLayout }
        await h.start()
        let model = PhoneTaskRequestsModel(store: h.store, workspace: try XCTUnwrap(h.store.workspace))
        try await capture("requests-01-incoming-access", view: PhoneTaskRequestsView(model: model), inspect: { window in
            func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
            let scrolls = views(window).compactMap { $0 as? UIScrollView }
                .filter { !($0 is UITextView) && $0.bounds.width > 0 && $0.contentSize.height > $0.bounds.height }
            XCTAssertEqual(scrolls.count, 1, "All request settings share one vertical scroll view")
            let scroll = try XCTUnwrap(scrolls.first)
            let travel = max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            XCTAssertGreaterThan(travel, 0, "Access, sent requests, and accounts follow the waiting request")
            for (fraction, name) in [(0.35, "requests-02-access-targets"), (0.7, "requests-03-sent"), (1.0, "requests-04-chat-accounts")] {
                scroll.setContentOffset(CGPoint(x: 0, y: travel * fraction), animated: false)
                window.layoutIfNeeded()
                self.save(window, name)
            }
        }) { model.feed.loaded }
    }

    func testDriveFolderHierarchyOnPhone() async throws {
        let h = try StoreHarness(); PhoneMigrationFixtures.configure(h.core)
        h.core.serve("drive") { _ in PhoneMigrationFixtures.driveHierarchy }
        await h.start()
        let model = PhoneDriveModel(store: h.store, workspace: try XCTUnwrap(h.store.workspace))
        try await capture("drive-01-space-root", view: PhoneDriveView(model: model)) { model.feed.loaded }
        model.openFolder("Design")
        try await capture("drive-02-folder", view: PhoneDriveView(model: model)) { model.folderPath == ["Design"] }
        model.openFolder("2026")
        try await capture("drive-03-breadcrumb", view: PhoneDriveView(model: model), inspect: {
            try self.assertDriveBreadcrumb($0, names: ["Projects", "Design", "2026"])
        }) { model.folderPath == ["Design", "2026"] }
        model.navigate(to: 0)
        model.query = "roadmap"
        try await capture("drive-04-search", view: PhoneDriveView(model: model)) { model.entries.map(\.name) == ["Design"] }
        model.selectSpace("comma-system-files"); model.openFolder("memory"); model.openFolder("scoped")
        try await capture("drive-05-system-files", view: PhoneDriveView(model: model)) { model.folderPath == ["memory", "scoped"] }
    }

    func testFeaturePagesOnIPhone() async throws {
        let h = try StoreHarness(); PhoneMigrationFixtures.configure(h.core); await h.start()
        let workspace = try XCTUnwrap(h.store.workspace)
        let coding = PhoneNewTaskModel(store: h.store, workspace: workspace)
        coding.environmentID = "sandbox"
        coding.text = "梳理 iOS 与桌面端的功能差异，补齐 Duo 适配。"
        try await capture("01-new-coding-task", view: PhoneNewTaskView(model: coding)) {
            guard coding.models.loaded, coding.reposLoaded else { return false }
            if coding.repoID.isEmpty { coding.repoID = coding.repos.first?.id ?? ""; return false }
            return !coding.branches.isEmpty
        }
        let review = PhoneCodingModel(store: h.store, workspace: workspace, task: "code-1")
        try await capture("02-code-review", view: PhoneCodingView(model: review)) { review.loaded }
        let drive = PhoneDriveModel(store: h.store, workspace: workspace)
        try await capture("03-system-files", view: PhoneDriveView(model: drive)) { drive.feed.loaded }
        let document = PhoneDriveDocument(scope: drive.scope, file: PhoneDriveFile(PhoneMigrationFixtures.driveFile as NSDictionary))
        try await capture("04-memory-editor", view: PhoneDriveDocumentView(model: document)) { document.loaded }
        let requests = PhoneTaskRequestsModel(store: h.store, workspace: workspace)
        try await capture("05-task-requests", view: PhoneTaskRequestsView(model: requests)) { requests.feed.loaded }
        let shares = WorkspaceTopic(store: h.store, workspace: workspace, topic: "taskShares", parameters: ["workspace": workspace.id], workspaceField: true)
        try await capture("06-shared-tasks", view: PhoneSharedTasksView(feed: shares)) { shares.loaded }
        let voice = PhoneVoiceModel(store: h.store, workspace: workspace)
        try await capture("07-voice-settings", view: PhoneVoiceSettingsView(model: voice)) { voice.feed.loaded }
        let keys = PhoneAPIKeysModel(store: h.store, workspace: workspace, voice: false)
        try await capture("08-router-api-keys", view: PhoneAPIKeysView(model: keys)) { keys.feed.loaded }
        let linear = PhoneChannelModel(store: h.store, workspace: workspace, channel: .linear)
        try await capture("09-linear-channel", view: PhoneChannelView(model: linear)) { linear.feed.loaded }
        let compute = WorkspaceTopic(store: h.store, workspace: workspace, topic: "compute", parameters: ["prefer": workspace.id], workspaceField: true)
        try await capture("10-compute", view: PhoneComputeView(feed: compute)) { compute.loaded }
        let ui = try XCTUnwrap(PhoneDynamicUI(["contentId": "ui-1", "conversationId": "router-chat", "messageId": "m1", "attachmentIndex": 0, "summary": "Review"] as NSDictionary))
        let dynamic = PhoneDynamicUIModel(store: h.store, workspace: workspace, ui: ui)
        try await capture("11-dynamic-ui", view: PhoneDynamicUIView(model: dynamic, pane: try XCTUnwrap(h.store.router.pane))) { dynamic.runtimeReady || dynamic.failure != nil }
        XCTAssertNil(dynamic.failure)
        XCTAssertTrue(dynamic.runtimeReady)
        try await capture("12-remote-screen", view: PhoneScreenView(scope: WorkspaceSettingsScope(store: h.store, workspace: workspace), device: "fixture-device")) { true }
        try await capture("23-code-diff", view: PhoneCodePatchView(file: try XCTUnwrap(review.files.first))) { true }
        try await capture("24-execution-history", view: PhoneCodingHistoryView(model: review)) { review.history.object != nil }
        try await capture("26-request-review", view: PhoneRequestDetail(model: requests, request: PhoneMigrationFixtures.request as NSDictionary, incoming: true)) { requests.feed.loaded }
        try await capture("27-send-request", view: PhoneSendRequestView(model: requests, target: try XCTUnwrap(requests.rows("targets").first))) { true }
        let voiceKeys = PhoneAPIKeysModel(store: h.store, workspace: workspace, voice: true)
        try await capture("28-voice-api-keys", view: PhoneAPIKeysView(model: voiceKeys)) { voiceKeys.feed.loaded }
        for (kind, name) in [(PhoneChannel.telegram, "29-telegram"), (.wechat, "30-wechat"), (.signal, "31-signal"), (.imessage, "32-imessage")] {
            let channel = PhoneChannelModel(store: h.store, workspace: workspace, channel: kind)
            try await capture(name, view: PhoneChannelView(model: channel)) { channel.feed.loaded }
        }
        let sample = UIGraphicsImageRenderer(size: CGSize(width: 900, height: 520)).image { context in
            UIColor.systemBackground.setFill(); context.fill(CGRect(x: 0, y: 0, width: 900, height: 520))
            ("本地浏览器测试页面" as NSString).draw(at: CGPoint(x: 48, y: 64), withAttributes: [.font: UIFont.preferredFont(forTextStyle: .largeTitle), .foregroundColor: UIColor.label])
            ("Duo layout review · Sample content\n\nBoth headings align left.\nThis image is supplied by the local test service." as NSString).draw(in: CGRect(x: 48, y: 140, width: 800, height: 280), withAttributes: [.font: UIFont.systemFont(ofSize: 28), .foregroundColor: UIColor.secondaryLabel])
        }
        let encoded = try XCTUnwrap(sample.jpegData(compressionQuality: 0.8)).base64EncodedString()
        h.core.serve("browserView") { _ in ["tabs": [["tab_id": "tab-1", "title": "本地浏览器测试页面", "url": "https://example.test"]], "tab": "tab-1", "controlling": true, "status": "human", "pending": false, "frame": ["seq": 1, "data": encoded, "width": 900, "height": 520]] }
        let browser = PhoneBrowserModel(store: h.store, workspace: workspace, conversation: "code-1", participant: "worker-1")
        try await capture("21-remote-browser", view: PhoneBrowserView(model: browser)) { browser.loaded && browser.value.object != nil }
        let mini = MiniAppSession(core: h.core)
        let request = MiniAppHostRequest(op: "tasks.propose", detail: "审查 iOS 迁移功能，并检查 Duo 上的布局。")
        try await capture("22-mini-app-confirmation", view: MiniAppHostPermissionSheet(session: mini, request: request)) { true }
    }

    func testDynamicRuntimeProposesTextAndSavesThroughTheIsolatedBridge() async throws {
        let h = try StoreHarness(); PhoneMigrationFixtures.configure(h.core); await h.start()
        h.core.serve("dynamicUi") { _ in ["status": "ready", "ui": ["version": 1, "html": "<div class='card'><h2>Native bridge test</h2><p>Interactive content is isolated.</p></div>", "script": "comma.save({nativeBridge:typeof globalThis.webkit});comma.request('Review this result');", "data": [:]]] }
        let ui = try XCTUnwrap(PhoneDynamicUI(["contentId": "isolated-ui", "conversationId": "router", "messageId": "message-1", "attachmentIndex": 0, "summary": "Test"] as NSDictionary))
        let model = PhoneDynamicUIModel(store: h.store, workspace: try XCTUnwrap(h.store.workspace), ui: ui)
        let pane = try XCTUnwrap(h.store.router.pane); pane.draftText = "Keep this draft"
        try await capture("33-dynamic-proposal", view: PhoneDynamicUIView(model: model, pane: pane)) { model.proposal != nil && !h.core.calls("dynamicUiState.save").isEmpty }
        XCTAssertNil(model.failure)
        XCTAssertEqual(model.proposal, "Review this result")
        XCTAssertEqual(pane.draftText, "Keep this draft")
        XCTAssertTrue(h.core.calls("chatView.send").isEmpty)
        let state = try XCTUnwrap(h.core.calls("dynamicUiState.save").last?["text"] as? String)
        XCTAssertTrue(state.contains("undefined"))
    }

    func testDuoFeatureColumns() async throws {
        let scene = try scene()
        let h = try StoreHarness(); PhoneMigrationFixtures.configure(h.core); await h.start()
        h.store.tasksLoaded = true; h.store.profileRead = true
        let navigation = AppNavigation(tab: .settings)
        let root = UIHostingController(rootView: ShellCard(store: h.store, activity: TaskActivityCoordinator(), navigation: navigation, query: HomeTaskQuery()))
        let original = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene); let container = UIViewController()
        window.rootViewController = container; container.addChild(root); container.view.addSubview(root.view); root.didMove(toParent: container)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; original?.makeKeyAndVisible(); scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeLeft))
        let deadline = ContinuousClock.now + .seconds(12)
        while window.bounds.width < ShellTabs.minimumColumnWidth * 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
        guard window.bounds.width >= ShellTabs.minimumColumnWidth * 2 else { throw XCTSkip("Run on the unfolded Duo display") }
        root.view.frame = window.bounds
        for (route, name) in [(SettingsRoute.drive, "14-duo-system-files"), (.requests, "15-duo-task-requests"), (.shares, "16-duo-shared-tasks"), (.voice, "17-duo-voice"), (.channels, "18-duo-channels"), (.routerKeys, "19-duo-router-keys"), (.compute, "20-duo-compute")] {
            navigation.settingsPath = [route]
            try await Task.sleep(for: .milliseconds(1000)); window.layoutIfNeeded()
            XCTAssertEqual(navigation.settingsPath, [route])
            let title: String
            switch route {
            case .drive: title = String(localized: "Drive")
            case .requests: title = String(localized: "Task requests")
            case .shares: title = String(localized: "Shared tasks")
            case .voice: title = String(localized: "Voice settings")
            case .channels: title = String(localized: "Channels")
            case .routerKeys: title = String(localized: "Router API keys")
            default: title = String(localized: "Compute resources")
            }
            try assertHeadings(window, title: title)

            save(window, name)
        }
    }
    func testNewTaskComposerOnIPhone() async throws {
        let scene = try scene()
        let h = try StoreHarness(); PhoneMigrationFixtures.configure(h.core); await h.start()
        let original = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .light
        let model = PhoneNewTaskModel(store: h.store, workspace: try XCTUnwrap(h.store.workspace))
        model.environmentID = "sandbox"
        model.text = "检查 iOS 布局，并完善 Duo 适配。"
        let navigation = AppNavigation(tab: .home)
        window.rootViewController = UIHostingController(rootView:
            ShellCard(store: h.store, activity: TaskActivityCoordinator(), navigation: navigation, query: HomeTaskQuery())
                .sheet(isPresented: .constant(true)) { NavigationStack { PhoneNewTaskView(model: model) }.commaSheet([.medium, .large]) }
        )
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; original?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(1500))
        model.repoID = model.repos.first?.id ?? ""
        try await Task.sleep(for: .milliseconds(600)); window.layoutIfNeeded()
        XCTAssertTrue(model.environmentsLoaded); XCTAssertFalse(model.branches.isEmpty)
        save(window, "41-iphone-new-task-coding")
        try assertTaskSheet(window, requiresActionFrame: false)
    }

    func testTaskPanelCreationOnDuo() async throws {
        let scene = try scene()
        let h = try StoreHarness(); PhoneMigrationFixtures.configure(h.core); await h.start()
        h.store.tasksLoaded = true; h.store.profileRead = true
        let navigation = AppNavigation(tab: .home)
        let original = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = UIHostingController(rootView: ShellCard(store: h.store, activity: TaskActivityCoordinator(), navigation: navigation, query: HomeTaskQuery()))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; original?.makeKeyAndVisible(); scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeLeft))
        let deadline = ContinuousClock.now + .seconds(12)
        while window.bounds.width < ShellTabs.minimumColumnWidth * 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
        guard window.bounds.width >= ShellTabs.minimumColumnWidth * 2 else { throw XCTSkip("Run on the unfolded Duo display") }
        try await Task.sleep(for: .milliseconds(1500)); window.layoutIfNeeded()
        save(window, "35-duo-task-panel")
        navigation.newTaskOpen = true
        try await Task.sleep(for: .milliseconds(1800)); window.layoutIfNeeded()
        save(window, "36-duo-new-task-cloud")
        navigation.newTaskOpen = false
        try await Task.sleep(for: .milliseconds(500))
        let workspace = try XCTUnwrap(h.store.workspace)
        let model = PhoneNewTaskModel(store: h.store, workspace: workspace)
        model.environmentID = "sandbox"
        model.text = "检查 iOS 布局，并完善 Duo 适配。"
        window.rootViewController = UIHostingController(rootView:
            ShellCard(store: h.store, activity: TaskActivityCoordinator(), navigation: navigation, query: HomeTaskQuery())
                .sheet(isPresented: .constant(true)) { NavigationStack { PhoneNewTaskView(model: model) }.commaSheet([.medium, .large]) }
        )
        try await Task.sleep(for: .milliseconds(1200))
        model.repoID = model.repos.first?.id ?? ""
        try await Task.sleep(for: .milliseconds(600)); window.layoutIfNeeded()
        XCTAssertTrue(model.environmentsLoaded); XCTAssertFalse(model.branches.isEmpty)
        try assertTaskSheet(window)
        save(window, "37-duo-new-task-coding")
        model.environmentID = "plain_sandbox"
        try await Task.sleep(for: .milliseconds(500)); window.layoutIfNeeded()
        save(window, "38-duo-new-task-sandbox")
        h.core.publish("stations", ["workspace": "w1", "loading": false, "stations": [["id": "mac", "name": "Alex’s Mac", "link": ["state": "online"]]]])
        model.environmentID = "mac"
        try await Task.sleep(for: .milliseconds(700)); window.layoutIfNeeded()
        XCTAssertTrue(model.profilesLoaded)
        save(window, "39-duo-new-task-computer")
    }

    func testNewTaskComposerOnClosedDuo() async throws {
        let scene = try scene()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
        try await Task.sleep(for: .milliseconds(800))
        guard scene.coordinateSpace.bounds.width < ShellTabs.minimumColumnWidth * 2 else {
            throw XCTSkip("Close the Duo display before this test")
        }
        let h = try StoreHarness(); PhoneMigrationFixtures.configure(h.core); await h.start()
        let original = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene); window.overrideUserInterfaceStyle = .light
        let model = PhoneNewTaskModel(store: h.store, workspace: try XCTUnwrap(h.store.workspace))
        model.environmentID = "sandbox"; model.text = "检查合上状态的创建面板。"
        let navigation = AppNavigation(tab: .home)
        window.rootViewController = UIHostingController(rootView:
            ShellCard(store: h.store, activity: TaskActivityCoordinator(), navigation: navigation, query: HomeTaskQuery())
                .sheet(isPresented: .constant(true)) { NavigationStack { PhoneNewTaskView(model: model) }.commaSheet(selection: .constant(.large)) }
        )
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; original?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(1500))
        model.repoID = model.repos.first?.id ?? ""
        try await Task.sleep(for: .milliseconds(600)); window.layoutIfNeeded()
        XCTAssertTrue(model.canStart)
        save(window, "42-duo-closed-new-task")
        try assertTaskSheet(window)
        let sheet = try XCTUnwrap(window.rootViewController?.presentedViewController?.sheetPresentationController)
        sheet.animateChanges { sheet.selectedDetentIdentifier = .medium }
        try await Task.sleep(for: .milliseconds(600)); window.layoutIfNeeded()
        XCTAssertEqual(sheet.selectedDetentIdentifier, .medium)
        try assertTaskSheet(window)
        save(window, "43-duo-closed-new-task-medium")
    }

    func testRepositoryPickerOnDuo() async throws {
        let scene = try scene()
        let h = try StoreHarness(); PhoneMigrationFixtures.configure(h.core); await h.start()
        h.store.tasksLoaded = true; h.store.profileRead = true
        let task = PhoneNewTaskModel(store: h.store, workspace: try XCTUnwrap(h.store.workspace))
        task.environmentID = "sandbox"; task.text = "完善 iOS 仓库选择体验。"
        let picker = PhoneRepositoryPickerModel(scope: task.scope, selected: nil)
        let original = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene); window.overrideUserInterfaceStyle = .light
        let navigation = AppNavigation(tab: .home)
        window.rootViewController = UIHostingController(rootView:
            ShellCard(store: h.store, activity: TaskActivityCoordinator(), navigation: navigation, query: HomeTaskQuery())
                .sheet(isPresented: .constant(true)) {
                    NavigationStack {
                        PhoneNewTaskView(model: task)
                            .sheet(isPresented: .constant(true)) {
                                PhoneRepositoryPickerView(model: picker) { task.selectRepository($0) }.commaSheet([.large])
                            }
                    }.commaSheet([.medium, .large])
                }
        )
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; original?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(1800)); window.layoutIfNeeded()
        XCTAssertTrue(picker.ownersLoaded)
        let posture = window.bounds.width < ShellTabs.minimumColumnWidth * 2 ? "closed" : "open"
        save(window, "44-duo-" + posture + "-repository-organizations")
        picker.owner = try XCTUnwrap(picker.owners.first { $0.login == "AFK-surf" })
        try await Task.sleep(for: .milliseconds(700)); window.layoutIfNeeded()
        XCTAssertEqual(picker.repos.count, 6)
        save(window, "45-duo-" + posture + "-organization-repositories")
        picker.query = "comma" // The search starts on change, with no submit action.
        try await Task.sleep(for: .milliseconds(700)); window.layoutIfNeeded()
        XCTAssertEqual(picker.repos.map(\.name), ["comma-ios", "comma-desktop"])
        picker.selected = picker.repos.first
        save(window, "46-duo-" + posture + "-repository-search")
        XCTAssertTrue(task.repoID.isEmpty)
    }

    private func assertTaskSheet(_ window: UIWindow, requiresActionFrame: Bool = true) throws {
        // The standard iPhone test host does not expose SwiftUI accessibility nodes. Review its captured image.
        guard requiresActionFrame else { return }
        var seen = Set<ObjectIdentifier>(), nodes: [NSObject] = []
        func visit(_ node: NSObject) {
            guard seen.insert(ObjectIdentifier(node)).inserted else { return }; nodes.append(node)
            if let view = node as? UIView { view.subviews.forEach(visit) }
            if let children = node.automationElements ?? node.accessibilityElements { children.compactMap { $0 as? NSObject }.forEach(visit) }
            else {
                let count = node.accessibilityElementCount()
                if count > 0, count < 256 { for index in 0..<count { if let child = node.accessibilityElement(at: index) as? NSObject { visit(child) } } }
            }
        }
        visit(window)
        let environment = try XCTUnwrap(nodes.first { $0.accessibilityLabel == String(localized: "Run in") && $0.accessibilityFrame.width > 0 })
        let tabs = window.convert(environment.accessibilityFrame, from: nil)
        if let presented = window.rootViewController?.presentedViewController?.view {
            let sheet = presented.convert(presented.bounds, to: window)
            XCTAssertGreaterThanOrEqual(tabs.minY, sheet.minY + 20, "The header leaves room for the system grabber")
        }
        let create = try XCTUnwrap(nodes.filter { $0.accessibilityLabel == String(localized: "Create task") && $0.accessibilityFrame.width > 0 }.max { $0.accessibilityFrame.width < $1.accessibilityFrame.width })
        let action = window.convert(create.accessibilityFrame, from: nil)
        let close = try XCTUnwrap(nodes.first { ($0.accessibilityLabel == String(localized: "Close") || $0.accessibilityLabel == "Close") && $0.accessibilityFrame.width > 0 })
        let closeFrame = window.convert(close.accessibilityFrame, from: nil)
        XCTAssertEqual(closeFrame.midY, tabs.midY, accuracy: 1, "Close and the environment menu align vertically")
        XCTAssertLessThanOrEqual(closeFrame.maxX + 4, tabs.minX)
        XCTAssertLessThanOrEqual(action.width, 60, "Creation is a compact icon action in the header")
        XCTAssertLessThanOrEqual(action.height, 60)
        XCTAssertEqual(action.midY, tabs.midY, accuracy: 1, "Create, environment menu and Close share the header row")
        XCTAssertGreaterThanOrEqual(action.minX, tabs.maxX + 4, "The right action does not overlap the environment menu")
        XCTAssertLessThanOrEqual(action.maxX, window.bounds.maxX - GroupedSurface.margin)
        #if canImport(SwiftUI, _version: 8.0.85)
        if #available(iOS 27.1, *) {
            for region in window.reservedRegions(kind: .occlusion) {
                XCTAssertFalse(action.intersects(region.frame), "Create must stay clear of the camera and its interaction margins")
                XCTAssertFalse(closeFrame.intersects(region.frame), "Close must stay clear of hardware occlusions")
                XCTAssertFalse(tabs.intersects(region.frame), "The environment menu must stay clear of hardware occlusions")
            }
        }
        #endif
    }

    private func assertHeadings(_ window: UIWindow, title: String) throws {
        var seen = Set<ObjectIdentifier>(), nodes: [NSObject] = []
        func visit(_ node: NSObject) {
            guard seen.insert(ObjectIdentifier(node)).inserted else { return }; nodes.append(node)
            if let view = node as? UIView { view.subviews.forEach(visit) }
            if let children = node.automationElements ?? node.accessibilityElements { children.compactMap { $0 as? NSObject }.forEach(visit) }
            else {
                let count = node.accessibilityElementCount()
                if count > 0, count < 256 { for index in 0..<count { if let child = node.accessibilityElement(at: index) as? NSObject { visit(child) } } }
            }
        }
        visit(window)
        let headings = nodes.filter { $0.accessibilityTraits.contains(.header) && $0.accessibilityFrame.width > 0 }
        let left = try XCTUnwrap(headings.first { $0.accessibilityLabel == String(localized: "Settings") })
        let right = try XCTUnwrap(headings.filter { $0.accessibilityLabel == title }
            .min { window.convert($0.accessibilityFrame, from: nil).minY < window.convert($1.accessibilityFrame, from: nil).minY })
        let master = window.convert(left.accessibilityFrame, from: nil), detail = window.convert(right.accessibilityFrame, from: nil)
        XCTAssertLessThan(master.midX, window.bounds.midX)
        XCTAssertGreaterThan(detail.minX, window.bounds.width * 0.3)
    }

    private func assertDriveBreadcrumb(_ window: UIWindow, names: [String]) throws {
        let nodes = accessibilityNodes(window)
        let breadcrumb = try XCTUnwrap(nodes.first { $0.accessibilityLabel == String(localized: "Location") })
        let frame = window.convert(breadcrumb.accessibilityFrame, from: nil)
        XCTAssertGreaterThan(frame.height, 0)
        XCTAssertGreaterThan(frame.width, 0)
        XCTAssertTrue(window.bounds.contains(frame), "The breadcrumb viewport stays on screen")
        // SwiftUI exposes a horizontal ScrollView as a virtual accessibility group.
        // Its spoken value reports the full path even when older ancestors scroll out of view.
        XCTAssertEqual(breadcrumb.accessibilityValue, names.joined(separator: " / "))
    }

    private func accessibilityNodes(_ root: NSObject) -> [NSObject] {
        var nodes: [NSObject] = [], seen = Set<ObjectIdentifier>()
        func visit(_ node: NSObject) {
            guard seen.insert(ObjectIdentifier(node)).inserted else { return }
            nodes.append(node)
            if let view = node as? UIView { view.subviews.forEach(visit) }
            if let children = node.automationElements ?? node.accessibilityElements {
                children.compactMap { $0 as? NSObject }.forEach(visit)
            } else {
                let count = node.accessibilityElementCount()
                if count > 0, count < 256 {
                    for index in 0..<count { if let child = node.accessibilityElement(at: index) as? NSObject { visit(child) } }
                }
            }
        }
        visit(root)
        return nodes
    }

    private func capture<V: View>(_ name: String, view: V, inspect: ((UIWindow) throws -> Void)? = nil,
                                  ready: @escaping @MainActor () -> Bool) async throws {
        let scene = try scene()
        let original = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = UIHostingController(rootView: NavigationStack { view }.environment(AppNavigation(tab: .settings)))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; original?.makeKeyAndVisible() }
        let deadline = ContinuousClock.now + .seconds(5)
        while !ready(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(ready())
        try await Task.sleep(for: .milliseconds(name == "11-dynamic-ui" ? 2500 : 700)); window.layoutIfNeeded()
        save(window, name)
        try inspect?(window)
    }
    private func scene() throws -> UIWindowScene { try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.filter { $0.activationState == .foregroundActive }.max { $0.coordinateSpace.bounds.width < $1.coordinateSpace.bounds.width }) }
    private func save(_ window: UIWindow, _ name: String) {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ios-migration-evidence", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? image.pngData()?.write(to: directory.appendingPathComponent(name + ".png"))
    }
}
