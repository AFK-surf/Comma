import AVFoundation
import UniformTypeIdentifiers
import UIKit

/// AVFoundation reads the existing authenticated Core file source, without exposing credentials or a server URL.
/// Each request transfers at most 1 MiB. A gallery permits three concurrent range reads across its video assets.
@MainActor final class ChatVideoAsset: NSObject, @preconcurrency AVAssetResourceLoaderDelegate {
    let asset: AVURLAsset
    private let core: any CoreAPI
    private let source: CoreJSON
    private let mediaType: String
    private let reads: ChatMediaReads
    private let isCurrent: @MainActor () -> Bool
    private var requests: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var closed = false
    private var coverGenerator: AVAssetImageGenerator?
    static let chunkSize = 1_048_576

    init(core: any CoreAPI, source: CoreJSON, mediaType: String, reads: ChatMediaReads,
         isCurrent: @escaping @MainActor () -> Bool) {
        self.core = core; self.source = source; self.mediaType = mediaType; self.reads = reads; self.isCurrent = isCurrent
        let ext = UTType(mimeType: mediaType)?.preferredFilenameExtension ?? "mp4"
        asset = AVURLAsset(url: URL(string: "comma-media://video/\(UUID().uuidString).\(ext)")!)
        super.init()
        asset.resourceLoader.setDelegate(self, queue: .main)
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        guard !closed, isCurrent() else {
            request.finishLoading(with: CancellationError())
            return true
        }
        let key = ObjectIdentifier(request)
        requests[key] = Task { [weak self] in
            guard let self else { return }
            do {
                try await serve(request)
                if !request.isCancelled { request.finishLoading() }
            } catch {
                if !request.isCancelled { request.finishLoading(with: error) }
            }
            requests[key] = nil
        }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
        requests.removeValue(forKey: ObjectIdentifier(request))?.cancel()
    }

    func close() {
        closed = true
        coverGenerator?.cancelAllCGImageGeneration()
        requests.values.forEach { $0.cancel() }
        requests.removeAll()
        asset.cancelLoading()
    }

    func cover(maxPixel: Int) async throws -> UIImage {
        guard !closed, isCurrent() else { throw CancellationError() }
        let generator = AVAssetImageGenerator(asset: asset)
        coverGenerator = generator
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        return try await withTaskCancellationHandler {
            // Keep the generator and cancellation on Main; AVFoundation decodes on its own queue.
            let image: UIImage = try await withCheckedThrowingContinuation { continuation in
                generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: .zero)]) { _, frame, _, result, error in
                    if result == .succeeded, let frame { continuation.resume(returning: UIImage(cgImage: frame)) }
                    else { continuation.resume(throwing: error ?? CoreError(code: "invalid_video", message: String(localized: "Could not load this video."))) }
                }
            }
            try Task.checkCancellation()
            return image
        } onCancel: { Task { @MainActor [weak self] in self?.close() } }
    }

    private func serve(_ request: AVAssetResourceLoadingRequest) async throws {
        let data = request.dataRequest
        var offset = max(data?.requestedOffset ?? 0, data?.currentOffset ?? 0)
        let end = (data?.requestedOffset ?? 0) + Int64(data?.requestedLength ?? 1)
        repeat {
            try Task.checkCancellation()
            guard !closed, isCurrent() else { throw CancellationError() }
            let remaining = data?.requestsAllDataToEndOfResource == true ? Int64(Self.chunkSize) : max(1, end - offset)
            let length = Int(min(Int64(Self.chunkSize), remaining))
            try await reads.acquire()
            let span: Span
            do {
                guard !closed, isCurrent() else { throw CancellationError() }
                span = try await Self.read(core: core, source: source, offset: offset, length: length)
                await reads.release()
            } catch { await reads.release(); throw error }
            try Task.checkCancellation()
            guard !closed, isCurrent(), !request.isCancelled else { throw CancellationError() }
            if let info = request.contentInformationRequest {
                info.contentType = UTType(mimeType: mediaType)?.identifier ?? UTType.movie.identifier
                info.contentLength = span.size
                info.isByteRangeAccessSupported = true
            }
            guard let data else { return }
            if span.data.isEmpty {
                if offset >= span.size { return }
                throw CoreError(code: "incomplete_video", message: String(localized: "Could not load this video."))
            }
            data.respond(with: span.data)
            offset += Int64(span.data.count)
            if offset >= span.size || (!data.requestsAllDataToEndOfResource && offset >= end) { return }
        } while !request.isCancelled
    }

    private struct Span: Sendable { let data: Data; let size: Int64 }

    @concurrent nonisolated private static func read(core: any CoreAPI, source: CoreJSON, offset: Int64, length: Int) async throws -> Span {
        let answer = try await core.object("files.readRange", ["source": source.value ?? [:], "offset": offset, "length": length])
        guard let bytes = CoreBytes.read(answer["bytes"]), let size = answer["size"] as? NSNumber else {
            throw CoreError(code: "invalid_video", message: String(localized: "Could not load this video."))
        }
        return Span(data: bytes, size: size.int64Value)
    }
}
