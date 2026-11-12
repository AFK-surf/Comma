import SwiftUI
import UIKit
import os

struct ChatMediaContext {
    let gallery: ChatMediaGallery
    let store: CommaStore
    let group: String
    let conversation: String

    func item(message: ChatItem, position: Int, attachment: ChatAttachment) -> ChatMediaItem? {
        ChatMediaItem(messageID: message.id, position: position, attachment: attachment, group: group, conversation: conversation)
    }
}

extension EnvironmentValues {
    @Entry var chatMedia: ChatMediaContext? = nil
}

/// Media presentation for one conversation and account. UIKit owns zoom and interactive dismissal.
@MainActor @Observable final class ChatMediaGallery {
    var returnMessageID: String?
    @ObservationIgnored var items: [ChatMediaItem] = []
    @ObservationIgnored var open: ((ChatMediaItem, UIImage?) -> Void)?
    @ObservationIgnored private var sources: [String: NSHashTable<UIImageView>] = [:]
    @ObservationIgnored private let thumbnails = NSCache<NSString, UIImage>()
    @ObservationIgnored private let fullImages = NSCache<NSString, UIImage>()
    @ObservationIgnored private let reads = ChatMediaReads()
    @ObservationIgnored private let videoReads = ChatMediaReads()
    @ObservationIgnored private var boundary: Int?
    private static let log = Logger(subsystem: "surf.comma.ios", category: "chat-media")

    init() {
        thumbnails.totalCostLimit = 24 * 1024 * 1024
        fullImages.totalCostLimit = 48 * 1024 * 1024
    }

    func register(_ view: UIImageView, id: String) {
        let views = sources[id] ?? NSHashTable.weakObjects()
        views.add(view)
        sources[id] = views
    }

    func unregister(_ view: UIImageView, id: String) {
        sources[id]?.remove(view)
        if sources[id]?.allObjects.isEmpty == true { sources[id] = nil }
    }

    func source(for id: String) -> UIImageView? {
        sources[id]?.allObjects.last { view in
            guard let window = view.window else { return false }
            var ancestor: UIView? = view
            while let current = ancestor {
                if current.isHidden || current.alpha < 0.01 { return false }
                ancestor = current.superview
            }
            return view.convert(view.bounds, to: window).intersects(window.bounds)
        }
    }

    func cached(_ item: ChatMediaItem, full: Bool) -> UIImage? {
        (full ? fullImages : thumbnails).object(forKey: item.cacheKey as NSString)
    }

    func video(_ item: ChatMediaItem, store: CommaStore) throws -> ChatVideoAsset {
        if boundary == nil { boundary = store.boundaryToken }
        guard boundary == store.boundaryToken, store.session != nil else { throw CancellationError() }
        let current = store.boundaryToken
        return ChatVideoAsset(core: store.core, source: item.source, mediaType: item.mediaType, reads: videoReads) { [weak store] in
            store?.isCurrent(current) == true && store?.session != nil
        }
    }

    /// Each visible tile or adjacent page has one deadline. There is no retry timer or per-item polling.
    func image(_ item: ChatMediaItem, full: Bool, store: CommaStore, timeout: Duration = .seconds(30)) async throws -> UIImage {
        do {
            return try await withThrowingTaskGroup(of: UIImage.self) { group in
                group.addTask { try await self.readImage(item, full: full, store: store) }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw CoreError(code: "preview_timeout", message: String(localized: "The preview took too long to load."))
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
        } catch {
            if !Task.isCancelled, !(error is CancellationError) {
                let code = (error as? CoreError)?.code ?? (error as NSError).domain
                let status = (error as? CoreError)?.status ?? (error as NSError).code
                Self.log.error("Media preview failed: video=\(item.isVideo), code=\(code, privacy: .public), status=\(status)")
            }
            throw error
        }
    }

    private func readImage(_ item: ChatMediaItem, full: Bool, store: CommaStore) async throws -> UIImage {
        if boundary == nil { boundary = store.boundaryToken }
        guard boundary == store.boundaryToken, store.session != nil else { throw CancellationError() }
        if let image = cached(item, full: full) { return image }
        let boundary = store.boundaryToken
        try await reads.acquire()
        do {
            try Task.checkCancellation()
            guard store.isCurrent(boundary), store.session != nil else { throw CancellationError() }
            if let image = cached(item, full: full) { await reads.release(); return image }
            let source = item.source.value as? [String: Any] ?? [:]
            let maxPixel = full ? 2_048 : 640
            let image: UIImage
            if item.isVideo {
                let video = try video(item, store: store)
                defer { video.close() }
                image = try await video.cover(maxPixel: maxPixel)
            } else {
                let answer = try await store.core.object("files.read", source)
                guard let data = CoreBytes.read(answer["bytes"]) else {
                    throw CoreError(code: "invalid_image", message: String(localized: "That photo couldn’t be read."))
                }
                image = try await ChatImageDecode.image(data: data, maxPixel: maxPixel)
            }
            try Task.checkCancellation()
            guard store.isCurrent(boundary) else { throw CancellationError() }
            let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
            (full ? fullImages : thumbnails).setObject(image, forKey: item.cacheKey as NSString, cost: cost)
            await reads.release()
            return image
        } catch {
            await reads.release()
            throw error
        }
    }
}

/// The design system's image attachment tile, with its source view retained weakly for the return transition.
struct ChatMediaThumbnail: View {
    let item: ChatMediaItem
    let context: ChatMediaContext
    let openFile: () -> Void
    @State private var image: UIImage?
    @State private var visible = false
    @State private var failed = false
    @State private var attempt = 0

    var body: some View {
        Group {
            Button {
                if item.isVideo || image != nil { context.gallery.open?(item, image) }
                // A tap on a loading tile leaves its read running.
                else if failed { if item.attachment.index != nil { openFile() } else { attempt += 1 } }
            } label: {
                ZStack {
                    CommaTheme.imagePlaceholder
                    ChatMediaSourceView(image: image, id: item.id, gallery: context.gallery)
                    if image == nil, failed {
                        VStack(spacing: CommaTheme.imageSpacing) {
                            CentralIcon(item.isVideo ? "central-play" : "central-file-bend", size: CommaTheme.mediaPlayIcon)
                            Text(item.attachment.name)
                                .font(.caption2)
                                .lineLimit(2)
                                .truncationMode(.tail)
                                .multilineTextAlignment(.center)
                        }
                        .foregroundStyle(CommaTheme.textSecondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(CommaTheme.imageSpacing)
                        .background(CommaTheme.bgSecondary)
                        .overlay(RoundedRectangle(cornerRadius: CommaTheme.imageRadius, style: .continuous)
                            .strokeBorder(CommaTheme.borderPrimary))
                    } else if item.isVideo {
                        CentralIcon("central-play", size: CommaTheme.mediaPlayIcon)
                            .foregroundStyle(CommaTheme.imageViewerForeground)
                            .frame(width: CommaTheme.imageViewerControl, height: CommaTheme.imageViewerControl)
                            .background(.ultraThinMaterial, in: Circle())
                            .environment(\.colorScheme, .dark)
                    } else if image == nil { ProgressView() }
                }
                .frame(width: CommaTheme.imageTileSide, height: CommaTheme.imageTileSide)
                .clipShape(RoundedRectangle(cornerRadius: CommaTheme.imageRadius, style: .continuous))
            }
            // The transition itself owns the source's scale; press scaling would change its starting frame.
            .buttonStyle(.plain)
            .accessibilityLabel(Text(item.attachment.name))
            .accessibilityHint(item.isVideo ? Text("Play video") : (failed ? (item.attachment.index != nil ? Text("Open file") : Text("Retry")) : Text("Open image")))
            .accessibilityIdentifier("chat-image-" + item.id)
            .accessibilityValue(image == nil ? (failed ? Text("Image unavailable") : Text("Loading image")) : Text("Image loaded"))
            .onScrollVisibilityChange(threshold: 0.01) { visible = $0 }
            .task(id: "\(visible):\(attempt)") {
                guard visible else { image = nil; return }
                failed = false
                do { image = try await context.gallery.image(item, full: false, store: context.store) }
                catch is CancellationError {} catch { if !Task.isCancelled { failed = true } }
            }
            .contextMenu {
                if image == nil { Button("Retry") { attempt += 1 } }
                if item.attachment.index != nil { Button("Open file", action: openFile) }
            }
        }
    }
}

private struct ChatMediaSourceView: UIViewRepresentable {
    let image: UIImage?
    let id: String
    let gallery: ChatMediaGallery

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleAspectFill
        view.clipsToBounds = true
        view.layer.cornerRadius = CommaTheme.imageRadius
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        gallery.register(view, id: id)
        return view
    }

    func updateUIView(_ view: UIImageView, context: Context) { view.image = image }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIImageView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? CommaTheme.imageTileSide, height: proposal.height ?? CommaTheme.imageTileSide)
    }
    func makeCoordinator() -> Coordinator { Coordinator(gallery: gallery, id: id) }
    static func dismantleUIView(_ view: UIImageView, coordinator: Coordinator) {
        coordinator.gallery.unregister(view, id: coordinator.id)
    }
    final class Coordinator {
        let gallery: ChatMediaGallery
        let id: String
        init(gallery: ChatMediaGallery, id: String) { self.gallery = gallery; self.id = id }
    }
}
