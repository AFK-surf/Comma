import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import Comma

@MainActor
final class DeviceSetupTests: XCTestCase {
    func testProjectionUsesCoreBoardIdentity() throws {
        let board = try XCTUnwrap(CommaDeviceRow(["device_id": "dev1", "name": "Comma-6AD8", "isCommaDevice": true, "status": "connected", "allows_operations": true]))
        XCTAssertTrue(board.comma)
        XCTAssertTrue(board.online)
        XCTAssertTrue(board.allowsOperations)
    }

    func testSetupScreenFollowsCoreAndSendsCancellation() async throws {
        let core = FakeCore()
        core.serve("deviceSetup") { _ in ["supported": true, "bluetooth": "on", "state": ["step": "pairing", "device": ["id": "fresh", "name": "Comma-6AD8"]]] }
        let model = AppleDeviceSetupModel(core: core, workspace: "wsp")
        let follow = Task { await model.follow() }
        defer { follow.cancel() }
        await until { model.step == "pairing" }
        XCTAssertEqual(model.name, "Comma-6AD8")
        model.cancel()
        let cancelled = await core.first("deviceSetup.event")
        XCTAssertEqual(cancelled["type"] as? String, "cancel")
        XCTAssertEqual(core.calls("deviceSetup.start").first?["workspace"] as? String, "wsp")
    }

    func testKeychainRecordsAreScopedAndPendingReadsAreBounded() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let records = TestKeychain()
        let store = DeviceSetupRecords(directory: directory, recordFor: { records.item($0) })
        let scope: [String: Any] = ["audience": "https://api.test", "account": "one", "workspace": "wsp"]
        for i in 0..<23 {
            var input = scope
            input["record"] = ["deviceId": String(format: "dev-%02d", i), "connectorToken": "salix_conn_test", "voiceKeyId": "key", "name": "Board", "createdAt": 0, "confirmed": false]
            _ = try store.call("put", input)
        }
        XCTAssertEqual((try store.call("records", scope) as? [Any])?.count, 20)
        XCTAssertEqual((try store.call("records", scope) as? [Any])?.count, 3)
        var other = scope; other["account"] = "two"
        XCTAssertEqual((try store.call("records", other) as? [Any])?.count, 0)
        var remove = scope; remove["deviceId"] = "dev-00"
        XCTAssertEqual(records.stored, 23)
        _ = try store.call("remove", remove)
        XCTAssertEqual((try store.call("records", remove) as? [Any])?.count, 0)
        // Removing deletes the Keychain item instead of leaving an empty one behind.
        XCTAssertEqual(records.stored, 22)
    }

    /// Render the real SwiftUI screen from a fake core. This test never constructs a Bluetooth manager.
    func testPairingScreenRendersOnSimulator() async throws {
        let core = FakeCore()
        core.serve("deviceSetup") { _ in ["supported": true, "bluetooth": "on", "state": ["step": "pairing", "device": ["id": "fresh", "name": "Comma-6AD8"]]] }
        let host = UIHostingController(rootView: NavigationStack { AddCommaDeviceView(core: core, workspace: "wsp") })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let original = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; original?.makeKeyAndVisible() }
        _ = await core.first("deviceSetup.start")
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            window.layoutIfNeeded(); host.view.layoutIfNeeded()
            if !core.topics("deviceSetup").isEmpty, host.view.bounds.height > 0 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        try await Task.sleep(for: .milliseconds(150))
        host.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image)
        attachment.name = "iPhone add device pairing (fake core)"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertNotNil(host.view.window)
    }
}

private final class TestKeychain: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: MemoryRecord] = [:]
    /// The items that hold a record.
    var stored: Int { lock.withLock { records.values.filter { (try? $0.read()) != nil }.count } }
    func item(_ key: String) -> MemoryRecord {
        lock.withLock { if let value = records[key] { return value }; let value = MemoryRecord(); records[key] = value; return value }
    }
}
