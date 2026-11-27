@testable import Comma
import Foundation
import XCTest

final class PerformanceRecordTests: XCTestCase {
    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PerformanceRecordTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "PerformanceRecordTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (defaults, suite)
    }

    @MainActor
    func testRecordingIsOffByDefaultAndWritesNothing() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let perfDir = root.appendingPathComponent("perf", isDirectory: true)
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let record = PerformanceRecord(
            directory: perfDir,
            defaults: defaults,
            useSharedEngineHooks: false,
            bridgeCounters: CoreBridgePerfCounters()
        )
        record.startIfNeeded()
        record.note("ignored while off")
        record.sampleTickNow()
        record.flushForTesting()

        XCTAssertFalse(record.isEnabled)
        XCTAssertEqual(record.recordedBytes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: perfDir.path))
        XCTAssertNil(record.exportFileURL())
    }

    @MainActor
    func testTogglePersistsWritesLifecycleLinesAndSampleTick() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let fixedDate = Date(timeIntervalSince1970: 1_760_000_000)
        let counters = CoreBridgePerfCounters()
        let record = PerformanceRecord(
            directory: dir,
            defaults: defaults,
            useSharedEngineHooks: false,
            bridgeCounters: counters,
            now: { fixedDate }
        )
        defer { record.setEnabled(false) }

        record.pageSummaryProvider = { "tab=home router=1 task=0 ws=ws-1" }
        record.setEnabled(true)
        XCTAssertTrue(record.isEnabled)
        XCTAssertTrue(defaults.bool(forKey: PerformanceRecord.defaultsKey))

        counters.recordOut("call.chat.list")
        counters.recordIn("topic.inbox", bytes: 4096, ms: 12.5)
        record.sampleTickNow()
        record.setEnabled(false)
        record.note("after off should not appear")
        record.flushForTesting()

        XCTAssertFalse(record.isEnabled)
        XCTAssertFalse(defaults.bool(forKey: PerformanceRecord.defaultsKey))
        XCTAssertGreaterThan(record.recordedBytes, 0)

        let exportURL = try XCTUnwrap(record.exportFileURL())
        defer { try? FileManager.default.removeItem(at: exportURL) }
        let content = try String(contentsOf: exportURL, encoding: .utf8)

        XCTAssertTrue(content.contains("perf: on (turned on) device="))
        XCTAssertTrue(content.contains("ios: cpu="))
        XCTAssertTrue(content.contains("threads:"))
        XCTAssertTrue(content.contains("power: user="))
        XCTAssertTrue(content.contains("core: in (ms/count/KB): 12.5ms/1/4.0KB topic.inbox || out (count): 1 call.chat.list"))
        XCTAssertTrue(content.contains("page: tab=home router=1 task=0 ws=ws-1"))
        XCTAssertTrue(content.contains("perf: off"))
        XCTAssertFalse(content.contains("after off should not appear"))
    }

    @MainActor
    func testStartIfNeededResumesSavedToggleAcrossRelaunch() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(true, forKey: PerformanceRecord.defaultsKey)
        let record = PerformanceRecord(
            directory: dir,
            defaults: defaults,
            useSharedEngineHooks: false,
            bridgeCounters: CoreBridgePerfCounters()
        )
        defer { record.setEnabled(false) }

        record.startIfNeeded()
        record.flushForTesting()

        XCTAssertTrue(record.isEnabled)
        let exportURL = try XCTUnwrap(record.exportFileURL())
        defer { try? FileManager.default.removeItem(at: exportURL) }
        let content = try String(contentsOf: exportURL, encoding: .utf8)
        XCTAssertTrue(content.contains("perf: on (launch) device="))
    }

    @MainActor
    func testUnavailableBuildIgnoresSavedToggleAndRefusesEnable() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let perfDir = root.appendingPathComponent("perf", isDirectory: true)
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(true, forKey: PerformanceRecord.defaultsKey)
        let record = PerformanceRecord(
            directory: perfDir,
            defaults: defaults,
            available: false,
            useSharedEngineHooks: false,
            bridgeCounters: CoreBridgePerfCounters()
        )

        record.startIfNeeded()
        record.setEnabled(true)
        record.note("ignored on app store build")
        record.sampleTickNow()
        record.flushForTesting()

        XCTAssertFalse(record.isEnabled)
        XCTAssertEqual(record.recordedBytes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: perfDir.path))
        XCTAssertNil(record.exportFileURL())
    }

    func testLogStoreRotatesRetainsNewestThreeAndExportsOldestFirst() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixedDate = Date(timeIntervalSince1970: 1_760_000_000)
        let store = PerfLogStore(
            directory: dir,
            maxFileBytes: 256,
            maxFilesKept: 3,
            now: { fixedDate }
        )

        let payload = String(repeating: "x", count: 140)
        for idx in 1...10 {
            store.append("entry-\(idx) \(payload)", continuationHeader: { "perf: continued test-device" })
        }
        store.flushSync()

        let files = store.listFilesForTesting()
        XCTAssertEqual(files.count, 3)

        let exportTarget = dir.appendingPathComponent("combined.log")
        let exported = try XCTUnwrap(store.exportCombined(to: exportTarget))
        let combined = try String(contentsOf: exported, encoding: .utf8)

        XCTAssertFalse(combined.contains("entry-1 "))
        XCTAssertTrue(combined.contains("perf: continued test-device"))
        let idx8 = try XCTUnwrap(combined.range(of: "entry-8 "))
        let idx9 = try XCTUnwrap(combined.range(of: "entry-9 "))
        let idx10 = try XCTUnwrap(combined.range(of: "entry-10 "))
        XCTAssertLessThan(idx8.lowerBound, idx9.lowerBound)
        XCTAssertLessThan(idx9.lowerBound, idx10.lowerBound)
    }

    func testCoreBridgePerfCountersTopSixAndReset() {
        let counters = CoreBridgePerfCounters()
        for idx in 1...8 {
            counters.recordIn("topic.\(idx)", bytes: idx * 1024, ms: Double(idx) * 2.0)
            for _ in 0..<idx {
                counters.recordOut("call.\(idx)")
            }
        }

        let summary = counters.takeSummary()
        XCTAssertTrue(summary.contains("16.0ms/1/8.0KB topic.8"))
        XCTAssertTrue(summary.contains("6.0ms/1/3.0KB topic.3"))
        XCTAssertFalse(summary.contains("topic.2"))
        XCTAssertFalse(summary.contains("topic.1"))
        XCTAssertTrue(summary.contains("8 call.8"))
        XCTAssertTrue(summary.contains("3 call.3"))
        XCTAssertFalse(summary.contains("2 call.2"))
        XCTAssertEqual(counters.takeSummary(), "")
    }

    func testMainRunLoopAccumulatorTracksSlowAndHitchTurnsAndResets() {
        var acc = MainRunLoopAccumulator()
        XCTAssertNil(acc.takeSummary(spanMs: 5000))

        acc.recordTurn(durationMs: 4.0)
        acc.recordTurn(durationMs: 20.0)
        acc.recordTurn(durationMs: 76.0)

        let summary = acc.takeSummary(spanMs: 1000.0)
        XCTAssertEqual(summary, "turns=3 busy=10% max=76ms slow=2 hitch=1")
        XCTAssertNil(acc.takeSummary(spanMs: 1000.0))
    }

    func testNativeMetricsAndEnginePerfTimingHooksWork() {
        XCTAssertGreaterThanOrEqual(CommaPerfProcessCPUMs(), 0)
        XCTAssertGreaterThan(CommaPerfMemoryBytes(), 0)
        let power = CommaPerfReadPower()
        XCTAssertTrue(power.valid)
        XCTAssertFalse(CommaPerfMachineIdentifier().isEmpty)
        XCTAssertFalse(CommaPerfBinaryUUID().isEmpty)

        let tracker = CommaPerfThreadTracker()
        _ = tracker.sampleOverSpanMs(20.0)
        // Burn a small slice of CPU so the current thread exceeds the 0.5% threshold.
        let deadline = DispatchTime.now().uptimeNanoseconds + 20_000_000
        var sink: UInt64 = 0
        while DispatchTime.now().uptimeNanoseconds < deadline {
            sink = sink &+ 1
        }
        XCTAssertGreaterThan(sink, 0)
        let sample = tracker.sampleOverSpanMs(20.0)
        XCTAssertTrue(sample.summary.contains("%"), "Unexpected thread summary: \(sample.summary)")
        XCTAssertNotEqual(sample.hottestThreadID, 0)
        XCTAssertGreaterThan(sample.hottestPercent, 5.0)

        CommaEngine.setPerfTimingEnabled(false)
        XCTAssertEqual(CommaEngine.takePerfSummary(forSpanMs: 5000.0), "")
    }
}
