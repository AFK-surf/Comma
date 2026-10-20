import Photos
import UIKit
import UniformTypeIdentifiers

/// Recent photos for the attachment panel. Access is asked for when the panel first opens; without
/// it, All Photos still works through the system picker, which needs no access.
@MainActor @Observable final class PhotoLibraryModel {
    enum Access: Equatable { case asking, allowed, denied }

    private(set) var access = Access.asking
    private(set) var assets: [PHAsset] = []
    /// The panel shows recent photos; All Photos reaches older ones.
    static let recentLimit = 300

    func load() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { access = .denied; return }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = Self.recentLimit
        let result = PHAsset.fetchAssets(with: .image, options: options)
        assets = result.objects(at: IndexSet(integersIn: 0..<result.count))
        access = .allowed
    }

    /// Every grid thumbnail comes from one caching manager.
    private static let thumbnails = PHCachingImageManager()

    /// A square thumbnail of `side` points. A photo kept only in iCloud at that size downloads; otherwise its
    /// cell would stay blank. High-quality delivery answers once, so it fits a continuation; a cell scrolled
    /// away cancels it, download included.
    static func thumbnail(_ asset: PHAsset, side: CGFloat, scale: CGFloat) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        let size = CGSize(width: side * scale, height: side * scale)
        let request = ThumbnailRequest(manager: thumbnails)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                request.start(continuation) { request in
                    thumbnails.requestImage(for: asset, targetSize: size, contentMode: .aspectFill, options: options) {
                        @Sendable image, _ in request.finish(image)
                    }
                }
            }
        } onCancel: {
            request.cancel()
        }
    }

    /// The photo's original data, as the system picker would hand it over.
    static func image(_ asset: PHAsset) async -> AttachmentImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, uti, _, _ in
                let type = uti.flatMap { UTType($0) } ?? .jpeg
                continuation.resume(returning: data.map { AttachmentImage(data: $0, type: type) })
            }
        }
    }
}

/// One thumbnail request that answers exactly once: with its image, or with nil as soon as its task is
/// cancelled, which also cancels the request in Photos.
private final class ThumbnailRequest: @unchecked Sendable {
    private let manager: PHImageManager
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UIImage?, Never>?
    private var id: PHImageRequestID?
    private var cancelled = false

    init(manager: PHImageManager) { self.manager = manager }

    func start(_ continuation: CheckedContinuation<UIImage?, Never>, request: (ThumbnailRequest) -> PHImageRequestID) {
        guard lock.withLock({ () -> Bool in
            if !cancelled { self.continuation = continuation }
            return !cancelled
        }) else { return continuation.resume(returning: nil) }
        let id = request(self)
        if lock.withLock({ self.id = id; return cancelled }) { manager.cancelImageRequest(id) }
    }

    func finish(_ image: UIImage?) { take()?.resume(returning: image) }

    func cancel() {
        if let id = lock.withLock({ cancelled = true; return self.id }) { manager.cancelImageRequest(id) }
        take()?.resume(returning: nil)
    }

    private func take() -> CheckedContinuation<UIImage?, Never>? {
        lock.withLock {
            defer { continuation = nil }
            return continuation
        }
    }
}
