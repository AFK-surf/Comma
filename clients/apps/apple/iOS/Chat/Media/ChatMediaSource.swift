import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// A loaded message's media and its existing file source. The gallery adds no history reads.
struct ChatMediaItem: Identifiable, Sendable {
    enum Kind: Sendable { case image, video }
    let id: String
    let messageID: String
    let attachment: ChatAttachment
    let source: CoreJSON
    let cacheKey: String
    let kind: Kind
    var isVideo: Bool { kind == .video }
    var mediaType: String {
        if let mime = attachment.mimeType, mime.hasPrefix(isVideo ? "video/" : "image/") { return mime }
        return UTType(filenameExtension: (attachment.name as NSString).pathExtension)?.preferredMIMEType ?? "video/mp4"
    }

    init?(messageID: String, position: Int, attachment: ChatAttachment, group: String, conversation: String) {
        let type = attachment.mimeType.flatMap { UTType(mimeType: $0) }
        let named = UTType(filenameExtension: (attachment.name as NSString).pathExtension)
        if attachment.blockType == "image" || type?.conforms(to: .image) == true || named?.conforms(to: .image) == true { kind = .image }
        else if type?.conforms(to: .movie) == true || named?.conforms(to: .movie) == true { kind = .video }
        else { return nil }
        let source: [String: Any]
        // Resolve sent media through its canonical message, as downloads and the web client do.
        if let index = attachment.index {
            source = ["source": "attachment", "group": group, "conversation": conversation, "message": messageID, "index": index]
        } else if let agent = attachment.agentID, let blob = attachment.blob?.value {
            source = ["source": "agent-blob", "group": group, "agent": agent, "blobRef": blob]
        } else if let path = attachment.workspacePath, path.hasPrefix("/uploads/") {
            source = ["source": "group-file", "group": group, "path": path]
        } else { return nil }
        id = "\(messageID):\(position)"
        self.messageID = messageID
        self.attachment = attachment
        self.source = CoreJSON(value: source)
        cacheKey = String(decoding: (try? JSONSerialization.data(withJSONObject: source, options: .sortedKeys)) ?? Data(), as: UTF8.self)
    }

    init?(message: ChatItem, file: ChatFile, position: Int, group: String, conversation: String) {
        guard let type = UTType(filenameExtension: (file.name as NSString).pathExtension),
              type.conforms(to: .image) || type.conforms(to: .movie) else { return nil }
        self.init(messageID: message.id, position: message.attachments.count + position,
                  attachment: ChatAttachment(blockType: type.conforms(to: .image) ? "image" : "file", index: nil, fileName: file.name, title: nil,
                                             mimeType: type.preferredMIMEType, size: nil, workspacePath: file.path, width: nil, height: nil,
                                             blob: nil, agentID: nil), group: group, conversation: conversation)
    }

    static func items(in rows: [ChatRow], group: String, conversation: String) -> [Self] {
        rows.flatMap { row in
            row.message.map { message in
                message.attachments.enumerated().compactMap {
                    Self(messageID: message.id, position: $0.offset, attachment: $0.element, group: group, conversation: conversation)
                } + message.files.enumerated().compactMap {
                    Self(message: message, file: $0.element, position: $0.offset, group: group, conversation: conversation)
                }
            } ?? []
        }
    }
}

/// At most three reads/decodes at once per open chat. Cancelled offscreen tiles leave the waiting queue.
actor ChatMediaReads {
    private var active = 0
    private var waiting: [(UUID, CheckedContinuation<Void, any Error>)] = []

    func acquire() async throws {
        try Task.checkCancellation()
        if active < 3 { active += 1; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in waiting.append((id, continuation)) }
        } onCancel: { Task { await self.cancel(id) } }
        // A cancellation can race the handoff of a slot.
        if Task.isCancelled { release(); throw CancellationError() }
    }

    func release() {
        if waiting.isEmpty { active -= 1 } else { waiting.removeFirst().1.resume() }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.0 == id }) else { return }
        waiting.remove(at: index).1.resume(throwing: CancellationError())
    }
}

enum ChatImageDecode {
    /// Image I/O downsamples before decoding and applies EXIF orientation; the original never decodes whole.
    @concurrent static func image(data: Data, maxPixel: Int) async throws -> UIImage {
        try Task.checkCancellation()
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        let source = CGImageSourceCreateWithData(data as CFData, options)
        guard let source, let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary) else {
            throw CoreError(code: "invalid_image", message: String(localized: "That photo couldn’t be read."))
        }
        try Task.checkCancellation()
        return UIImage(cgImage: image)
    }
}
