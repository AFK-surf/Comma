import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
import CommaCore
@testable import Comma

@MainActor
final class AttachmentUploadTests: XCTestCase {
    // MARK: - AttachmentFile.photo

    func testLargeOpaquePNGCompressesToJPEGWithin2048px() async throws {
        let png = try Self.makeNoisyPNG(width: 1_260, height: 2_736, withAlpha: false)
        XCTAssertGreaterThan(png.count, 512_000, "Synthetic large screenshot PNG should exceed compact threshold")
        XCTAssertFalse(AttachmentPhoto.hasAlpha(png))

        let result = try await AttachmentFile.photo(AttachmentImage(data: png, type: .png))
        XCTAssertEqual(result.file.filename, "Photo.jpg")
        XCTAssertEqual(result.file.contentType, "image/jpeg")
        XCTAssertLessThan(result.file.data.count, png.count / 2)
        let longestSide = try XCTUnwrap(AttachmentPhoto.longestSide(result.file.data))
        XCTAssertLessThanOrEqual(longestSide, 2_048)
        XCTAssertNotNil(result.thumbnail)
    }

    func testSmallOpaquePNGStaysVerbatim() async throws {
        let png = try Self.makeSolidPNG(width: 200, height: 200, withAlpha: false)
        XCTAssertLessThanOrEqual(png.count, 512_000)
        XCTAssertFalse(AttachmentPhoto.hasAlpha(png))

        let result = try await AttachmentFile.photo(AttachmentImage(data: png, type: .png))
        XCTAssertEqual(result.file.filename, "Photo.png")
        XCTAssertEqual(result.file.contentType, "image/png")
        XCTAssertEqual(result.file.data, png)
    }

    func testPNGWithAlphaStaysVerbatimWithinLimit() async throws {
        let png = try Self.makeNoisyPNG(width: 600, height: 600, withAlpha: true)
        XCTAssertLessThanOrEqual(png.count, 4_000_000)
        XCTAssertTrue(AttachmentPhoto.hasAlpha(png))

        let result = try await AttachmentFile.photo(AttachmentImage(data: png, type: .png))
        XCTAssertEqual(result.file.filename, "Photo.png")
        XCTAssertEqual(result.file.contentType, "image/png")
        XCTAssertEqual(result.file.data, png)
    }

    func testSmallGIFStaysVerbatim() async throws {
        let gif = try Self.makeSmallGIF(width: 64, height: 64)
        XCTAssertLessThanOrEqual(gif.count, 4_000_000)

        let result = try await AttachmentFile.photo(AttachmentImage(data: gif, type: .gif))
        XCTAssertEqual(result.file.filename, "Photo.gif")
        XCTAssertEqual(result.file.contentType, "image/gif")
        XCTAssertEqual(result.file.data, gif)
    }

    // MARK: - CoreHost.networkMessage

    func testCoreHostNetworkMessageMapsURLErrorsAndFallsBack() {
        let fallback = "Fallback message."
        XCTAssertEqual(CoreHost.networkMessage(URLError(.notConnectedToInternet), fallback: fallback),
                       String(localized: "No internet connection."))
        XCTAssertEqual(CoreHost.networkMessage(URLError(.timedOut), fallback: fallback),
                       String(localized: "The request timed out."))
        XCTAssertEqual(CoreHost.networkMessage(URLError(.networkConnectionLost), fallback: fallback),
                       String(localized: "The network connection was lost."))
        XCTAssertEqual(CoreHost.networkMessage(URLError(.cannotConnectToHost), fallback: fallback),
                       String(localized: "Couldn’t reach the server."))
        XCTAssertEqual(CoreHost.networkMessage(URLError(.secureConnectionFailed), fallback: fallback),
                       String(localized: "Couldn’t establish a secure connection."))
        XCTAssertEqual(CoreHost.networkMessage(URLError(.badURL), fallback: fallback), fallback)
        struct OtherError: Error {}
        XCTAssertEqual(CoreHost.networkMessage(OtherError(), fallback: fallback), fallback)
    }

    // MARK: - ConversationPane upload failures

    func testInitialFailedAttachmentDoesNotShowToast() async throws {
        let harness = try StoreHarness()
        harness.core.serve("chatView") { _ in nil }
        let store = harness.store
        await harness.start()
        defer { store.suspend() }
        let router = try XCTUnwrap(store.router.pane)

        harness.core.publish("chatView", matching: ["conversation": "router"], [
            "revision": 1,
            "state": [
                "status": "ready",
                "conversation": ["id": "router"],
                "draftAttachments": [
                    ["id": "att-1", "name": "Photo.jpg", "size": 1000, "status": "failed", "error": "The request timed out."],
                ],
            ],
        ])
        await until { router.state.revision == 1 }

        XCTAssertNil(router.error)
        XCTAssertNil(router.errorOrigin)
        XCTAssertEqual(router.errorRevision, 0)
    }

    func testAttachmentUploadFailureShowsToastMapsRawTimeoutAndClearsOnRetryOrRemove() async throws {
        let harness = try StoreHarness()
        let store = harness.store
        await harness.start()
        defer { store.suspend() }
        let router = try XCTUnwrap(store.router.pane)
        await until { router.state.loaded }

        // Start uploading
        harness.core.publish("chatView", matching: ["conversation": "router"], [
            "revision": 2,
            "state": [
                "status": "ready",
                "conversation": ["id": "router"],
                "draftAttachments": [
                    ["id": "att-1", "name": "Photo.jpg", "size": 2048, "status": "uploading"],
                ],
            ],
        ])
        await until { router.state.revision == 2 }
        XCTAssertNil(router.error)

        // Transition to failed with explicit message
        harness.core.publish("chatView", matching: ["conversation": "router"], [
            "revision": 3,
            "state": [
                "status": "ready",
                "conversation": ["id": "router"],
                "draftAttachments": [
                    ["id": "att-1", "name": "Photo.jpg", "size": 2048, "status": "failed", "error": "The request timed out."],
                ],
            ],
        ])
        await until { router.state.revision == 3 }
        XCTAssertEqual(router.error, "The request timed out.")
        XCTAssertEqual(router.errorOrigin, .attachment)
        let revAfterFirstFail = router.errorRevision
        XCTAssertGreaterThan(revAfterFirstFail, 0)

        // Unrelated snapshot update does not re-trigger toast
        harness.core.publish("chatView", matching: ["conversation": "router"], [
            "revision": 4,
            "state": [
                "status": "ready",
                "draft": "hello",
                "conversation": ["id": "router"],
                "draftAttachments": [
                    ["id": "att-1", "name": "Photo.jpg", "size": 2048, "status": "failed", "error": "The request timed out."],
                ],
            ],
        ])
        await until { router.state.revision == 4 }
        XCTAssertEqual(router.errorRevision, revAfterFirstFail)

        // Retry clears .attachment error
        router.retryAttachment("att-1")
        XCTAssertNil(router.error)
        XCTAssertNil(router.errorOrigin)

        // Uploading again, then fails with localized core message
        harness.core.publish("chatView", matching: ["conversation": "router"], [
            "revision": 5,
            "state": [
                "status": "ready",
                "conversation": ["id": "router"],
                "draftAttachments": [
                    ["id": "att-1", "name": "Photo.jpg", "size": 2048, "status": "uploading"],
                ],
            ],
        ])
        await until { router.state.revision == 5 }

        harness.core.publish("chatView", matching: ["conversation": "router"], [
            "revision": 6,
            "state": [
                "status": "ready",
                "conversation": ["id": "router"],
                "draftAttachments": [
                    ["id": "att-1", "name": "Photo.jpg", "size": 2048, "status": "failed",
                     "error": "Upload timed out"],
                ],
            ],
        ])
        await until { router.state.revision == 6 }
        XCTAssertEqual(router.error, "Upload timed out")
        XCTAssertEqual(router.errorOrigin, .attachment)
        XCTAssertEqual(router.errorRevision, revAfterFirstFail + 1)
        if case .failed(let tileMessage) = router.drafts.first?.state {
            XCTAssertEqual(tileMessage, "Upload timed out")
        } else {
            XCTFail("Expected failed draft state")
        }

        XCTAssertEqual(ConversationPane.uploadFailureMessage("   \n  "),
                       String(localized: "The file could not be uploaded."))
        XCTAssertEqual(ConversationPane.uploadFailureMessage(nil),
                       String(localized: "The file could not be uploaded."))

        // Remove clears .attachment error
        router.removeAttachment("att-1")
        XCTAssertNil(router.error)
        XCTAssertNil(router.errorOrigin)
    }

    func testQuestionCardAttachmentFailureShowsToast() async throws {
        let harness = try StoreHarness()
        let store = harness.store
        await harness.start()
        defer { store.suspend() }
        let router = try XCTUnwrap(store.router.pane)
        await until { router.state.loaded }

        harness.core.publish("chatView", matching: ["conversation": "router"], [
            "revision": 2,
            "state": [
                "status": "ready",
                "conversation": ["id": "router"],
                "questionAttachments": [
                    "msg-q1": [
                        ["id": "q-att-1", "name": "Photo.jpg", "size": 1024, "status": "uploading"],
                    ],
                ],
            ],
        ])
        await until { router.state.revision == 2 }
        XCTAssertNil(router.error)

        harness.core.publish("chatView", matching: ["conversation": "router"], [
            "revision": 3,
            "state": [
                "status": "ready",
                "conversation": ["id": "router"],
                "questionAttachments": [
                    "msg-q1": [
                        ["id": "q-att-1", "name": "Photo.jpg", "size": 1024, "status": "failed",
                         "error": "No internet connection."],
                    ],
                ],
            ],
        ])
        await until { router.state.revision == 3 }
        XCTAssertEqual(router.error, "No internet connection.")
        XCTAssertEqual(router.errorOrigin, .attachment)
    }

    // MARK: - CommaStore core locale

    func testCoreLocaleMapsChineseAndFallbackToEnglish() {
        for zh in ["zh-Hans", "zh-Hans-CN", "zh-CN", "zh-Hant"] {
            XCTAssertEqual(CommaStore.coreLocale(for: zh), "zh-CN", zh)
        }
        for other in ["en", "en-US", "ja", nil] {
            XCTAssertEqual(CommaStore.coreLocale(for: other), "en", other ?? "nil")
        }
    }

    func testCommaStoreStartSendsChatLocaleToCore() async throws {
        let harness = try StoreHarness()
        let store = harness.store
        await harness.start()
        defer { store.suspend() }

        XCTAssertEqual(harness.core.calls("chat.locale").first?["locale"] as? String, CommaStore.coreLocale())
    }

    // MARK: - Synthetic image helpers

    private static func makeNoisyPNG(width: Int, height: Int, withAlpha: Bool) throws -> Data {
        let bytesPerPixel = 4
        var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        for i in stride(from: 0, to: pixels.count, by: 4) {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            pixels[i] = UInt8((state >> 56) & 0xFF)
            pixels[i + 1] = UInt8((state >> 48) & 0xFF)
            pixels[i + 2] = UInt8((state >> 40) & 0xFF)
            pixels[i + 3] = withAlpha ? UInt8(((state >> 32) & 0x7F) + 64) : 255
        }
        return try encodeImage(pixels: &pixels, width: width, height: height, withAlpha: withAlpha, type: .png)
    }

    private static func makeSolidPNG(width: Int, height: Int, withAlpha: Bool) throws -> Data {
        var pixels = [UInt8](repeating: 120, count: width * height * 4)
        for i in stride(from: 3, to: pixels.count, by: 4) { pixels[i] = withAlpha ? 128 : 255 }
        return try encodeImage(pixels: &pixels, width: width, height: height, withAlpha: withAlpha, type: .png)
    }

    private static func makeSmallGIF(width: Int, height: Int) throws -> Data {
        var pixels = [UInt8](repeating: 200, count: width * height * 4)
        return try encodeImage(pixels: &pixels, width: width, height: height, withAlpha: false, type: .gif)
    }

    private static func encodeImage(pixels: inout [UInt8], width: Int, height: Int, withAlpha: Bool, type: UTType) throws -> Data {
        let colorSpace = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: CGBitmapInfo = withAlpha
            ? CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
            : CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        let cgImage: CGImage = try pixels.withUnsafeMutableBytes { ptr in
            guard let ctx = CGContext(data: ptr.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: colorSpace, bitmapInfo: bitmapInfo.rawValue),
                  let image = ctx.makeImage() else {
                throw XCTSkip("Could not create CGImage")
            }
            return image
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw XCTSkip("Could not create image destination")
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw XCTSkip("Could not finalize image")
        }
        return data as Data
    }
}
