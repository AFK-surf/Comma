import SwiftUI
import XCTest
@testable import Comma

@MainActor final class ChatImagePreviewTests: XCTestCase {
    private func imageMessages() -> [ChatRow] {
        let reader = ChatViewReader()
        let value: [String: Any] = ["revision": 1, "state": ["status": "ready", "serverMessages": [
            ["messageId": "sent", "role": "user", "attachments": [
                ["blockType": "image", "attachmentIndex": 2, "fileName": "sent.png", "mimeType": "image/png"],
                ["blockType": "file", "attachmentIndex": 3, "fileName": "notes.pdf"],
            ]],
            ["messageId": "reply", "role": "assistant", "attachments": [
                ["blockType": "image", "fileName": "generated.png", "agentId": "a", "blobRef": [
                    "kind": "blob", "uuid": "b", "hash": String(repeating: "a", count: 64), "size": 100,
                ]],
                ["blockType": "image", "fileName": "unavailable.png"],
            ]],
        ]]]
        return ChatTranscriptModel.rows(timeline: reader.read(value).timeline, isTask: false)
    }

    func testGalleryKeepsMessageOrderAndReadsEachImageFromItsOwner() throws {
        let images = ChatMediaItem.items(in: imageMessages(), group: "g", conversation: "c")
        XCTAssertEqual(images.map(\.id), ["sent:0", "reply:0"])
        let sent = try XCTUnwrap(images.first?.source.value as? [String: Any])
        XCTAssertEqual(sent["source"] as? String, "attachment")
        XCTAssertEqual(sent["index"] as? Int, 2)
        XCTAssertEqual(sent["message"] as? String, "sent")
        let reply = try XCTUnwrap(images.last?.source.value as? [String: Any])
        XCTAssertEqual(reply["source"] as? String, "agent-blob")
        XCTAssertEqual(reply["agent"] as? String, "a")
        XCTAssertEqual((reply["blobRef"] as? [String: Any])?["uuid"] as? String, "b")
        let user = try XCTUnwrap(imageMessages().first?.message)
        let upload = try XCTUnwrap(ChatMediaItem(message: user,
                                               file: ChatFile(name: "photo.png", path: "/uploads/abcdefghijklmnopqrstuv-photo.png"),
                                               position: 0, group: "g", conversation: "c"))
        XCTAssertEqual((upload.source.value as? [String: Any])?["source"] as? String, "group-file")
        XCTAssertNil(ChatMediaItem(message: user, file: ChatFile(name: "notes.pdf", path: "/uploads/notes.pdf"),
                                  position: 0, group: "g", conversation: "c"))
    }

    func testPreviewDecodesToItsPixelBudgetAndReusesTheRead() async throws {
        let harness = try StoreHarness()
        await harness.start()
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let png = UIGraphicsImageRenderer(size: CGSize(width: 2400, height: 1200), format: format).pngData { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 2400, height: 1200))
        }
        harness.core.on("files.read") { _ in ["bytes": ["$bytes": png.base64EncodedString()], "type": "image/png"] }
        let item = try XCTUnwrap(ChatMediaItem.items(in: imageMessages(), group: "g", conversation: "c").first)
        let gallery = ChatMediaGallery()
        let thumbnail = try await gallery.image(item, full: false, store: harness.store)
        XCTAssertEqual(thumbnail.cgImage?.width, 640)
        XCTAssertEqual(thumbnail.cgImage?.height, 320)
        let again = try await gallery.image(item, full: false, store: harness.store)
        XCTAssertTrue(thumbnail === again)
        XCTAssertEqual(harness.core.calls("files.read").count, 1)
        let full = try await gallery.image(item, full: true, store: harness.store)
        XCTAssertEqual(full.cgImage?.width, 2048)
        XCTAssertEqual(full.cgImage?.height, 1024)
        harness.store.boundary += 1
        do {
            _ = try await gallery.image(item, full: false, store: harness.store)
            XCTFail("A retired account cannot expose its cached picture")
        } catch is CancellationError {}
    }

    func testSentImageUsesItsMessageAttachmentInsteadOfTheResourceEndpoint() throws {
        let item = try XCTUnwrap(ChatMediaItem(messageID: "sent-image", position: 0,
            attachment: ChatAttachment(blockType: "image", index: 2, fileName: "photo.png", title: nil,
                                       mimeType: "image/png", size: 100, workspacePath: nil, width: nil, height: nil,
                                       blob: CoreJSON(value: ["kind": "blob", "uuid": "b", "hash": "a", "size": 100]), agentID: "a"),
            group: "g", conversation: "c"))
        let source = try XCTUnwrap(item.source.value as? [String: Any])
        XCTAssertEqual(source["source"] as? String, "attachment")
        XCTAssertEqual(source["message"] as? String, "sent-image")
        XCTAssertEqual(source["index"] as? Int, 2)
    }

    func testStalledPreviewsEndAndReleaseTheirReadSlotsForRetry() async throws {
        let harness = try StoreHarness()
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let png = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 40), format: format).pngData { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
        }
        harness.core.on("files.read") { _ in ["bytes": CoreBytes.json(png)] }
        let core = StalledPreviewCore(base: harness.core)
        let custody = try SessionCustody(record: MemoryRecord(), apiOrigin: testOrigin)
        let store = CommaStore(configuration: harness.store.configuration, core: core, custody: custody, apple: AppleSignInSheet(),
                               workspacePreferences: UserDefaults(suiteName: UUID().uuidString)!)
        await store.start()
        await until { store.session != nil }
        let item = try XCTUnwrap(ChatMediaItem.items(in: imageMessages(), group: "g", conversation: "c").first)
        let gallery = ChatMediaGallery()
        for _ in 0..<3 {
            do { _ = try await gallery.image(item, full: false, store: store, timeout: .milliseconds(50)); XCTFail("A stalled preview must settle") }
            catch let error as CoreError { XCTAssertEqual(error.code, "preview_timeout") }
        }
        let retried = try await gallery.image(item, full: false, store: store)
        XCTAssertEqual(retried.cgImage?.width, 80)
        XCTAssertEqual(harness.core.calls("files.read").count, 1, "Timed out reads stop before the retry succeeds")
    }

    func testMalformedImageShowsFailureInsteadOfAFalsePreview() async throws {
        do {
            _ = try await ChatImageDecode.image(data: Data("not an image".utf8), maxPixel: 640)
            XCTFail("An invalid attachment cannot become a visible picture")
        } catch let error as CoreError { XCTAssertEqual(error.code, "invalid_image") }
    }
}

private final class StalledPreviewCore: CoreAPI, @unchecked Sendable {
    let base: FakeCore
    private let lock = NSLock()
    private var stalled = 3
    init(base: FakeCore) { self.base = base }

    nonisolated(nonsending) func call(_ name: String, _ params: [String: Any]) async throws -> CoreJSON {
        let stall = name == "files.read" && lock.withLock { () -> Bool in
            guard stalled > 0 else { return false }
            stalled -= 1
            return true
        }
        if stall { try await Task.sleep(for: .seconds(60)) }
        return try await base.call(name, params)
    }

    func subscribe<T: Sendable>(_ topic: [String: Any], read: @escaping @Sendable (Any?) -> T) -> AsyncStream<TopicValue<T>> {
        base.subscribe(topic, read: read)
    }
}
