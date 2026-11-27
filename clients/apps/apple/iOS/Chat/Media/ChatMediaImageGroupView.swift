import SwiftUI
import UIKit

/// Lightweight test/demo handle to trigger the same interactive actions as taps on the view's controls.
@MainActor final class ChatMediaImageGroupDriver {
    var rotate: ((Int) -> Void)?
    var toggleExpanded: (() -> Void)?
    var openFront: (() -> Void)?
}

/// Fan-Stack Card Deck image group, 1:1 with Web `ChatPanelImageGroup`.
/// - 1 image: natural aspect ratio inside `(singleMaxWidth, 320pt)`, no fan allowance.
/// - 2...3 images: plain horizontal row (`3:4` cards, `8pt` gap), no toggle pill.
/// - 4+ images: collapsed rotated card fan with `N Images` / `Hide` pill, edge chevrons,
///   horizontal swipe, 320ms throw arc with layer swap at 0.6, and 240ms staggered expand/collapse.
struct ChatMediaImageGroupView: View {
    let messageID: String
    let items: [ChatMediaItem]
    let context: ChatMediaContext
    let isUser: Bool
    let availableWidth: CGFloat
    var driver: ChatMediaImageGroupDriver?
    var openAttachment: ((ChatAttachment) -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded: Bool
    @State private var browseState = ChatMediaImageGroupBrowseState()
    @State private var imagesByID: [String: UIImage] = [:]
    @State private var failedIDs: Set<String> = []
    @State private var retryAttempts: [String: Int] = [:]
    @State private var scrollVisible = true

    // 320ms throw-card flight state
    private enum FlightPhase: Equatable {
        case apex(side: CGFloat)
        case settling
    }
    @State private var flyingIndex: Int?
    @State private var flightPhase: FlightPhase?
    @State private var flightAboveFront = false
    @State private var flightGeneration = 0
    @State private var flightTask: Task<Void, Never>?

    init(
        messageID: String,
        items: [ChatMediaItem],
        context: ChatMediaContext,
        isUser: Bool,
        availableWidth: CGFloat,
        defaultExpanded: Bool = false,
        driver: ChatMediaImageGroupDriver? = nil,
        openAttachment: ((ChatAttachment) -> Void)? = nil
    ) {
        self.messageID = messageID
        self.items = items
        self.context = context
        self.isUser = isUser
        self.availableWidth = availableWidth
        self.driver = driver
        self.openAttachment = openAttachment
        _expanded = State(initialValue: defaultExpanded)
    }

    private var stackable: Bool {
        ChatMediaImageGroupLayout.isStackable(count: items.count)
    }

    private var isExpanded: Bool {
        stackable ? expanded : true
    }

    var body: some View {
        if items.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                if stackable {
                    togglePill
                }
                if items.count == 1 {
                    singleImageView(items[0])
                } else {
                    deckOrGridView
                }
            }
            .onScrollVisibilityChange(threshold: 0.01) { visible in
                scrollVisible = visible
            }
            .onAppear {
                seedCachedImages()
                bindDriver()
                context.gallery.registerViewerSync(messageID: messageID) { itemID in
                    guard let idx = items.firstIndex(where: { $0.id == itemID }) else { return }
                    browseState.alignPreview(index: idx, count: items.count)
                }
            }
            .onDisappear {
                flightTask?.cancel()
                context.gallery.unregisterViewerSync(messageID: messageID)
            }
        }
    }

    // MARK: - Toggle Pill

    private var togglePill: some View {
        Button {
            toggleExpanded()
        } label: {
            ZStack {
                Text("\(items.count) Images")
                    .opacity(isExpanded ? 0 : 1)
                    .scaleEffect(isExpanded ? 0.96 : 1)
                Text("Hide")
                    .opacity(isExpanded ? 1 : 0)
                    .scaleEffect(isExpanded ? 1 : 0.96)
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(CommaTheme.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(CommaTheme.bgQuaternary, in: Capsule())
            .animation(reduceMotion ? nil : CommaMotion.stateChange, value: isExpanded)
        }
        .buttonStyle(TactileButtonStyle(scale: 0.96))
        .accessibilityLabel(isExpanded ? Text("Hide") : Text("\(items.count) Images"))
        .accessibilityIdentifier("chat-image-group-toggle-\(messageID)")
    }

    // MARK: - Single Image (count == 1)

    private func singleImageView(_ item: ChatMediaItem) -> some View {
        let loaded = resolvedImage(for: item)
        let aspectW: CGFloat? = loaded.map(\.size.width) ?? item.attachment.width.map { CGFloat($0) }
        let aspectH: CGFloat? = loaded.map(\.size.height) ?? item.attachment.height.map { CGFloat($0) }
        let size = ChatMediaImageGroupLayout.singleSize(
            aspectWidth: aspectW,
            aspectHeight: aspectH,
            availableWidth: availableWidth
        )
        return cardButton(
            item: item,
            index: 0,
            size: size,
            interactive: true,
            registerSource: true,
            shouldLoad: true,
            dimOpacity: 0,
            hasShadow: false
        )
    }

    // MARK: - Multi-Image Deck & Expanded Grid

    private var deckOrGridView: some View {
        let count = items.count
        let deckCardSize = ChatMediaImageGroupLayout.collapsedDeckCardSize()
        let deckContainerSize = ChatMediaImageGroupLayout.collapsedDeckContainerSize()
        let grid = ChatMediaImageGroupLayout.expandedGrid(
            count: count,
            availableWidth: availableWidth,
            isUser: isUser
        )
        let containerSize = isExpanded ? grid.containerSize : deckContainerSize

        let deckCenterX = CommaTheme.imageGroupFanAllowanceHorizontal + deckCardSize.width / 2
        let deckCenterY = CommaTheme.imageGroupFanAllowanceVertical + deckCardSize.height / 2

        return ZStack(alignment: .topLeading) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                let slot = browseState.slot(for: index, count: count)
                let slotGeo = slot.geometry
                let gridFrame = index < grid.frames.count ? grid.frames[index] : CGRect(origin: .zero, size: deckCardSize)

                let isFlying = !isExpanded && flyingIndex == index
                let activeTx: CGFloat = {
                    if isExpanded { return 0 }
                    if isFlying, case .apex(let side) = flightPhase {
                        return round(deckCardSize.width * ChatMediaImageGroupLayout.flightApexWidthFactor * side)
                    }
                    return slotGeo.translateX
                }()
                let activeRot: Double = {
                    if isExpanded { return 0 }
                    if isFlying, case .apex(let side) = flightPhase {
                        return ChatMediaImageGroupLayout.flightApexRotationDegrees * Double(side)
                    }
                    return slotGeo.rotationDegrees
                }()
                let activeScale: CGFloat = {
                    if isExpanded { return 1.0 }
                    if isFlying, case .apex = flightPhase {
                        return ChatMediaImageGroupLayout.flightApexScale
                    }
                    return slotGeo.scale
                }()
                let activeOpacity: Double = {
                    if isExpanded { return 1.0 }
                    if isFlying, case .apex = flightPhase { return 1.0 }
                    return slotGeo.opacity
                }()
                let activeDim: Double = {
                    if isExpanded { return 0 }
                    if isFlying, case .apex = flightPhase { return 0 }
                    return slotGeo.dimOpacity
                }()
                let activeZIndex: Double = {
                    if isExpanded { return Double(index) }
                    if isFlying && flightAboveFront { return 6 }
                    return slotGeo.zIndex
                }()

                let cardSize = isExpanded ? gridFrame.size : deckCardSize
                let cardCenterX = isExpanded ? gridFrame.midX : (deckCenterX + activeTx)
                let cardCenterY = isExpanded ? gridFrame.midY : deckCenterY

                let interactive = isExpanded || slot == .front
                let shouldLoad = isExpanded || slot.isVisible || isFlying
                let registerSource = isExpanded || slot.isVisible || isFlying
                let delay = browseState.staggerDelay(for: index, count: count, expanding: isExpanded)

                cardButton(
                    item: item,
                    index: index,
                    size: cardSize,
                    interactive: interactive,
                    registerSource: registerSource,
                    shouldLoad: shouldLoad,
                    dimOpacity: activeDim,
                    hasShadow: !isExpanded
                )
                .scaleEffect(activeScale)
                .rotationEffect(.degrees(activeRot))
                .opacity(activeOpacity)
                .position(x: cardCenterX, y: cardCenterY)
                .zIndex(activeZIndex)
                .allowsHitTesting(interactive)
                .accessibilityHidden(!interactive)
                .animation(
                    reduceMotion ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: CommaTheme.imageGroupFlipDuration).delay(delay),
                    value: isExpanded
                )
            }

            if stackable && !isExpanded {
                chevronButton(side: .leading) {
                    rotate(1)
                }
                .position(x: CommaTheme.imageGroupFanAllowanceHorizontal, y: deckCenterY)
                .zIndex(7)
                .accessibilityLabel(Text("Next image"))
                .accessibilityIdentifier("chat-image-group-prev-\(messageID)")

                chevronButton(side: .trailing) {
                    rotate(-1)
                }
                .position(x: CommaTheme.imageGroupFanAllowanceHorizontal + deckCardSize.width, y: deckCenterY)
                .zIndex(7)
                .accessibilityLabel(Text("Previous image"))
                .accessibilityIdentifier("chat-image-group-next-\(messageID)")
            }
        }
        .frame(width: containerSize.width, height: containerSize.height, alignment: .topLeading)
        .animation(
            reduceMotion ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: CommaTheme.imageGroupFlipDuration),
            value: isExpanded
        )
        .simultaneousGesture(deckSwipeGesture)
    }

    private enum ChevronSide { case leading, trailing }

    private func chevronButton(side: ChevronSide, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            CentralIcon("central-chevron-right-small", size: 16)
                .rotationEffect(.degrees(side == .leading ? 180 : 0))
                .foregroundStyle(CommaTheme.textSecondary)
                .frame(width: 32, height: 32)
                .background(CommaTheme.cardPrimary, in: Circle())
                .overlay(Circle().strokeBorder(CommaTheme.borderPrimary, lineWidth: 0.5))
                .shadow(color: Color.black.opacity(0.12), radius: 4, x: 0, y: 2)
        }
        .buttonStyle(TactileButtonStyle(scale: 0.94))
    }

    private var deckSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onEnded { value in
                guard stackable && !isExpanded else { return }
                let dx = value.translation.width
                let dy = value.translation.height
                guard abs(dx) > abs(dy), abs(dx) >= 28 else { return }
                rotate(dx < 0 ? 1 : -1)
            }
    }

    // MARK: - Card Cell

    private func cardButton(
        item: ChatMediaItem,
        index: Int,
        size: CGSize,
        interactive: Bool,
        registerSource: Bool,
        shouldLoad: Bool,
        dimOpacity: Double,
        hasShadow: Bool
    ) -> some View {
        let image = resolvedImage(for: item)
        let failed = failedIDs.contains(item.id)
        let attempt = retryAttempts[item.id, default: 0]
        let radius = CommaTheme.imageGroupCardRadius

        return Button {
            if item.isVideo || image != nil {
                browseState.alignPreview(index: index, count: items.count)
                context.gallery.open?(item, image)
            } else if failed {
                if item.attachment.index != nil, let openAttachment {
                    openAttachment(item.attachment)
                } else {
                    retryAttempts[item.id, default: 0] += 1
                }
            }
        } label: {
            ZStack {
                CommaTheme.imagePlaceholder
                ChatMediaSourceView(
                    image: image,
                    id: item.id,
                    gallery: context.gallery,
                    cornerRadius: radius,
                    registerSource: registerSource
                )
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
                } else if item.isVideo {
                    CentralIcon("central-play", size: CommaTheme.mediaPlayIcon)
                        .foregroundStyle(CommaTheme.imageViewerForeground)
                        .frame(width: CommaTheme.imageViewerControl, height: CommaTheme.imageViewerControl)
                        .background(.ultraThinMaterial, in: Circle())
                        .environment(\.colorScheme, .dark)
                } else if image == nil {
                    ProgressView()
                }
                if dimOpacity > 0 {
                    Color.black.opacity(dimOpacity)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(CommaTheme.borderPrimary, lineWidth: 0.5)
            )
            .shadow(color: hasShadow ? Color.black.opacity(0.10) : .clear, radius: hasShadow ? 4 : 0, x: 0, y: hasShadow ? 2 : 0)
        }
        // Keep .plain so UIKit .zoom transition reads the exact frame without press scale distortion.
        .buttonStyle(.plain)
        .disabled(!interactive)
        .accessibilityLabel(Text(item.attachment.name))
        .accessibilityHint(item.isVideo ? Text("Play video") : (failed ? (item.attachment.index != nil ? Text("Open file") : Text("Retry")) : Text("Open image")))
        .accessibilityIdentifier("chat-image-\(item.id)")
        .accessibilityValue(image == nil ? (failed ? Text("Image unavailable") : Text("Loading image")) : Text("Image loaded"))
        .task(id: "\(item.id):\(shouldLoad):\(scrollVisible):\(attempt)") {
            guard shouldLoad && scrollVisible else { return }
            if let cached = context.gallery.cached(item, full: false) {
                imagesByID[item.id] = cached
                failedIDs.remove(item.id)
                return
            }
            failedIDs.remove(item.id)
            do {
                let loaded = try await context.gallery.image(item, full: false, store: context.store)
                imagesByID[item.id] = loaded
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { failedIDs.insert(item.id) }
            }
        }
        .contextMenu {
            if image == nil {
                Button("Retry") { retryAttempts[item.id, default: 0] += 1 }
            }
            if item.attachment.index != nil, let openAttachment {
                Button("Open file") { openAttachment(item.attachment) }
            }
        }
    }

    // MARK: - Actions

    private func resolvedImage(for item: ChatMediaItem) -> UIImage? {
        imagesByID[item.id] ?? context.gallery.cached(item, full: false)
    }

    private func seedCachedImages() {
        for item in items {
            if let cached = context.gallery.cached(item, full: false) {
                imagesByID[item.id] = cached
            }
        }
    }

    private func bindDriver() {
        guard let driver else { return }
        driver.rotate = { step in rotate(step) }
        driver.toggleExpanded = { toggleExpanded() }
        driver.openFront = {
            guard !items.isEmpty else { return }
            let idx = browseState.normalizedFront(count: items.count)
            let item = items[idx]
            browseState.alignPreview(index: idx, count: items.count)
            context.gallery.open?(item, resolvedImage(for: item))
        }
    }

    private func retireActiveFlights() {
        flightTask?.cancel()
        flightTask = nil
        flightGeneration += 1
        flyingIndex = nil
        flightPhase = nil
        flightAboveFront = false
    }

    private func toggleExpanded() {
        retireActiveFlights()
        expanded.toggle()
    }

    private func rotate(_ step: Int) {
        let count = items.count
        guard count > 1 else { return }
        flightTask?.cancel()
        flightGeneration += 1
        let generation = flightGeneration
        let outgoingIndex = browseState.normalizedFront(count: count)
        let side: CGFloat = step >= 0 ? -1 : 1

        if reduceMotion {
            flyingIndex = nil
            flightPhase = nil
            flightAboveFront = false
            browseState.rotate(step: step, count: count)
            return
        }

        flyingIndex = outgoingIndex
        flightAboveFront = true
        flightPhase = nil

        withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.200)) {
            browseState.rotate(step: step, count: count)
        }

        let total = CommaTheme.imageGroupFlightDuration
        let apexDuration = total * ChatMediaImageGroupLayout.flightApexOffset
        let settleDuration = total * (1.0 - ChatMediaImageGroupLayout.flightApexOffset)
        let swapDelay = total * (ChatMediaImageGroupLayout.flightLayerSwapOffset - ChatMediaImageGroupLayout.flightApexOffset)

        withAnimation(.timingCurve(0.32, 0.72, 0, 1, duration: apexDuration)) {
            flightPhase = .apex(side: side)
        }

        flightTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Int(round(apexDuration * 1000))))
            guard !Task.isCancelled, flightGeneration == generation else { return }

            withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: settleDuration)) {
                flightPhase = .settling
            }

            try? await Task.sleep(for: .milliseconds(Int(round(swapDelay * 1000))))
            guard !Task.isCancelled, flightGeneration == generation else { return }
            flightAboveFront = false

            let remaining = max(0, settleDuration - swapDelay)
            try? await Task.sleep(for: .milliseconds(Int(round(remaining * 1000))))
            guard !Task.isCancelled, flightGeneration == generation else { return }
            flyingIndex = nil
            flightPhase = nil
        }
    }
}
