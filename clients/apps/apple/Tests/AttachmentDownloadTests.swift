import XCTest
@testable import Comma

/// A message attachment opens from the file the client core downloaded to the device, whatever its size.
final class AttachmentDownloadTests: XCTestCase {
    private static func source() -> [String: Any] {
        ["source": "attachment", "group": "g", "conversation": "c", "message": "m", "index": 1]
    }

    func testOpensTheFileOnceTheCoreSaysItIsWholeIgnoringStatesFromBeforeTheCall() async throws {
        let core = FakeCore()
        core.on("downloads.start") { _ in ["asked": 2] }
        // A failure from an earlier attempt, which this call starts again.
        core.serve("download") { _ in ["status": "failed", "failure": "network", "asked": 1] }
        let opening = Task {
            try await AttachmentDownload.path(core: core, source: Self.source(), name: "clip.mp4")
        }

        let started = await core.first("downloads.start")
        XCTAssertEqual(started["name"] as? String, "clip.mp4")
        XCTAssertEqual((started["source"] as? [String: Any])?["message"] as? String, "m")
        // The state followed is the same file's, its source as JSON.
        let topic = try XCTUnwrap(core.topics("download").first?["source"] as? String)
        let named = try JSONSerialization.jsonObject(with: Data(topic.utf8)) as? [String: Any]
        XCTAssertEqual(named?["index"] as? Int, 1)
        core.publish("download", ["status": "downloading", "received": 1_000, "asked": 2])
        core.publish("download", ["status": "ready", "path": "acct/a1/clip.mp4", "asked": 2])

        let path = try await opening.value
        XCTAssertEqual(path, "acct/a1/clip.mp4")
    }

    func testSaysWhyTheDownloadFailed() async throws {
        let core = FakeCore()
        core.on("downloads.start") { _ in ["asked": 1] }
        let opening = Task {
            try await AttachmentDownload.path(core: core, source: Self.source(), name: "clip.mp4")
        }
        _ = await core.first("downloads.start")
        core.publish("download", ["status": "failed", "failure": "unavailable", "asked": 1])

        do {
            _ = try await opening.value
            XCTFail("A failed download opens nothing")
        } catch let error as CoreError {
            XCTAssertEqual(error.code, "unavailable")
        }
    }
}
