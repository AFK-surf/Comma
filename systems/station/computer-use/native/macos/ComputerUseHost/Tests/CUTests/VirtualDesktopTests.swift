import CoreGraphics
import Foundation
import Testing
@testable import CUBackground
@testable import CUShared

struct VirtualDesktopTests {
    @Test
    func notchPanelFrameCentersAndFlushesToTopEdge() {
        let anchor = NotchAnchorMetrics(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            hasHardwareNotch: true,
            notchWidth: 188,
            notchHeight: 32
        )
        let expanded = NotchDimensions.target(for: .expanded, anchor: anchor)
        let frame = NotchDimensions.panelFrame(for: anchor, shadowPadding: 20)

        #expect(abs(frame.midX - anchor.screenFrame.midX) <= 1.0)
        #expect(abs(frame.maxY - anchor.screenFrame.maxY) <= 1.0)
        // Minimal card: far narrower than the old 624pt three-row island.
        #expect((460...510).contains(expanded.totalWidth))
        #expect(expanded.topContentInset == anchor.notchHeight)
    }

    @Test
    func compactNotchIsMinimalAndFlushWithNotchAndMenuBar() {
        let notched = NotchDimensions.target(for: .compact, anchor: Self.notchedAnchor)
        #expect(notched.topContentInset == 0)
        #expect(notched.bodyHeight == Self.notchedAnchor.notchHeight)
        #expect(notched.bodyWidth == Self.notchedAnchor.notchWidth + NotchCompactLayout.notchedWingWidth * 2)
        #expect(NotchCompactLayout.previewCornerRadius == notched.bottomCornerRadius - NotchCompactLayout.edgeInset)
        #expect(abs(NotchCompactLayout.previewSize.width / NotchCompactLayout.previewSize.height - 1440.0 / 900.0) < 0.01)

        let plainAnchor = NotchAnchorMetrics(
            screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            hasHardwareNotch: false,
            notchWidth: 200,
            notchHeight: 28
        )
        let plain = NotchDimensions.target(for: .compact, anchor: plainAnchor)
        #expect(plain.topContentInset == 0)
        #expect(plain.bodyHeight == NotchCompactLayout.minNonNotchedHeight)
        #expect(plain.bodyWidth == NotchCompactLayout.nonNotchedBodyWidth)

        // Compact panel shrinks tightly so transparent regions below never swallow clicks.
        let compactRect = NotchDimensions.islandScreenRect(for: .compact, anchor: plainAnchor)
        let expandedRect = NotchDimensions.islandScreenRect(for: .expanded, anchor: plainAnchor)
        #expect(compactRect.height < expandedRect.height)
        #expect(compactRect.maxY == plainAnchor.screenFrame.maxY)
        // A point 20pt below the compact bar must be outside its hit rect.
        #expect(!compactRect.contains(CGPoint(x: plainAnchor.screenFrame.midX, y: compactRect.minY - 20)))
    }

    @Test @MainActor
    func notchCompactHoverFeedbackAndClickExpandCollapseMatchCommaNotch() {
        let vm = NotchViewModel(
            anchor: Self.notchedAnchor,
            stream: VirtualDesktopStream(),
            taskTitle: "Check build"
        )
        vm.setPresentationState(.compact, animated: false)

        let compactRect = NotchDimensions.islandScreenRect(for: .compact, anchor: Self.notchedAnchor)
        let insideCompact = CGPoint(x: compactRect.midX, y: compactRect.midY)
        let topEdgePoint = CGPoint(x: compactRect.midX, y: Self.notchedAnchor.screenFrame.maxY)
        let belowCompact = CGPoint(x: compactRect.midX, y: compactRect.minY - 24)

        // Hovering compact notch (including slammed against screen top edge) triggers tactile hover feedback.
        vm.handleMouseMoved(at: topEdgePoint)
        #expect(vm.isCompactHovered)
        #expect(vm.presentationState == .compact)
        #expect(vm.containsInteractivePoint(topEdgePoint))
        #expect(!vm.containsInteractivePoint(belowCompact))

        // Leaving compact notch clears hover feedback.
        vm.handleMouseMoved(at: belowCompact)
        #expect(!vm.isCompactHovered)

        // Clicking compact notch expands immediately and clears compact hover.
        vm.handleMouseMoved(at: insideCompact)
        #expect(vm.isCompactHovered)
        vm.handleMouseDown(at: insideCompact)
        #expect(vm.presentationState == .expanded)
        #expect(!vm.isCompactHovered)

        // Clicking inside expanded body (below the top notch band) keeps the island open for controls.
        let expandedRect = NotchDimensions.islandScreenRect(for: .expanded, anchor: Self.notchedAnchor)
        let expandedBodyPoint = CGPoint(x: expandedRect.midX, y: expandedRect.minY + 24)
        vm.handleMouseDown(at: expandedBodyPoint)
        #expect(vm.presentationState == .expanded)

        // Clicking the top notch band while expanded collapses back to compact.
        vm.handleMouseDown(at: insideCompact)
        #expect(vm.presentationState == .compact)

        // Clicking outside while expanded also collapses back to compact.
        vm.handleMouseDown(at: insideCompact)
        #expect(vm.presentationState == .expanded)
        vm.handleMouseDown(at: CGPoint(x: expandedRect.midX, y: expandedRect.minY - 40))
        #expect(vm.presentationState == .compact)
    }

    @Test
    func expandedNotchPreviewIsConcentricWithIslandAndClearsTheNotch() {
        let anchor = NotchAnchorMetrics(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            hasHardwareNotch: true,
            notchWidth: 188,
            notchHeight: 32
        )
        let body = NotchDimensions.target(for: .expanded, anchor: anchor)
        let preview = NotchExpandedLayout.previewFrame(in: body)
        let details = NotchExpandedLayout.detailsFrame(in: body)

        // Equal inset on the left wall and the bottom edge, and corner radii that
        // share a center, so the preview corner nests inside the island corner.
        #expect(preview.minX == body.bodyHeight - preview.maxY)
        #expect(NotchExpandedLayout.previewCornerRadius == body.bottomCornerRadius - preview.minX)
        #expect(abs(preview.width / preview.height - 1440.0 / 900.0) < 0.01)
        // Content starts below the hardware notch with breathing room.
        #expect(preview.minY > anchor.notchHeight)
        #expect(details.minX > preview.maxX)
        #expect(details.maxX < body.bodyWidth)
        // Title + status hang from the preview's top, the action row sits on
        // its bottom edge: the column spans exactly the preview's height.
        #expect(details.minY == preview.minY)
        #expect(details.maxY == preview.maxY)
        #expect(details.height >= 18 + 7 + 18 + NotchExpandedLayout.actionRowHeight + 8)
        #expect(details.width >= 260)
    }

    @Test
    func notchEntranceGrowsFromNotchWithoutOvershootAndSettlesExpanded() {
        let anchor = NotchAnchorMetrics(
            screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            hasHardwareNotch: false,
            notchWidth: 200,
            notchHeight: 24
        )
        let hidden = NotchDimensions.target(for: .hidden, anchor: anchor)
        let expanded = NotchDimensions.target(for: .expanded, anchor: anchor)

        let s0 = NotchEntranceSample.sample(elapsed: 0.0, anchor: anchor)
        #expect(s0.width == hidden.bodyWidth)
        #expect(s0.height == hidden.bodyHeight)
        #expect(s0.previewOpacity == 0)
        #expect(s0.detailsOpacity == 0)
        #expect(!s0.isSettled)

        // Critically damped: every frame grows monotonically and never passes the target.
        var previous = s0
        var t = 1.0 / 60.0
        while t < NotchEntranceSample.totalDuration {
            let s = NotchEntranceSample.sample(elapsed: t, anchor: anchor)
            #expect(s.width >= previous.width)
            #expect(s.height >= previous.height)
            #expect(s.width <= expanded.bodyWidth)
            #expect(s.height <= expanded.bodyHeight)
            #expect(s.bottomCornerRadius <= expanded.bottomCornerRadius)
            // Preview and details ride opposite walls; once text is visible the
            // body is close enough to full width that they never overlap.
            if s.detailsOpacity > 0 {
                #expect(expanded.bodyWidth - s.width <= NotchExpandedLayout.previewToDetailsGap)
            }
            previous = s
            t += 1.0 / 60.0
        }

        let sMid = NotchEntranceSample.sample(elapsed: 0.30, anchor: anchor)
        #expect(sMid.width > hidden.bodyWidth)
        #expect(sMid.height > hidden.bodyHeight)
        #expect(sMid.previewOpacity > 0)

        let sEnd = NotchEntranceSample.sample(elapsed: NotchEntranceSample.totalDuration, anchor: anchor)
        #expect(sEnd.isSettled)
        #expect(sEnd.width == expanded.bodyWidth)
        #expect(sEnd.height == expanded.bodyHeight)
        #expect(sEnd.previewOpacity == 1.0)
        #expect(sEnd.detailsOpacity == 1.0)
        #expect(sEnd.detailsOffsetY == 0)
    }

    @Test
    func virtualDesktopLayoutCentersAndClampsWindowsWithinBounds() {
        let displayBounds = CGRect(x: 1440, y: 900, width: 1440, height: 900)

        let normal = VirtualDesktopLayout.targetFrame(
            for: CGSize(width: 900, height: 620),
            in: displayBounds,
            windowIndex: 0
        )
        #expect(normal.width == 900)
        #expect(normal.height == 620)
        #expect(displayBounds.contains(normal))
        #expect(normal.minY >= displayBounds.minY + VirtualDesktopLayout.menuBarReserve)

        let oversized = VirtualDesktopLayout.targetFrame(
            for: CGSize(width: 2400, height: 1600),
            in: displayBounds,
            windowIndex: 0
        )
        #expect(oversized.width <= displayBounds.width - VirtualDesktopLayout.outerMargin * 2)
        #expect(oversized.height <= displayBounds.height - VirtualDesktopLayout.menuBarReserve - VirtualDesktopLayout.outerMargin * 2)
        #expect(displayBounds.contains(oversized))
    }

    @Test
    func virtualDesktopRecoverySnapshotRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cu-vd-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("snapshot.json")

        let record = MigratedWindowRecord(
            pid: 4242,
            bundleID: "com.apple.TextEdit",
            appName: "TextEdit",
            windowID: 99,
            windowTitle: "Draft.txt",
            originX: 120,
            originY: 80,
            width: 840,
            height: 600
        )
        let snapshot = VirtualDesktopSnapshot(virtualDisplayID: 9, windows: [record])
        try VirtualDesktopRecovery.writeSnapshot(snapshot, to: fileURL)

        #expect(VirtualDesktopRecovery.hasSnapshot(at: fileURL))
        let loaded = try VirtualDesktopRecovery.loadSnapshot(from: fileURL)
        #expect(loaded.virtualDisplayID == 9)
        #expect(loaded.windows == [record])

        VirtualDesktopRecovery.discardSnapshot(at: fileURL)
        #expect(!VirtualDesktopRecovery.hasSnapshot(at: fileURL))
    }

    @Test
    func streamCapturesThumbnailSizeUntilTheViewerAsksForFullPixels() {
        let points = CGSize(width: 1440, height: 900)
        let pixels = CGSize(width: 2880, height: 1800)
        #expect(VirtualDesktopStream.captureSize(pointSize: points, pixelSize: pixels, quality: .preview) == points)
        #expect(VirtualDesktopStream.captureSize(pointSize: points, pixelSize: pixels, quality: .full) == pixels)
    }

    @Test @MainActor
    func islandShowsOneLiveStatusLineFromRealSessionData() {
        let vm = NotchViewModel(anchor: Self.notchedAnchor, stream: VirtualDesktopStream())
        // Nothing passed yet: one honest default per line, no placeholder steps.
        #expect(vm.headline == NotchViewModel.defaultTitle)
        #expect(vm.statusLine == NotchViewModel.idleStatus)

        vm.recordStatus("Clicking “Run Preview” in Comma Studio", appName: "Comma Studio")
        #expect(vm.headline == "Comma Studio")
        #expect(vm.compactName == "Comma Studio")
        #expect(vm.statusLine == "Clicking “Run Preview” in Comma Studio")

        // A newer action or thinking replaces the line; multi-line thinking
        // collapses onto one line; blank input keeps the current line.
        vm.recordStatus("  Checking the build\n   output ")
        #expect(vm.statusLine == "Checking the build output")
        vm.recordStatus("   ")
        #expect(vm.statusLine == "Checking the build output")

        let titled = NotchViewModel(
            anchor: Self.notchedAnchor,
            stream: VirtualDesktopStream(),
            taskTitle: " Write an NSPanel component ",
            activeAppName: "Comma Studio"
        )
        #expect(titled.headline == "Write an NSPanel component")
        #expect(titled.compactName == "Comma Studio")
    }

    @Test @MainActor
    func stopCollapsesTheIslandOnceThenEndsTheSession() {
        var scheduled: [(delay: TimeInterval, cancelled: Bool, action: @MainActor () -> Void)] = []
        let vm = NotchViewModel(
            anchor: Self.notchedAnchor,
            stream: VirtualDesktopStream(),
            taskTitle: "Run build",
            scheduleAfter: { delay, action in
                let index = scheduled.count
                scheduled.append((delay: delay, cancelled: false, action: action))
                return { scheduled[index].cancelled = true }
            }
        )
        vm.setPresentationState(.expanded, animated: false)

        var stops = 0
        vm.onStop = { stops += 1 }

        vm.requestStop()
        vm.requestStop()
        vm.setPresentationState(.expanded, animated: false)

        #expect(vm.isStopping)
        #expect(vm.presentationState == .hidden)
        #expect(stops == 0)
        #expect(scheduled.count == 1)
        #expect(scheduled[0].delay == NotchViewModel.exitDuration)

        if !scheduled[0].cancelled {
            scheduled[0].action()
        }
        #expect(stops == 1)
    }

    @Test @MainActor
    func userStopEndsTheActiveSessionAndTellsTheAgentWhy() async throws {
        let registry = SessionRegistry()
        var made: [FakeRuntime] = []
        registry.registerBackground(factory: {
            let runtime = FakeRuntime()
            made.append(runtime)
            return runtime
        })
        _ = await registry.handle(session: SessionControl(op: .start))
        let runtime = try #require(made.first)

        // Only the active session's island can stop it.
        #expect(!registry.stopByUser(FakeRuntime()))
        #expect(registry.active === runtime)

        #expect(registry.stopByUser(runtime))
        #expect(runtime.deactivations == 1)
        #expect(registry.active == nil)
        #expect(registry.activeMode == nil)
        #expect(!registry.stopByUser(runtime))
        #expect(runtime.deactivations == 1)

        let next = await registry.handle(action: ["click", "--snapshot-id", "s1", "--element-index", "3"])
        #expect(!next.ok)
        #expect(next.error == SessionRegistry.stoppedByUserMessage)
        #expect(runtime.dispatches == 0)

        // A new start clears the reason.
        _ = await registry.handle(session: SessionControl(op: .start))
        #expect(!registry.stoppedByUser)
        #expect(made.count == 2)
    }

    @Test @MainActor
    func singleActiveSessionIsolatesConcurrentCallersBySessionID() async throws {
        let registry = SessionRegistry()
        var made: [FakeRuntime] = []
        registry.registerBackground(factory: {
            let runtime = FakeRuntime()
            made.append(runtime)
            return runtime
        })

        let startA = await registry.handle(session: SessionControl(
            op: .start,
            mode: .background,
            background: BackgroundStartArgs(apps: ["Keynote"], title: "Edit Keynote deck"),
            sessionId: "agent-a"
        ))
        #expect(startA.ok)
        let runtimeA = try #require(made.first)
        #expect(registry.activeSessionID == "agent-a")
        #expect(registry.activeTitle == "Edit Keynote deck")

        // Same caller starting twice gets the already-active error.
        let doubleStartA = await registry.handle(session: SessionControl(op: .start, sessionId: "agent-a"))
        #expect(!doubleStartA.ok)
        #expect(doubleStartA.error?.contains("already active") == true)

        // Another session starting gets a clear busy error naming the active task.
        let startB = await registry.handle(session: SessionControl(
            op: .start,
            background: BackgroundStartArgs(title: "Check email"),
            sessionId: "agent-b"
        ))
        #expect(!startB.ok)
        #expect(startB.error?.contains("busy") == true)
        #expect(startB.error?.contains("Edit Keynote deck") == true)
        #expect(registry.active === runtimeA)

        // Foreign callers (another session ID or nil) cannot dispatch actions, stop, or overwrite thinking.
        let foreignClick = await registry.handle(
            action: ["click", "--snapshot-id", "s1", "--element-index", "1"],
            sessionId: "agent-b"
        )
        #expect(!foreignClick.ok)
        #expect(foreignClick.error?.contains("Edit Keynote deck") == true)
        #expect(runtimeA.dispatches == 0)

        let untaggedClick = await registry.handle(
            action: ["click", "--snapshot-id", "s1", "--element-index", "1"],
            sessionId: nil
        )
        #expect(!untaggedClick.ok)
        #expect(runtimeA.dispatches == 0)

        registry.recordThinking("Foreign thinking must be ignored", sessionId: "agent-b")
        registry.recordThinking("Untagged thinking must be ignored", sessionId: nil)
        #expect(runtimeA.recordedThinking.isEmpty)

        registry.recordThinking("Exporting slides", sessionId: "agent-a")
        #expect(runtimeA.recordedThinking == ["Exporting slides"])

        let foreignStop = await registry.handle(session: SessionControl(op: .stop, sessionId: "agent-b"))
        #expect(!foreignStop.ok)
        #expect(foreignStop.error?.contains("Edit Keynote deck") == true)
        #expect(runtimeA.deactivations == 0)
        #expect(registry.active === runtimeA)

        // Status JSON reports busy, title, and ownership accurately for each caller.
        let statusAData = try #require(registry.sessionStatusJSON(for: "agent-a").data(using: .utf8))
        let statusA = try #require(JSONSerialization.jsonObject(with: statusAData) as? [String: Any])
        #expect(statusA["busy"] as? Bool == true)
        #expect(statusA["mode"] as? String == "background")
        #expect(statusA["title"] as? String == "Edit Keynote deck")
        #expect(statusA["owned_by_caller"] as? Bool == true)

        let statusBData = try #require(registry.sessionStatusJSON(for: "agent-b").data(using: .utf8))
        let statusB = try #require(JSONSerialization.jsonObject(with: statusBData) as? [String: Any])
        #expect(statusB["busy"] as? Bool == true)
        #expect(statusB["owned_by_caller"] as? Bool == false)

        // The owner can act and stop; afterwards another session can start cleanly.
        let ownClick = await registry.handle(
            action: ["click", "--snapshot-id", "s1", "--element-index", "1"],
            sessionId: "agent-a"
        )
        #expect(ownClick.ok)
        #expect(runtimeA.dispatches == 1)

        let stopA = await registry.handle(session: SessionControl(op: .stop, sessionId: "agent-a"))
        #expect(stopA.ok)
        #expect(runtimeA.deactivations == 1)
        #expect(registry.active == nil)
        #expect(registry.activeSessionID == nil)

        let startBAfter = await registry.handle(session: SessionControl(
            op: .start,
            background: BackgroundStartArgs(title: "Check email"),
            sessionId: "agent-b"
        ))
        #expect(startBAfter.ok)
        #expect(registry.activeSessionID == "agent-b")
        #expect(registry.activeTitle == "Check email")
        #expect(made.count == 2)
    }

    @Test @MainActor
    func userStopReasonTargetsOnlyTheStoppedSession() async throws {
        let registry = SessionRegistry()
        var made: [FakeRuntime] = []
        registry.registerBackground(factory: {
            let runtime = FakeRuntime()
            made.append(runtime)
            return runtime
        })

        _ = await registry.handle(session: SessionControl(op: .start, sessionId: "agent-a"))
        let runtimeA = try #require(made.first)
        #expect(registry.stopByUser(runtimeA))

        // Session A is told the user stopped its session.
        let nextA = await registry.handle(action: ["click", "--snapshot-id", "s1", "--element-index", "1"], sessionId: "agent-a")
        #expect(!nextA.ok)
        #expect(nextA.error == SessionRegistry.stoppedByUserMessage)

        // Session B (never started) gets the regular "no active session" error and can start cleanly.
        let nextB = await registry.handle(action: ["click", "--snapshot-id", "s1", "--element-index", "1"], sessionId: "agent-b")
        #expect(!nextB.ok)
        #expect(nextB.error == "no active session; run `start` first")

        let startB = await registry.handle(session: SessionControl(op: .start, sessionId: "agent-b"))
        #expect(startB.ok)
        #expect(!registry.stoppedByUser)
        #expect(registry.activeSessionID == "agent-b")
    }

    @Test @MainActor
    func computerUseNotchPreferenceControlsVirtualDesktopAndDefaultsOn() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cu-prefs-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("preferences.json")

        // Missing file defaults to enabled.
        #expect(ComputerUsePreferences.showInNotch(from: fileURL))
        #expect(BackgroundModeRuntime.shouldUseVirtualDesktop(explicit: nil, preferenceURL: fileURL))

        // Writing false disables virtual desktop + notch unless caller explicitly overrides.
        try ComputerUsePreferences.write(showInNotch: false, to: fileURL)
        #expect(!ComputerUsePreferences.showInNotch(from: fileURL))
        #expect(!BackgroundModeRuntime.shouldUseVirtualDesktop(explicit: nil, preferenceURL: fileURL))
        #expect(BackgroundModeRuntime.shouldUseVirtualDesktop(explicit: true, preferenceURL: fileURL))

        // Writing true re-enables it; explicit false still wins.
        try ComputerUsePreferences.write(showInNotch: true, to: fileURL)
        #expect(ComputerUsePreferences.showInNotch(from: fileURL))
        #expect(BackgroundModeRuntime.shouldUseVirtualDesktop(explicit: nil, preferenceURL: fileURL))
        #expect(!BackgroundModeRuntime.shouldUseVirtualDesktop(explicit: false, preferenceURL: fileURL))

        // Malformed file safely falls back to enabled.
        try Data("not-json".utf8).write(to: fileURL)
        #expect(ComputerUsePreferences.showInNotch(from: fileURL))
    }

    @Test
    func statusLineNamesTheRealTargetAndNeverLeaksPasswords() {
        let target = NotchActivityText.Target(appName: "Comma Studio", elements: [
            Self.element(role: "AXWindow", title: "PreviewDemo.swift"),
            Self.element(role: "AXButton", title: "Run Preview"),
            Self.element(role: "AXButton", title: ""),
            Self.element(role: "AXTextField", subrole: "AXSecureTextField", title: "Password"),
            Self.element(role: "AXTextField", title: "Search"),
        ])
        func line(_ command: ComputerUseCLICommand) -> String? {
            NotchActivityText.describe(command, target: target)
        }
        #expect(line(.click(snapshotID: "s", elementIndex: 1, x: nil, y: nil)) == "Clicking “Run Preview” in Comma Studio")
        #expect(line(.click(snapshotID: "s", elementIndex: 2, x: nil, y: nil)) == "Clicking the button in Comma Studio")
        #expect(line(.click(snapshotID: "s", elementIndex: nil, x: 10, y: 20)) == "Clicking in Comma Studio")
        #expect(line(.typeText(snapshotID: "s", text: "hunter2", elementIndex: 3)) == "Entering a password in Comma Studio")
        #expect(line(.setValue(snapshotID: "s", elementIndex: 3, value: "hunter2")) == "Entering a password in Comma Studio")
        // Without a known target field the typed text is not shown.
        #expect(line(.typeText(snapshotID: "s", text: "hunter2", elementIndex: nil)) == "Typing in Comma Studio")
        #expect(line(.typeText(snapshotID: "s", text: "NotchPanel component and more", elementIndex: 4))
            == "Typing “NotchPanel component an…” in Comma Studio")
        #expect(line(.scroll(snapshotID: "s", elementIndex: 0, direction: "down", pages: 1)) == "Scrolling down in Comma Studio")
        #expect(line(.permissions(.status)) == nil)
        #expect(NotchActivityText.describe(.getAppState(app: "Safari", windowTitle: nil), target: nil) == "Looking at Safari")
    }

    @Test
    func displayStyleDetectsDynamicIslandVsLegacyNotchAndExternalDisplay() {
        // External monitor never resolves to a notch or Dynamic Island even with non-zero safe area.
        #expect(
            NotchAnchorMetrics.detectDisplayStyle(
                isBuiltIn: false,
                safeAreaTop: 32,
                screenWidth: 2560,
                rawCutoutWidth: 120,
                nativePixelSize: CGSize(width: 5120, height: 2880),
                hardwareModel: "Mac17,10"
            ) == .none
        )

        // Non-notched built-in display resolves to .none.
        #expect(
            NotchAnchorMetrics.detectDisplayStyle(
                isBuiltIn: true,
                safeAreaTop: 0,
                screenWidth: 1440,
                rawCutoutWidth: nil,
                nativePixelSize: CGSize(width: 2560, height: 1600),
                hardwareModel: "MacBookAir10,1"
            ) == .none
        )

        // Legacy 14" MacBook Pro at default Retina and at "Larger Text" scaling (1024pt logical width):
        // cutout ratio remains ~12.4% (>= 9.5%), so scaling never falsely triggers Dynamic Island.
        #expect(
            NotchAnchorMetrics.detectDisplayStyle(
                isBuiltIn: true,
                safeAreaTop: 32,
                screenWidth: 1512,
                rawCutoutWidth: 188,
                nativePixelSize: CGSize(width: 3024, height: 1964),
                hardwareModel: "Mac15,3"
            ) == .legacyNotch
        )
        #expect(
            NotchAnchorMetrics.detectDisplayStyle(
                isBuiltIn: true,
                safeAreaTop: 32,
                screenWidth: 1024,
                rawCutoutWidth: 127,
                nativePixelSize: CGSize(width: 3024, height: 1964),
                hardwareModel: "Mac15,3"
            ) == .legacyNotch
        )
        #expect(
            NotchAnchorMetrics.detectDisplayStyle(
                isBuiltIn: true,
                safeAreaTop: 37,
                screenWidth: 1728,
                rawCutoutWidth: 188,
                nativePixelSize: CGSize(width: 3456, height: 2234),
                hardwareModel: "Mac15,7"
            ) == .legacyNotch
        )

        // 2026 PROLED MacBook Pro models via hw.model, native resolution, or narrow cutout ratio.
        #expect(
            NotchAnchorMetrics.detectDisplayStyle(
                isBuiltIn: true,
                safeAreaTop: 38,
                screenWidth: 1512,
                rawCutoutWidth: 122,
                nativePixelSize: CGSize(width: 3024, height: 1986),
                hardwareModel: "Mac17,10"
            ) == .dynamicIsland
        )
        #expect(
            NotchAnchorMetrics.detectDisplayStyle(
                isBuiltIn: true,
                safeAreaTop: 38,
                screenWidth: 1736,
                rawCutoutWidth: 124,
                nativePixelSize: CGSize(width: 3472, height: 2266),
                hardwareModel: "Mac17,12"
            ) == .dynamicIsland
        )
        // Future Dynamic Island MacBook without a hardcoded model ID: detected by native panel or ratio.
        #expect(
            NotchAnchorMetrics.detectDisplayStyle(
                isBuiltIn: true,
                safeAreaTop: 38,
                screenWidth: 1512,
                rawCutoutWidth: 120,
                nativePixelSize: CGSize(width: 3024, height: 1986),
                hardwareModel: "Mac18,10"
            ) == .dynamicIsland
        )
        #expect(
            NotchAnchorMetrics.detectDisplayStyle(
                isBuiltIn: true,
                safeAreaTop: 38,
                screenWidth: 1600,
                rawCutoutWidth: 120,
                nativePixelSize: CGSize(width: 3200, height: 2100),
                hardwareModel: "Mac19,4"
            ) == .dynamicIsland
        )
    }

    @Test @MainActor
    func dynamicIslandFloatingCapsuleGeometryEntranceAndInteraction() {
        let anchor = Self.dynamicIslandAnchor
        #expect(anchor.displayStyle == .dynamicIsland)
        #expect(anchor.isFloatingCapsule)
        #expect(anchor.hasHardwareNotch)
        #expect(anchor.topMargin == NotchDynamicIslandLayout.topMargin)

        // Compact floating pill: zero ears, full semicircular radius, floats topMargin below top edge,
        // and stays flush with the menu bar safe area bottom.
        let compact = NotchDimensions.target(for: .compact, anchor: anchor)
        #expect(compact.earRadius == 0)
        #expect(compact.bottomCornerRadius == compact.bodyHeight / 2)
        #expect(compact.bodyHeight == anchor.notchHeight - anchor.topMargin)
        #expect(compact.bodyWidth == anchor.notchWidth + NotchDynamicIslandLayout.wingWidth * 2)

        let compactRect = NotchDimensions.islandScreenRect(for: .compact, anchor: anchor)
        #expect(compactRect.maxY == anchor.screenFrame.maxY - anchor.topMargin)
        #expect(compactRect.minY == anchor.screenFrame.maxY - anchor.notchHeight)

        // Fitts's law: slamming pointer against top bezel hits compactHitRect.
        let hitRect = NotchDimensions.compactHitRect(for: anchor)
        #expect(hitRect.maxY >= anchor.screenFrame.maxY)
        #expect(!hitRect.contains(CGPoint(x: anchor.screenFrame.midX, y: compactRect.minY - 20)))

        // Expanded floating card (staggered Plan B): zero ears, 122pt tall, 30pt continuous
        // corners, triple-concentric 150×94 left preview (14pt inset, clears centered camera cutout),
        // details column starting cleanly below camera band (36pt).
        let expanded = NotchDimensions.target(for: .expanded, anchor: anchor)
        #expect(expanded.earRadius == 0)
        #expect(expanded.bottomCornerRadius == NotchDynamicIslandLayout.expandedCornerRadius)
        #expect(expanded.bodyHeight == 122)
        #expect(expanded.topContentInset == anchor.notchHeight - anchor.topMargin)
        let preview = NotchDynamicIslandLayout.expandedPreviewFrame(in: expanded)
        let details = NotchDynamicIslandLayout.expandedDetailsFrame(in: expanded)
        #expect(preview.minX == NotchDynamicIslandLayout.expandedEdgeInset)
        #expect(preview.minY == NotchDynamicIslandLayout.expandedEdgeInset)
        #expect(expanded.bodyHeight - preview.maxY == NotchDynamicIslandLayout.expandedEdgeInset)
        #expect(NotchDynamicIslandLayout.expandedPreviewCornerRadius == expanded.bottomCornerRadius - preview.minX)
        let cutoutMinX = (expanded.bodyWidth - anchor.notchWidth) / 2
        #expect(preview.maxX < cutoutMinX)
        #expect(details.minY >= expanded.topContentInset + 4)
        #expect(details.height >= NotchDynamicIslandLayout.expandedMinDetailsHeight)

        let expandedRect = NotchDimensions.islandScreenRect(for: .expanded, anchor: anchor)
        #expect(expandedRect.maxY == anchor.screenFrame.maxY - anchor.topMargin)

        // Entrance animation grows monotonically from floating camera pill with zero ears.
        let hidden = NotchDimensions.target(for: .hidden, anchor: anchor)
        #expect(hidden.earRadius == 0)
        #expect(hidden.bottomCornerRadius == hidden.bodyHeight / 2)
        var prev = NotchEntranceSample.sample(elapsed: 0, anchor: anchor)
        #expect(prev.earRadius == 0)
        var t = 1.0 / 60.0
        while t < NotchEntranceSample.totalDuration {
            let s = NotchEntranceSample.sample(elapsed: t, anchor: anchor)
            #expect(s.earRadius == 0)
            #expect(s.width >= prev.width)
            #expect(s.height >= prev.height)
            #expect(s.bottomCornerRadius <= expanded.bottomCornerRadius)
            // Floating capsule content stays hidden until shell has expanded enough to avoid clipping.
            if s.previewOpacity > 0 {
                #expect(s.width >= 410)
            }
            if s.detailsOpacity > 0 {
                #expect(s.width >= 425)
            }
            prev = s
            t += 1.0 / 60.0
        }

        // Compact hover + click-expand + top-band-collapse interaction on floating capsule.
        let vm = NotchViewModel(anchor: anchor, stream: VirtualDesktopStream(), taskTitle: "Review PR")
        vm.setPresentationState(.compact, animated: false)
        let topEdgePoint = CGPoint(x: compactRect.midX, y: anchor.screenFrame.maxY)
        let insidePill = CGPoint(x: compactRect.midX, y: compactRect.midY)
        vm.handleMouseMoved(at: topEdgePoint)
        #expect(vm.isCompactHovered)
        vm.handleMouseDown(at: insidePill)
        #expect(vm.presentationState == .expanded)
        #expect(!vm.isCompactHovered)

        // Clicking the top-right corner of the staggered preview tile (where its hover
        // expand icon sits, overlapping the compact left wing) must NOT collapse the island.
        let previewScreen = NotchDimensions.expandedPreviewScreenRect(for: anchor)
        let previewTopRight = CGPoint(x: previewScreen.maxX - 10, y: previewScreen.maxY - 10)
        #expect(NotchDimensions.compactHitRect(for: anchor).contains(previewTopRight))
        vm.handleMouseDown(at: previewTopRight)
        #expect(vm.presentationState == .expanded)

        // Clicking the center camera cutout band still collapses back to compact.
        vm.handleMouseDown(at: insidePill)
        #expect(vm.presentationState == .compact)

        // Automatic entrance must not steal key focus; explicit click-expand may focus glass.
        vm.playEntranceAnimation()
        #expect(!vm.lastTransitionWasUserInitiated)
        vm.setPresentationState(.compact, animated: false)
        vm.handleMouseDown(at: insidePill)
        #expect(vm.presentationState == .expanded)
        #expect(vm.lastTransitionWasUserInitiated)
    }

    @Test @MainActor
    func concurrentStartDuringSuspendedActivationRejectsSecondCallerAndHandlesMidStartStop() async throws {
        let registry = SessionRegistry()
        var created: [SuspendingRuntime] = []
        registry.registerBackground(factory: {
            let rt = SuspendingRuntime()
            created.append(rt)
            return rt
        })

        let firstTask = Task<Bool, Never> { @MainActor in
            let response = await registry.handle(session: SessionControl(
                op: .start,
                background: BackgroundStartArgs(title: "Deploy release"),
                sessionId: "agent-a"
            ))
            return response.ok
        }
        await Task.yield()
        let firstRuntime = try #require(created.first)
        #expect(firstRuntime.isSuspended)

        // Concurrent caller B is rejected immediately without creating a second runtime.
        let secondStart = await registry.handle(session: SessionControl(
            op: .start,
            background: BackgroundStartArgs(title: "Other task"),
            sessionId: "agent-b"
        ))
        #expect(!secondStart.ok)
        #expect(secondStart.error?.contains("busy") == true)
        #expect(created.count == 1)

        // Status hides the title from foreign callers while reporting busy.
        let statusBData = try #require(registry.sessionStatusJSON(for: "agent-b").data(using: .utf8))
        let statusB = try #require(JSONSerialization.jsonObject(with: statusBData) as? [String: Any])
        #expect(statusB["busy"] as? Bool == true)
        #expect(statusB["owned_by_caller"] as? Bool == false)
        #expect(statusB["title"] == nil)

        // Owner calling `stop` during activation cancels it cleanly once `activate` returns.
        let midStop = await registry.handle(session: SessionControl(op: .stop, sessionId: "agent-a"))
        #expect(midStop.ok)
        firstRuntime.resumeActivation()

        let firstOk = await firstTask.value
        #expect(!firstOk)
        #expect(firstRuntime.deactivations == 1)
        #expect(registry.active == nil)
        #expect(registry.activeSessionID == nil)

        // Subsequent start succeeds cleanly without deadlock.
        let thirdTask = Task<Bool, Never> { @MainActor in
            let response = await registry.handle(session: SessionControl(op: .start, sessionId: "agent-b"))
            return response.ok
        }
        await Task.yield()
        let secondRuntime = try #require(created.last)
        secondRuntime.resumeActivation()
        let thirdOk = await thirdTask.value
        #expect(thirdOk)
        #expect(registry.activeSessionID == "agent-b")
    }

    @Test @MainActor
    func idleSessionLeaseExpiresAutomaticallyForFailOpenLiveness() async throws {
        var currentTime = Date(timeIntervalSince1970: 1_000_000)
        let registry = SessionRegistry(now: { currentTime }, idleTimeout: 600)
        var created: [FakeRuntime] = []
        registry.registerBackground(factory: {
            let rt = FakeRuntime()
            created.append(rt)
            return rt
        })

        let startA = await registry.handle(session: SessionControl(op: .start, sessionId: "agent-a"))
        #expect(startA.ok)
        let rtA = try #require(created.first)

        // Still within idle lease -> caller B is rejected.
        currentTime = currentTime.addingTimeInterval(300)
        let busyB = await registry.handle(session: SessionControl(op: .start, sessionId: "agent-b"))
        #expect(!busyB.ok)
        #expect(rtA.deactivations == 0)

        // Past idle lease -> stale session auto-deactivates and caller B acquires cleanly.
        currentTime = currentTime.addingTimeInterval(301)
        let startB = await registry.handle(session: SessionControl(op: .start, sessionId: "agent-b"))
        #expect(startB.ok)
        #expect(rtA.deactivations == 1)
        #expect(registry.activeSessionID == "agent-b")
    }

    @Test
    func cursorBarrierClampsPointerOnlyInsideVirtualDisplay() {
        let main = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let virtual = CGRect(x: 1512, y: 0, width: 1440, height: 900)

        #expect(CursorBarrierRunner.clampedPoint(CGPoint(x: 700, y: 500), mainBounds: main, virtualBounds: virtual) == nil)
        let clamped = CursorBarrierRunner.clampedPoint(CGPoint(x: 1600, y: 400), mainBounds: main, virtualBounds: virtual)
        #expect(clamped == CGPoint(x: 1510, y: 400))
    }

    private static let notchedAnchor = NotchAnchorMetrics(
        screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        hasHardwareNotch: true,
        notchWidth: 188,
        notchHeight: 32
    )

    private static let dynamicIslandAnchor = NotchAnchorMetrics(
        screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 993),
        hasHardwareNotch: true,
        notchWidth: 122,
        notchHeight: 38,
        displayStyle: .dynamicIsland
    )

    private static func element(role: String, subrole: String = "", title: String) -> CachedNodeSignature {
        CachedNodeSignature(depth: 1, role: role, subrole: subrole, title: title, identifier: "", childIndexAmongSameRole: 0)
    }
}

@MainActor
private final class FakeRuntime: ModeRuntime {
    var deactivations = 0
    var dispatches = 0
    var recordedThinking: [String] = []

    func activate(payload _: SessionControl) async throws {}

    func deactivate() {
        deactivations += 1
    }

    func dispatch(args _: [String]) async -> DaemonResponse {
        dispatches += 1
        return .success("ok")
    }

    func recordThinking(_ text: String) {
        recordedThinking.append(text)
    }
}

@MainActor
private final class SuspendingRuntime: ModeRuntime {
    var deactivations = 0
    private var continuation: CheckedContinuation<Void, Never>?
    var isSuspended: Bool { continuation != nil }

    func activate(payload _: SessionControl) async throws {
        await withCheckedContinuation { cont in
            self.continuation = cont
        }
    }

    func resumeActivation() {
        let cont = continuation
        continuation = nil
        cont?.resume()
    }

    func deactivate() {
        deactivations += 1
    }

    func dispatch(args _: [String]) async -> DaemonResponse {
        .success("ok")
    }
}
