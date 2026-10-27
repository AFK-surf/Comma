import AppKit
import Foundation
import MCP
import XCTest

@testable import MacApps

/// The server's call contract: permissions are reported, never prompted for;
/// a slow app cannot hold a call past its deadline; failures carry stable codes.
final class MacAppsServiceTests: XCTestCase {
    func testMissingPermissionIsReportedWithoutRunningTheTool() async {
        let ran = Counter()
        let tool = ToolDefinition(
            app: .calendar, name: "probe", title: "Probe", description: "", inputSchema: Schema.object(),
            readOnly: true, requirements: [.calendars]
        ) { _, _ in
            ran.increment()
            return [:]
        }
        let permissions = StubPermissions([.calendars: .notDetermined])
        let result = await service([tool], permissions).call("calendar_probe", [:])

        XCTAssertEqual(errorCode(result), "permission_required")
        XCTAssertEqual(errorField(result, "requirement"), "calendars")
        XCTAssertEqual(ran.value, 0)
        XCTAssertEqual(permissions.requested, [])
    }

    func testClosedAutomationTargetIsLeftToTheScriptRunner() async {
        let tool = ToolDefinition(
            app: .notes, name: "probe", title: "Probe", description: "", inputSchema: Schema.object(),
            readOnly: true, requirements: [.automation(BundleID.notes)]
        ) { _, _ in ["ran": true] }
        let result = await service([tool], StubPermissions([.automation(BundleID.notes): .unknown]))
            .call("notes_probe", [:])
        XCTAssertNotEqual(result.isError, true)
    }

    func testBlockedToolTimesOutOnSchedule() async {
        let tool = ToolDefinition(
            app: .system, name: "stuck", title: "Stuck", description: "", inputSchema: Schema.object(),
            readOnly: true
        ) { _, _ in
            usleep(2_000_000)  // An app that does not answer blocks its thread.
            return [:]
        }
        let started = Date()
        let result = await service([tool], StubPermissions([:]), timeout: .milliseconds(200)).call("system_stuck", [:])
        XCTAssertEqual(errorCode(result), "timeout")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    }

    /// A script that waited for the main thread past its call's deadline is not
    /// run: the caller was told the call timed out, so it must not send later.
    func testAScriptWhoseCallTimedOutIsNotRun() async {
        let runner = AppleScriptRunner()
        let code = await Task { () -> String in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await runner.execute("on probe()\n  return 1\nend probe", "probe", [])
                return "ran"
            } catch let failure as ToolFailure {
                return failure.code
            } catch {
                return "error"
            }
        }.value
        XCTAssertEqual(code, "timeout")
    }

    func testAChangeToARecurringEventNamesItsOccurrence() throws {
        XCTAssertThrowsError(try CalendarTools.occurrenceToChange(recurring: true, nil)) { error in
            XCTAssertEqual((error as? ToolFailure)?.code, "invalid_arguments")
        }
        let start = Date(timeIntervalSince1970: 1_792_540_800)
        XCTAssertEqual(try CalendarTools.occurrenceToChange(recurring: true, start), start)
        // A single event is changed by its id; an occurrence start does not matter.
        XCTAssertNil(try CalendarTools.occurrenceToChange(recurring: false, start))
    }

    func testInvalidArgumentsNameTheField() async {
        let result = await service(CalendarTools.all, StubPermissions([.calendars: .granted]))
            .call("calendar_list_events", ["start": "tomorrow-ish", "end": "2026-10-13"])
        XCTAssertEqual(errorCode(result), "invalid_arguments")
        XCTAssertEqual(errorField(result, "field"), "start")

        let unknown = await service([], StubPermissions([:])).call("calendar_delete_everything", [:])
        XCTAssertEqual(errorCode(unknown), "unknown_tool")
    }

    /// Messages needs only Automation: its history, which needs Full Disk Access, is not read.
    func testMessagesNeedsOnlyAutomation() async {
        let permissions = StubPermissions([.automation(BundleID.messages): .notDetermined])
        let report = await service(Catalog.all, permissions).requestPermissions(for: .messages)

        XCTAssertEqual(permissions.requested, [.automation(BundleID.messages)])
        let requirements = report.objectValue?["requirements"]?.arrayValue?.compactMap {
            $0.objectValue?["requirement"]?.stringValue
        }
        XCTAssertEqual(requirements, ["automation:\(BundleID.messages)"])
    }

    /// Turning Vision on asks for Screen Recording even when it is granted: macOS's
    /// question about capturing without its window picker comes then, not in a tool call.
    func testTurningVisionOnAsksForScreenCaptureEvenWhenGranted() async {
        let permissions = StubPermissions([.screenRecording: .granted])
        _ = await service(Catalog.all, permissions).requestPermissions(for: .vision)
        XCTAssertEqual(permissions.requested, [.screenRecording])
    }

    /// Main shows and filters tools per app by name prefix.
    func testEveryToolBelongsToItsAppByName() {
        let names = Catalog.all.map(\.name)
        XCTAssertEqual(Set(names).count, names.count)
        for tool in Catalog.all {
            XCTAssertTrue(tool.name.hasPrefix(tool.app.toolPrefix), tool.name)
        }
        XCTAssertEqual(Set(Catalog.all.map(\.app)), Set(MacApp.allCases))
    }

    func testDatesAcceptDaysLocalTimesAndOffsets() throws {
        let shanghai = TimeZone(identifier: "Asia/Shanghai")!
        let day = try XCTUnwrap(DateText.parse("2026-10-12", timeZone: shanghai))
        XCTAssertTrue(day.dateOnly)
        XCTAssertEqual(day.date.timeIntervalSince1970, 1_791_734_400)

        let local = try XCTUnwrap(DateText.parse("2026-10-12T15:00", timeZone: shanghai))
        XCTAssertFalse(local.dateOnly)
        XCTAssertEqual(local.date.timeIntervalSince1970, 1_791_788_400)

        let offset = try XCTUnwrap(DateText.parse("2026-10-12T15:00:00+08:00", timeZone: .gmt))
        XCTAssertEqual(offset.date, local.date)
        XCTAssertNil(DateText.parse("next Tuesday"))
    }

    /// Vision reads only Comma Drive: no other path on the Mac, and no symlink out of Drive.
    func testVisionReadsOnlyCommaDrive() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let drive = scratch.appendingPathComponent("drive")
        let outside = scratch.appendingPathComponent("outside.png")
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try Data([0]).write(to: outside)
        try Data([0]).write(to: drive.appendingPathComponent("inside.png"))
        try FileManager.default.createSymbolicLink(
            at: drive.appendingPathComponent("link.png"), withDestinationURL: outside)
        let files = FileLocations(driveRoot: drive)

        func failure(_ path: String) -> String? {
            do {
                _ = try ImageInput(Arguments(["path": .string(path)]), files: files)
                return nil
            } catch let error as ToolFailure {
                return error.message
            } catch {
                return "\(error)"
            }
        }

        XCTAssertNil(failure("/drive/inside.png"))
        XCTAssertEqual(failure(outside.path), "path must be a Comma Drive path (/drive/...).")
        XCTAssertEqual(failure("/drive/link.png"), "The path leaves Comma Drive.")
        XCTAssertEqual(failure("/drive/../outside.png"), "The path leaves Comma Drive.")
    }

    @MainActor
    func testEveryAppleScriptCompiles() throws {
        let runner = AppleScriptRunner()
        for source in Scripts.all {
            XCTAssertNoThrow(try runner.compile(source))
        }
    }

    /// The Plugins page shows each app's own icon; a wrong bundle id would leave it out.
    @MainActor
    func testEveryAppAndThePluginHaveTheirMacOSIcon() throws {
        let icons = try XCTUnwrap(AppIcons.report().objectValue?["icons"]?.objectValue)
        for key in MacApp.allCases.map(\.rawValue) + ["mac"] {
            let png = try XCTUnwrap(icons[key]?.stringValue.flatMap { Data(base64Encoded: $0) }, key)
            XCTAssertEqual(NSBitmapImageRep(data: png)?.pixelsWide, AppIcons.pixels, key)
        }
    }

    // MARK: - Helpers

    private func service(_ tools: [ToolDefinition], _ permissions: StubPermissions, timeout: Duration = .seconds(5))
        -> MacAppsService
    {
        let files = FileLocations(driveRoot: nil)
        let context = ToolContext(
            permissions: permissions, events: EventStoreBox(), appleScript: AppleScriptRunner(), files: files)
        return MacAppsService(tools: tools, context: context, callTimeout: timeout)
    }

    private func errorObject(_ result: CallTool.Result) -> [String: Value]? {
        guard result.isError == true else { return nil }
        return result.structuredContent?.objectValue?["error"]?.objectValue
    }

    private func errorCode(_ result: CallTool.Result) -> String? {
        errorObject(result)?["code"]?.stringValue
    }

    private func errorField(_ result: CallTool.Result, _ key: String) -> String? {
        errorObject(result)?[key]?.stringValue
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}

private final class StubPermissions: PermissionAuthority, @unchecked Sendable {
    private let lock = NSLock()
    private var states: [Requirement: PermissionState]
    private(set) var requested: [Requirement] = []

    init(_ states: [Requirement: PermissionState]) {
        self.states = states
    }

    func status(_ requirement: Requirement) async -> PermissionState {
        lock.withLock { states[requirement] ?? .granted }
    }

    func request(_ requirement: Requirement) async -> PermissionState {
        lock.withLock {
            requested.append(requirement)
            states[requirement] = .granted
            return .granted
        }
    }
}
