import Foundation
import CommaCore

/// A file or photo on its way into the next message. It shows in the composer the moment it is picked, uploads
/// beside the others, and is sent once ready; a failed upload keeps its file for a retry.
struct DraftAttachment: Identifiable, Equatable {
    enum State: Equatable {
        case uploading
        case failed(String)
        case ready(ContentBlock)
    }

    let id = UUID()
    let file: AttachmentPayload
    /// A small JPEG for a photo's tile.
    let thumbnail: Data?
    var state: State = .uploading

    var isImage: Bool { file.contentType.hasPrefix("image/") }
    var block: ContentBlock? { if case .ready(let block) = state { block } else { nil } }
}

/// What is uploaded: the file's name, type and contents.
struct AttachmentPayload: Equatable, Sendable {
    let filename: String
    let contentType: String
    let data: Data
}

extension ConversationPane {
    static let maxAttachments = 8

    /// The uploaded attachments, in the order they were picked, as the next message sends them.
    var attachments: [ContentBlock] { drafts.compactMap(\.block) }
    /// An upload is still on its way, or failed and waits to be retried or removed; the message waits for it.
    var attachmentsBlockSend: Bool { drafts.contains { $0.block == nil } }
    var attachmentRoom: Int { max(0, Self.maxAttachments - drafts.count) }

    /// Adds `file` to the next message at once and uploads it.
    func attach(_ file: AttachmentPayload, thumbnail: Data?) {
        guard target != nil else { return }
        guard attachmentRoom > 0 else {
            return showError(String(localized: "You can attach up to eight files to a message."))
        }
        let draft = DraftAttachment(file: file, thumbnail: thumbnail)
        drafts.append(draft)
        upload(draft.id)
    }

    func retryAttachment(_ id: UUID) {
        guard let index = drafts.firstIndex(where: { $0.id == id }), case .failed = drafts[index].state else { return }
        drafts[index].state = .uploading
        upload(id)
    }

    func removeAttachment(_ id: UUID) {
        drafts.removeAll { $0.id == id }
    }

    private func upload(_ id: UUID) {
        guard let store, let target, let file = drafts.first(where: { $0.id == id })?.file else { return }
        let token = fence
        let workspace = workspace
        Task { [weak self] in
            let result: DraftAttachment.State
            do {
                result = .ready(try await store.client.uploadFile(workspace: workspace, filename: file.filename,
                                                                  contentType: file.contentType, data: file.data))
            } catch {
                result = .failed(error.localizedDescription)
            }
            // A removed attachment, a closed pane or another conversation drops the answer.
            guard let self, self.isLive(token), self.target == target,
                  let index = self.drafts.firstIndex(where: { $0.id == id }) else { return }
            self.drafts[index].state = result
        }
    }
}
