import XCTest

/// Runs the perf scenarios against the fixture's `FramePacingProbe`. Each scenario's metrics (the probe's window,
/// the test's wall time and any marks) go to `$PERF_OUT/<scenario>.json` and to the test's attachments.
/// `measure.sh` sets PERF_OUT through xcodebuild's `TEST_RUNNER_PERF_OUT`; without it the scenarios skip, so a
/// plain e2e run stays a correctness run.
extension PerfScenarios {
    /// An empty value counts as unset, so a script that forwards an unset variable still skips.
    var perfOutput: URL? {
        ProcessInfo.processInfo.environment["PERF_OUT"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
    }
    /// Where the probe writes each window's summary. Simulator processes share the Mac's file system, and
    /// reading a file costs the app nothing, where a UI query snapshots its whole accessibility tree.
    private var probeFile: URL { FileManager.default.temporaryDirectory.appendingPathComponent("frame-pacing.json") }

    /// Launches the fixture for a scenario: English, light, the long router chat, held streams and the probe.
    func launchPerfFixture(_ extra: [String] = []) throws -> XCUIApplication {
        guard perfOutput != nil else { throw XCTSkip("Perf scenarios run from perf/measure.sh, which sets TEST_RUNNER_PERF_OUT") }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-AppleInterfaceStyle", "Light",
                               "--perf-probe", "--perf-long-chat", "--perf-hold-stream"] + extra
        app.launchEnvironment["PERF_PROBE_FILE"] = probeFile.path
        app.launch()
        XCTAssertTrue(app.buttons["openRouterChat"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.element("framePacing").exists, "The fixture must be built with the frame pacing probe")
        // Launch work (task list, router history, routines) settles before anything is measured.
        Thread.sleep(forTimeInterval: 3)
        return app
    }

    /// Measures `body` as one probe window and records it under `scenario`. Signals reach the fixture without a
    /// UI query, so the window holds only the scenario's own interactions.
    func measureScenario(_ scenario: String, in app: XCUIApplication, _ body: () throws -> Void) throws {
        try? FileManager.default.removeItem(at: probeFile)
        marks = [:]
        PerfSignal.begin.post()
        Thread.sleep(forTimeInterval: 0.25)
        windowStart = Date()
        try body()
        let wall = Date().timeIntervalSince(windowStart ?? Date())
        PerfSignal.end.post()
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: probeFile.path), Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        let summary = try XCTUnwrap(try? Data(contentsOf: probeFile), "The probe must report the window")
        // Parsed numbers come back as Doubles; as decimals they serialize as short as the probe wrote them.
        var probe = try XCTUnwrap(JSONSerialization.jsonObject(with: summary) as? [String: Double]).mapValues(Self.decimal)
        probe.removeValue(forKey: "window")
        XCTAssertGreaterThan(probe["frames"] ?? 0, 0, "The probe saw no frames; did the begin signal arrive?")
        let record: [String: Any] = [
            "scenario": scenario, "test": name, "wallS": Self.decimal(wall), "marks": marks.mapValues(Self.decimal),
            "probe": probe, "arguments": app.launchArguments, "date": ISO8601DateFormatter().string(from: Date()),
        ]
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .prettyPrinted])
        if let directory = perfOutput {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(scenario + ".json"))
        }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = scenario + ".json"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Notes when a step finished, in seconds into the window, so runs can be checked for the same overlap.
    func mark(_ step: String) { marks[step] = Date().timeIntervalSince(windowStart ?? Date()) }

    private static func decimal(_ value: Double) -> Decimal { Decimal(string: String(format: "%.3f", value)) ?? 0 }
}

@MainActor extension XCUIApplication {
    /// A point in the app's frame, in points from its top-left corner.
    func point(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
        coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
    }

    /// A point at a fraction of the app's width and height.
    func at(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate { coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)) }
}
