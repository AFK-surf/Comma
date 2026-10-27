import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import ImageIO
import CommaCore

/// Attachments in and out of the conversation: the camera, the photo panel, the system photo picker and Files
/// hand their picks to the pane, which shows each in the composer at once and uploads them side by side; a
/// message's attachment opens in Quick Look.
extension PhoneConversationView {
    var attachmentActions: AttachmentActions {
        AttachmentActions(openFiles: { filePickerOpen = true }, openAllPhotos: { allPhotosOpen = true },
                          attach: { await attach($0) })
    }

    /// Photos from the system picker, each attached as soon as it has loaded.
    func uploadPhotos(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        defer { photos = [] }
        preparing = true
        defer { preparing = false }
        for item in items.prefix(pane.attachmentRoom) {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                await attach(AttachmentImage(data: data, type: item.supportedContentTypes.first ?? .jpeg))
            } catch { pane.showError(error.localizedDescription) }
        }
    }

    /// Camera captures, library photos and system-picker photos all attach through here.
    func attach(_ images: [AttachmentImage]) async {
        // Send waits for the whole batch: a photo still being redrawn has no draft yet to hold it back.
        preparing = true
        defer { preparing = false }
        let room = pane.attachmentRoom
        for image in images.prefix(room) { await attach(image) }
        if images.count > room { pane.showError(String(localized: "You can attach up to eight files to a message.")) }
    }

    private func attach(_ image: AttachmentImage) async {
        do {
            let photo = try await AttachmentFile.photo(image)
            pane.attach(photo.file, thumbnail: photo.thumbnail)
        } catch { pane.showError(error.localizedDescription) }
    }

    /// Files from Files: an image is read and attached as a photo is; any other file waits on disk and uploads from
    /// there as it is read, of any size the server takes.
    func uploadFiles(_ result: Result<[URL], any Error>) async {
        preparing = true
        defer { preparing = false }
        do {
            for url in try result.get().prefix(pane.attachmentRoom) {
                if let localFiles = store.localFiles, !AttachmentFile.isImage(url) {
                    guard let kept = try await localFiles.keep(url) else {
                        pane.showError(String(localized: "Choose a file smaller than 512 MB."))
                        continue
                    }
                    pane.attachLocalFile(ref: kept.ref, name: kept.name, size: kept.size,
                                         mediaType: AttachmentFile.mediaType(url))
                    continue
                }
                guard let file = try await AttachmentFile.read(url) else {
                    pane.showError(String(localized: "Choose a file smaller than 10 MB."))
                    continue
                }
                pane.attach(file.payload, thumbnail: file.thumbnail)
            }
        } catch { pane.showError(error.localizedDescription) }
    }

    /// Downloads the attachment to the device, of any size, and opens the kept file in Quick Look.
    func download(messageID: String, index: Int, name: String) async {
        guard let target = pane.target, !downloading, previewURL == nil else { return }
        let sessionID = store.session?.id
        downloading = true
        defer { downloading = false }
        do {
            let path = try await AttachmentDownload.path(
                core: store.core,
                source: ["source": "attachment", "group": target.groupID, "conversation": target.conversationID,
                         "message": messageID, "index": index],
                name: name)
            // The conversation or account may have changed while the file arrived.
            guard pane.target == target, store.session?.id == sessionID, sessionID != nil,
                  let file = store.downloadedFile(path) else { return }
            previewURL = file
        } catch is CancellationError {
        } catch { pane.showError(error.localizedDescription) }
    }
}

/// File work for attachments, off the main actor: a picked file can be large, or still on its way from iCloud.
enum AttachmentFile {
    struct Picked: Sendable {
        let payload: AttachmentPayload
        let thumbnail: Data?
    }

    static let maxSize = 10_000_000

    /// Whether the file is an image, by its name's type.
    static func isImage(_ url: URL) -> Bool { UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true }

    /// The file's media type, by its name's type.
    static func mediaType(_ url: URL) -> String {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    /// The file's name, type and contents, with a thumbnail when it is an image; nil when it is not a regular file
    /// of at most 10 MB.
    @concurrent static func read(_ url: URL) async throws -> Picked? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey, .isRegularFileKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) <= maxSize else { return nil }
        // Coordinated, so a file still downloading from iCloud is read once it has arrived.
        var read: Result<Data, any Error> = .failure(CocoaError(.fileReadUnknown))
        var coordination: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordination) { url in
            read = Result { try Data(contentsOf: url) }
        }
        if let coordination { throw coordination }
        let data = try read.get()
        let type = values.contentType?.preferredMIMEType ?? "application/octet-stream"
        return Picked(payload: AttachmentPayload(filename: url.lastPathComponent, contentType: type, data: data),
                      thumbnail: type.hasPrefix("image/") ? AttachmentPhoto.thumbnail(data) : nil)
    }

    /// A photo as it is sent: kept as it is when it is a JPEG, PNG or GIF of a sensible size, else (HEIC, or a
    /// very large photo) redrawn upright as a JPEG at most 2,048 pixels on its longer side, which models read
    /// as well and which uploads in a fraction of the time.
    @concurrent static func photo(_ image: AttachmentImage) async throws -> (file: AttachmentPayload, thumbnail: Data?) {
        let kept: [UTType] = [.jpeg, .png, .gif]
        if kept.contains(image.type), image.data.count <= 4_000_000,
           AttachmentPhoto.longestSide(image.data) ?? .max <= 4_096 {
            let name = "Photo." + (image.type.preferredFilenameExtension ?? "jpg")
            return (AttachmentPayload(filename: name, contentType: image.type.preferredMIMEType ?? "image/jpeg",
                                      data: image.data), AttachmentPhoto.thumbnail(image.data))
        }
        guard let jpeg = AttachmentPhoto.jpeg(image.data, maxSide: 2_048, quality: 0.85), jpeg.count <= maxSize else {
            throw CommaError.invalidInput(String(localized: "That photo couldn’t be read."))
        }
        return (AttachmentPayload(filename: "Photo.jpg", contentType: "image/jpeg", data: jpeg),
                AttachmentPhoto.thumbnail(jpeg))
    }
}

/// Image work for attachments, through Image I/O so a 48-megapixel photo never decodes whole.
enum AttachmentPhoto {
    static func longestSide(_ data: Data) -> Int? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return max(width, height)
    }

    /// The image upright, at most `maxSide` pixels on its longer side, as a JPEG.
    static func jpeg(_ data: Data, maxSide: Int, quality: CGFloat) -> Data? {
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                       kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: maxSide] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: image).jpegData(compressionQuality: quality)
    }

    /// A tile's picture: 192 pixels, three times the tile's 64 points.
    static func thumbnail(_ data: Data) -> Data? { jpeg(data, maxSide: 192, quality: 0.7) }
}
