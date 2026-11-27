import CoreGraphics
import SwiftUI
import UIKit
import XCTest
@testable import Comma

@MainActor final class ChatMediaImageGroupTests: XCTestCase {
    // MARK: - Browse state machine & slot geometry

    func testInitialDeckSlotsMatchWebRightFan() {
        let state = ChatMediaImageGroupBrowseState()
        let slots = (0..<6).map { state.slot(for: $0, count: 6) }
        XCTAssertEqual(slots, [.front, .r1, .r2, .hiddenRight, .hiddenRight, .hiddenRight])

        let frontGeo = ChatMediaImageGroupSlot.front.geometry
        XCTAssertEqual(frontGeo.zIndex, 5)
        XCTAssertEqual(frontGeo.translateX, 0)
        XCTAssertEqual(frontGeo.rotationDegrees, 0)
        XCTAssertEqual(frontGeo.scale, 1.0)
        XCTAssertEqual(frontGeo.dimOpacity, 0)
        XCTAssertEqual(frontGeo.opacity, 1.0)

        let r1 = ChatMediaImageGroupSlot.r1.geometry
        XCTAssertEqual(r1.zIndex, 4)
        XCTAssertEqual(r1.translateX, 3)
        XCTAssertEqual(r1.rotationDegrees, 3.5)
        XCTAssertEqual(r1.scale, 0.97, accuracy: 0.0001)
        XCTAssertEqual(r1.dimOpacity, 0.08, accuracy: 0.0001)
        XCTAssertEqual(r1.opacity, 1.0)

        let l2 = ChatMediaImageGroupSlot.l2.geometry
        XCTAssertEqual(l2.zIndex, 3)
        XCTAssertEqual(l2.translateX, -6)
        XCTAssertEqual(l2.rotationDegrees, -7.0)
        XCTAssertEqual(l2.scale, 0.94, accuracy: 0.0001)
        XCTAssertEqual(l2.dimOpacity, 0.16, accuracy: 0.0001)
        XCTAssertEqual(l2.opacity, 1.0)

        let hiddenRight = ChatMediaImageGroupSlot.hiddenRight.geometry
        XCTAssertEqual(hiddenRight.zIndex, 0)
        XCTAssertEqual(hiddenRight.opacity, 0)
        XCTAssertEqual(hiddenRight.translateX, 6)
        XCTAssertEqual(hiddenRight.rotationDegrees, 7.0)
    }

    func testCyclicTwoPileRotationMatchesWebReducer() {
        var state = ChatMediaImageGroupBrowseState()
        // Rotate +1: throws front (0) to left history pile, exposes 1 as front
        state.rotate(step: 1, count: 6)
        XCTAssertEqual(state.frontIndex, 1)
        XCTAssertEqual(state.leftCount, 1)
        XCTAssertEqual((0..<6).map { state.slot(for: $0, count: 6) },
                       [.l1, .front, .r1, .r2, .hiddenRight, .hiddenRight])

        // Rotate +1 again: 0 -> l2, 1 -> l1, 2 -> front, 3 -> r1, 4 -> r2, 5 -> hiddenRight
        state.rotate(step: 1, count: 6)
        XCTAssertEqual(state.frontIndex, 2)
        XCTAssertEqual(state.leftCount, 2)
        XCTAssertEqual((0..<6).map { state.slot(for: $0, count: 6) },
                       [.l2, .l1, .front, .r1, .r2, .hiddenRight])

        // Rotate +1 once more: 0 parks into hiddenLeft
        state.rotate(step: 1, count: 6)
        XCTAssertEqual(state.frontIndex, 3)
        XCTAssertEqual(state.leftCount, 3)
        XCTAssertEqual((0..<6).map { state.slot(for: $0, count: 6) },
                       [.hiddenLeft, .l2, .l1, .front, .r1, .r2])

        // Rotate -1: returns front back to right pile, pulls 2 back to front
        state.rotate(step: -1, count: 6)
        XCTAssertEqual(state.frontIndex, 2)
        XCTAssertEqual(state.leftCount, 2)

        // Wrap past 0 backwards: stays cyclic and clamps leftCount at 0
        state.rotate(step: -1, count: 6)
        state.rotate(step: -1, count: 6)
        state.rotate(step: -1, count: 6)
        XCTAssertEqual(state.frontIndex, 5)
        XCTAssertEqual(state.leftCount, 0)
    }

    func testAlignAndNavigatePreviewSyncDeckState() {
        var state = ChatMediaImageGroupBrowseState(frontIndex: 2, leftCount: 1)
        // Aligning to the current front preserves leftCount
        state.alignPreview(index: 2, count: 6)
        XCTAssertEqual(state.frontIndex, 2)
        XCTAssertEqual(state.leftCount, 1)

        // Aligning to another card moves frontIndex and sets leftCount = index
        state.alignPreview(index: 4, count: 6)
        XCTAssertEqual(state.frontIndex, 4)
        XCTAssertEqual(state.leftCount, 4)

        // Navigating preview clamps to [0, count - 1]
        state.navigatePreview(step: 1, count: 6)
        XCTAssertEqual(state.frontIndex, 5)
        XCTAssertEqual(state.leftCount, 5)
        state.navigatePreview(step: 1, count: 6)
        XCTAssertEqual(state.frontIndex, 5)
        state.navigatePreview(step: -2, count: 6)
        XCTAssertEqual(state.frontIndex, 3)
        XCTAssertEqual(state.leftCount, 3)
    }

    func testStaggerDelaysOrderFrontFirstOnExpandAndDeepestFirstOnCollapse() {
        let state = ChatMediaImageGroupBrowseState()
        // Expand: front=0ms, r1=12ms, r2=24ms, hidden=36ms
        XCTAssertEqual(state.staggerDelay(for: 0, count: 6, expanding: true), 0.0, accuracy: 0.0001)
        XCTAssertEqual(state.staggerDelay(for: 1, count: 6, expanding: true), 0.012, accuracy: 0.0001)
        XCTAssertEqual(state.staggerDelay(for: 2, count: 6, expanding: true), 0.024, accuracy: 0.0001)
        XCTAssertEqual(state.staggerDelay(for: 3, count: 6, expanding: true), 0.036, accuracy: 0.0001)

        // Collapse: hidden=0ms, r2=8ms, r1=16ms, front=24ms
        XCTAssertEqual(state.staggerDelay(for: 3, count: 6, expanding: false), 0.0, accuracy: 0.0001)
        XCTAssertEqual(state.staggerDelay(for: 2, count: 6, expanding: false), 0.008, accuracy: 0.0001)
        XCTAssertEqual(state.staggerDelay(for: 1, count: 6, expanding: false), 0.016, accuracy: 0.0001)
        XCTAssertEqual(state.staggerDelay(for: 0, count: 6, expanding: false), 0.024, accuracy: 0.0001)
    }

    // MARK: - Single & expanded responsive layout geometry

    func testSingleImageGeometryPreservesAspectAndCapsWidth() {
        // 390pt phone -> availableWidth = 358pt -> maxWidth = 268pt
        XCTAssertEqual(ChatMediaImageGroupLayout.singleMaxWidth(availableWidth: 358), 268)
        // iPad / wide screen caps at 320pt
        XCTAssertEqual(ChatMediaImageGroupLayout.singleMaxWidth(availableWidth: 640), 320)

        // Landscape 16:10 image at 358pt available width
        let wide = ChatMediaImageGroupLayout.singleSize(aspectWidth: 1600, aspectHeight: 1000, availableWidth: 358)
        XCTAssertEqual(wide.width, 268)
        XCTAssertEqual(wide.height, 168)

        // Tall portrait 1:2 image caps height at 320pt
        let tall = ChatMediaImageGroupLayout.singleSize(aspectWidth: 500, aspectHeight: 1000, availableWidth: 358)
        XCTAssertEqual(tall.height, 320)
        XCTAssertEqual(tall.width, 160)

        // Missing metadata locks to 4:3 to prevent height jumps before decode
        let fallback = ChatMediaImageGroupLayout.singleSize(aspectWidth: nil, aspectHeight: nil, availableWidth: 358)
        XCTAssertEqual(fallback.width, 268)
        XCTAssertEqual(fallback.height, 201)
    }

    func testExpandedCardSizesAndGridAlignmentForPhoneAndWideScreens() {
        XCTAssertFalse(ChatMediaImageGroupLayout.isStackable(count: 1))
        XCTAssertFalse(ChatMediaImageGroupLayout.isStackable(count: 2))
        XCTAssertFalse(ChatMediaImageGroupLayout.isStackable(count: 3))
        XCTAssertTrue(ChatMediaImageGroupLayout.isStackable(count: 4))

        // Phone (358pt): 2 images -> 165x220 side by side
        let phone2 = ChatMediaImageGroupLayout.expandedCardSize(count: 2, availableWidth: 358)
        XCTAssertEqual(phone2, CGSize(width: 165, height: 220))

        // Phone (358pt): 3 images -> 114x152 side by side in 1 row
        let phone3 = ChatMediaImageGroupLayout.expandedCardSize(count: 3, availableWidth: 358)
        XCTAssertEqual(phone3, CGSize(width: 114, height: 152))
        XCTAssertEqual(ChatMediaImageGroupLayout.expandedColumns(count: 3, availableWidth: 358), 3)

        // Wide screen (>= 520pt): fixed 165x220
        let wide4 = ChatMediaImageGroupLayout.expandedCardSize(count: 4, availableWidth: 600)
        XCTAssertEqual(wide4, CGSize(width: 165, height: 220))

        // User right-aligned 4 images in 3 columns: last row (1 card) aligns to right edge
        let userGrid = ChatMediaImageGroupLayout.expandedGrid(count: 4, availableWidth: 358, isUser: true)
        XCTAssertEqual(userGrid.frames.count, 4)
        XCTAssertEqual(userGrid.frames[3].maxX, userGrid.containerSize.width, accuracy: 0.5)

        // Agent left-aligned 4 images: last row aligns to x = 0
        let agentGrid = ChatMediaImageGroupLayout.expandedGrid(count: 4, availableWidth: 358, isUser: false)
        XCTAssertEqual(agentGrid.frames[3].minX, 0, accuracy: 0.5)
    }

    // MARK: - Viewer fixes & bidirectional zoom sync

    func testViewerImageFrameIsNullBeforeLayoutAndUsesAttachmentAspectBeforeDecode() throws {
        let harness = try StoreHarness()
        let attachment = ChatAttachment(
            blockType: "image",
            index: 0,
            fileName: "wide.png",
            title: nil,
            mimeType: "image/png",
            size: 100,
            workspacePath: nil,
            width: 1600,
            height: 800,
            blob: nil,
            agentID: nil
        )
        let item = try XCTUnwrap(ChatMediaItem(messageID: "m1", position: 0, attachment: attachment, group: "g", conversation: "c"))
        let gallery = ChatMediaGallery()
        let viewer = ChatMediaViewer(items: [item], index: 0, initialImage: nil, gallery: gallery, store: harness.store)
        // Before layout, imageFrame must be .null (never CGRect.zero)
        XCTAssertTrue(viewer.imageFrame.isNull)

        // Load view with explicit bounds and verify fallback aspect ratio (2:1) is respected when image == nil
        viewer.loadViewIfNeeded()
        viewer.view.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        viewer.view.layoutIfNeeded()
        let page = try XCTUnwrap(viewer.currentPage)
        page.view.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        page.view.layoutIfNeeded()
        XCTAssertEqual(page.imageView.bounds.width, 400, accuracy: 1)
        XCTAssertEqual(page.imageView.bounds.height, 200, accuracy: 1)
        XCTAssertFalse(viewer.imageFrame.isNull)
    }

    func testGalleryViewerSyncNotifiesOwningMessage() throws {
        let gallery = ChatMediaGallery()
        var syncedIDs: [String] = []
        gallery.registerViewerSync(messageID: "msg-1") { syncedIDs.append($0) }

        let att = ChatAttachment(blockType: "image", index: 1, fileName: "b.png", title: nil, mimeType: "image/png",
                                 size: 100, workspacePath: nil, width: 600, height: 800, blob: nil, agentID: nil)
        let item = try XCTUnwrap(ChatMediaItem(messageID: "msg-1", position: 1, attachment: att, group: "g", conversation: "c"))
        gallery.notifyViewerPageChanged(item: item)
        XCTAssertEqual(syncedIDs, ["msg-1:1"])

        gallery.unregisterViewerSync(messageID: "msg-1")
        gallery.notifyViewerPageChanged(item: item)
        XCTAssertEqual(syncedIDs, ["msg-1:1"])
    }

    // MARK: - Mixed image + video + file partitioning (Agent & User)

    func testThreeImagesAndOneVideoStaySeparateAndNeverFoldIntoFourImages() throws {
        let harness = try StoreHarness()
        let gallery = ChatMediaGallery()
        let context = ChatMediaContext(gallery: gallery, store: harness.store, group: "g1", conversation: "c1")

        let attachments: [ChatAttachment] = [
            ChatAttachment(blockType: "image", index: 0, fileName: "shot-1.png", title: nil, mimeType: "image/png",
                           size: 100, workspacePath: nil, width: 800, height: 600, blob: nil, agentID: nil),
            ChatAttachment(blockType: "image", index: 1, fileName: "shot-2.png", title: nil, mimeType: "image/png",
                           size: 100, workspacePath: nil, width: 600, height: 800, blob: nil, agentID: nil),
            ChatAttachment(blockType: "image", index: 2, fileName: "shot-3.png", title: nil, mimeType: "image/png",
                           size: 100, workspacePath: nil, width: 800, height: 600, blob: nil, agentID: nil),
            ChatAttachment(blockType: "file", index: 3, fileName: "clip.mp4", title: nil, mimeType: "video/mp4",
                           size: 2048, workspacePath: nil, width: 1280, height: 720, blob: nil, agentID: nil),
            ChatAttachment(blockType: "file", index: 4, fileName: "report.pdf", title: nil, mimeType: "application/pdf",
                           size: 4096, workspacePath: nil, width: nil, height: nil, blob: nil, agentID: nil),
        ]

        // Agent message path
        let agentMessage = ChatItem(
            id: "agent-mixed", seq: 1, isUser: false, actorType: "agent", actorID: "router", actorRole: "router",
            createdBy: nil, clientRequestID: nil, replyToMessageID: nil, threadRootMessageID: nil, createdAt: nil,
            text: "", command: nil, quotes: [], attachedTexts: [], files: [], parts: [],
            attachments: attachments, refs: [], brief: false, markdown: nil
        )
        let agentPart = MessageExtras.partitionAttachments(message: agentMessage, context: context)
        XCTAssertEqual(agentPart.images.count, 3)
        XCTAssertFalse(ChatMediaImageGroupLayout.isStackable(count: agentPart.images.count))
        XCTAssertEqual(agentPart.videos.count, 1)
        XCTAssertTrue(agentPart.videos[0].isVideo)
        XCTAssertEqual(agentPart.files.count, 1)
        XCTAssertEqual(agentPart.files[0].name, "report.pdf")

        // User message path (mixing attachments + workspace files)
        let userFiles = [
            ChatFile(name: "upload-3.png", path: "/uploads/upload-3.png"),
            ChatFile(name: "demo.mov", path: "/uploads/demo.mov"),
            ChatFile(name: "notes.pdf", path: "/uploads/notes.pdf"),
        ]
        let userMessage = ChatItem(
            id: "user-mixed", seq: 2, isUser: true, actorType: "user", actorID: nil, actorRole: nil,
            createdBy: "u1", clientRequestID: nil, replyToMessageID: nil, threadRootMessageID: nil, createdAt: nil,
            text: "", command: nil, quotes: [], attachedTexts: [], files: userFiles, parts: [],
            attachments: Array(attachments.prefix(2)), refs: [], brief: false, markdown: nil
        )
        let userRow = ChatRow(
            id: "user-mixed", relationshipID: "user-mixed", content: .message(userMessage),
            isUser: true, actorRole: nil, createdBy: "u1", threadRoot: "user-mixed"
        )
        let userPart = ChatTranscriptView.partitionUserMedia(
            row: userRow, target: (groupID: "g1", conversationID: "c1"), context: context
        )
        XCTAssertEqual(userPart.images.count, 3)
        XCTAssertFalse(ChatMediaImageGroupLayout.isStackable(count: userPart.images.count))
        XCTAssertEqual(userPart.videos.count, 1)
        XCTAssertTrue(userPart.videos[0].isVideo)
        XCTAssertEqual(userPart.attachments.count, 0)
        XCTAssertEqual(userPart.fileNames, ["notes.pdf"])
    }
}
