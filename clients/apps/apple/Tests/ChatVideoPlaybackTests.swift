import AVFoundation
import XCTest
@testable import Comma

/// The native decoder and player use actual video bytes through the same Core range calls as production.
@MainActor final class ChatVideoPlaybackTests: XCTestCase {
    private func item() throws -> ChatMediaItem {
        try XCTUnwrap(ChatMediaItem(messageID: "video-message", position: 1,
                                   attachment: ChatAttachment(blockType: "file", index: 1, fileName: "clip.mp4", title: nil,
                                                              mimeType: "video/mp4", size: nil, workspacePath: nil,
                                                              width: nil, height: nil, blob: nil, agentID: nil),
                                   group: "g", conversation: "c"))
    }

    func testVideoCoverAndPlaybackReadBoundedRangesFromTheMessage() async throws {
        let harness = try StoreHarness()
        await harness.start()
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "chat-video", withExtension: "mp4"))
        let bytes = try Data(contentsOf: url)
        let maximum = ChatVideoAsset.chunkSize
        harness.core.on("files.readRange") { params in
            let offset = (params["offset"] as? NSNumber)?.intValue ?? 0
            let length = (params["length"] as? NSNumber)?.intValue ?? 0
            XCTAssertGreaterThan(length, 0)
            XCTAssertLessThanOrEqual(length, maximum)
            let source = params["source"] as? [String: Any]
            XCTAssertEqual(source?["source"] as? String, "attachment")
            XCTAssertEqual(source?["message"] as? String, "video-message")
            XCTAssertEqual(source?["index"] as? Int, 1)
            let start = min(bytes.count, offset), end = min(bytes.count, offset + length)
            return ["bytes": CoreBytes.json(bytes.subdata(in: start..<end)), "type": "video/mp4", "size": bytes.count]
        }
        let gallery = ChatMediaGallery()
        let media = try item()
        XCTAssertTrue(media.isVideo)
        let cover = try await gallery.image(media, full: false, store: harness.store)
        XCTAssertGreaterThan(try XCTUnwrap(cover.cgImage?.width), 0)
        XCTAssertLessThanOrEqual(try XCTUnwrap(cover.cgImage?.width), 640)

        let resource = try gallery.video(media, store: harness.store)
        let player = AVPlayer(playerItem: AVPlayerItem(asset: resource.asset))
        player.isMuted = true
        let played = expectation(description: "The native player advances past its cover frame")
        let observer = player.addBoundaryTimeObserver(forTimes: [NSValue(time: CMTime(seconds: 0.25, preferredTimescale: 600))],
                                                     queue: .main) { played.fulfill() }
        defer { player.pause(); player.removeTimeObserver(observer); player.replaceCurrentItem(with: nil); resource.close() }
        player.play()
        await fulfillment(of: [played], timeout: 10)
        XCTAssertGreaterThan(player.currentTime().seconds, 0.2)
        XCTAssertFalse(harness.core.calls("files.readRange").isEmpty)
        XCTAssertTrue(harness.core.calls("files.read").isEmpty, "Video never uses the whole-file image read")

        player.pause()
        resource.close()
        do { _ = try await resource.cover(maxPixel: 640); XCTFail("Closed playback cannot read again") }
        catch is CancellationError {}
    }

    func testRetiredAccountCannotLoadAVideoCover() async throws {
        let harness = try StoreHarness()
        await harness.start()
        let resource = try ChatMediaGallery().video(item(), store: harness.store)
        defer { resource.close() }
        harness.store.boundary += 1
        do { _ = try await resource.cover(maxPixel: 640); XCTFail("A retired view cannot read under another account") }
        catch is CancellationError {}
        XCTAssertTrue(harness.core.calls("files.readRange").isEmpty)
    }
}
