import Foundation
import XCTest
@testable import Comma

/// A view over the mesh as the core's progress gives it (core screen-views.ts): what the station is told back, and
/// when the page must go another way.
@MainActor final class PhoneMeshScreenTests: XCTestCase {
    func testFramesAreAcknowledgedAndAnAgentsLeaseLeavesTheDeviceToIt() async throws {
        let core = FakeCore()
        let (events, feed) = AsyncStream<[String: Any]>.makeStream()
        nonisolated(unsafe) let stream = events
        core.onStream("devices.openScreenView") { _, progress in
            for await event in stream { progress(event) }
            return nil
        }
        let model = PhoneMeshScreenModel(core: core, workspace: "w1", device: "dev", target: "simulator:A", instance: "i1", control: true)
        model.start()
        let opened = await core.first("devices.openScreenView")
        XCTAssertEqual(opened["target"] as? String, "simulator:A")
        XCTAssertEqual(opened["instance"] as? String, "i1")
        XCTAssertEqual(opened["codecs"] as? [String], ["h265", "h264"])

        feed.yield(["type": "open", "view": 3])
        feed.yield(["type": "state", "state": ["switches": true, "control": true]])
        // A frame with no config before it cannot be drawn: it is acknowledged all the same, and a key frame asked for.
        feed.yield(["type": "video", "key": true, "ts": 42, "data": ["$bytes": "AAAAAWU="]])
        let ack = await core.first("devices.sendToScreenView") { $0["ack"] != nil }
        XCTAssertEqual(ack["view"] as? Int, 3)
        XCTAssertEqual((ack["ack"] as? NSNumber)?.int64Value, 42)
        _ = await core.first("devices.sendToScreenView") { $0["keyframe"] as? Bool == true }
        XCTAssertEqual(model.phase, .live)

        model.touch("down", at: CGPoint(x: 0.25, y: 1.5))
        let touched = await core.first("devices.sendToScreenView") { $0["input"] != nil }
        let input = try XCTUnwrap(touched["input"] as? [String: Any])
        XCTAssertEqual(input["t"] as? String, "pointer")
        XCTAssertEqual(input["kind"] as? String, "down")
        XCTAssertEqual(input["y"] as? Double, 1)

        // An agent's lease: the view goes to Watch, on the open view, so the agent's input reaches the device.
        feed.yield(["type": "state", "state": ["agent": true, "agentPointer": ["x": 0.5, "y": 0.5, "down": true]]])
        _ = await core.first("devices.sendToScreenView") { $0["control"] as? Bool == false }
        await until { model.agent && model.agentPointer == CGPoint(x: 0.5, y: 0.5) }
        feed.finish()
        model.stop()
    }

    func testPicturesComeStraightFromTheCoreToTheDecoderAndAreAcknowledged() async throws {
        let core = FakeCore()
        core.sinks = true
        let (events, feed) = AsyncStream<[String: Any]>.makeStream()
        nonisolated(unsafe) let stream = events
        core.onStream("devices.openScreenView") { _, progress in
            for await event in stream { progress(event) }
            return nil
        }
        let model = PhoneMeshScreenModel(core: core, workspace: "w1", device: "dev", target: "display", control: false)
        model.start()
        let opened = await core.first("devices.openScreenView")
        let sink = try XCTUnwrap(opened["sink"] as? Int)
        feed.yield(["type": "open", "view": 5])
        await until { model.view == 5 }
        core.screenFrame(sink: sink, kind: 4, ts: 77, bytes: [0, 0, 0, 1, 0x65])
        let ack = await core.first("devices.sendToScreenView") { $0["ack"] != nil }
        XCTAssertEqual(ack["view"] as? Int, 5)
        XCTAssertEqual((ack["ack"] as? NSNumber)?.int64Value, 77)
        feed.finish()
        model.stop()
    }

    func testAMeshThatDoesNotReachTheComputerLeavesTheWayToAnother() async {
        let core = FakeCore()
        core.on("devices.openScreenView") { _ in throw CoreError(code: "unreachable", message: "The mesh did not reach that computer.") }
        let model = PhoneMeshScreenModel(core: core, workspace: "w1", device: "dev", target: "display", control: false)
        model.start()
        await until { model.phase == .unavailable }
    }

    func testARefusalIsSaidAsItIs() async {
        let core = FakeCore()
        core.on("devices.openScreenView") { _ in throw CoreError(code: "forbidden", message: "this computer does not allow its screen to be viewed") }
        let model = PhoneMeshScreenModel(core: core, workspace: "w1", device: "dev", target: "display", control: false)
        model.start()
        await until { model.phase == .failed("this computer does not allow its screen to be viewed") }
    }
}
