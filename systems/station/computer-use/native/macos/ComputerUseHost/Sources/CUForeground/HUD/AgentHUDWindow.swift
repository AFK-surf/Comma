import AppKit
import CUShared
import QuartzCore

@MainActor
final class AgentHUDWindow: NSObject {
    private enum AnchorMode {
        case pointer
        case fixed(CGPoint)
    }

    enum VisualStyle {
        case agentOperating
        case observing

        var bubbleFillColor: NSColor {
            switch self {
            case .agentOperating:
                NSColor(
                    calibratedRed: 0.0,
                    green: 119.0 / 255.0,
                    blue: 1.0,
                    alpha: 1.0
                )
            case .observing:
                NSColor(
                    calibratedRed: 153.0 / 255.0,
                    green: 52.0 / 255.0,
                    blue: 208.0 / 255.0,
                    alpha: 1.0
                )
            }
        }
    }

    private enum BubblePlacement: Int, CaseIterable {
        case aboveRight
        case aboveLeft
        case belowRight
        case belowLeft

        var priority: Int {
            rawValue
        }

        func offset(for windowSize: NSSize, xGap: CGFloat, yGap: CGFloat) -> CGPoint {
            switch self {
            case .aboveRight:
                CGPoint(x: xGap, y: -windowSize.height - yGap)
            case .aboveLeft:
                CGPoint(x: -windowSize.width - xGap, y: -windowSize.height - yGap)
            case .belowRight:
                CGPoint(x: xGap, y: yGap)
            case .belowLeft:
                CGPoint(x: -windowSize.width - xGap, y: yGap)
            }
        }
    }

    private struct OffsetAnimation {
        let from: CGPoint
        let to: CGPoint
        let startTime: CFTimeInterval
        let duration: CFTimeInterval
    }

    private var window: NSWindow?
    private var textField: NSTextField?
    private var bubbleView: NSView?
    private var displayLinkWrapper: HUDDisplayLinkWrapper?
    private var currentText = ""
    private var currentPlacement: BubblePlacement?
    private var animatedOffset: CGPoint?
    private var offsetAnimation: OffsetAnimation?
    private var anchorMode: AnchorMode = .pointer
    private var visualStyle: VisualStyle = .agentOperating

    var overlayWindow: NSWindow? {
        window
    }

    private let defaultAlpha: CGFloat = 1.0
    private let bubbleCornerRadius: CGFloat = 12
    private let maxBubbleWidth: CGFloat = 320
    private let minBubbleHeight: CGFloat = 24
    private let maxTextLines: CGFloat = 6
    private let textFont = NSFont.systemFont(ofSize: 14, weight: .regular)
    private let horizontalPadding: CGFloat = 8
    private let verticalPadding: CGFloat = 4
    private let textWidthSlack: CGFloat = 6
    private let screenInset: CGFloat = 18
    private let cursorOffsetX: CGFloat = 16
    private let cursorOffsetY: CGFloat = 16
    private let cursorKeepoutRadius: CGFloat = 72
    private let offsetAnimationDuration: CFTimeInterval = 0.3

    func show(text: String, anchoredAt point: CGPoint? = nil, style: VisualStyle = .agentOperating) {
        if window == nil {
            createWindow()
        }

        currentText = text
        anchorMode = point.map { .fixed($0) } ?? .pointer
        visualStyle = style
        layoutBubble(for: text)
        window?.ignoresMouseEvents = true
        startFollowingCursor()
        refreshWindowFrame(display: true)
        window?.orderFront(nil)
        commitVisualState()
        textField?.layer?.add(fadeOutInAnimation(), forKey: "fade")
    }

    func updateText(_ text: String) {
        guard window != nil else {
            show(text: text)
            return
        }

        currentText = text
        layoutBubble(for: text)
        refreshWindowFrame(display: true)
        commitVisualState()
    }

    func hide() {
        stopFollowingCursor()
        anchorMode = .pointer
        currentPlacement = nil
        animatedOffset = nil
        offsetAnimation = nil
        window?.orderOut(nil)
    }

    /// Pull the bubble back onto the current anchor point immediately,
    /// without waiting for the CVDisplayLink tick. Foreground mode
    /// calls this from `DaemonCursor.onPoseApplied` so the bubble
    /// updates on the same main-actor turn as the sprite — otherwise
    /// `Task { @MainActor }` dispatches from the display-link callback
    /// can pile up during the bezier pump and the bubble visibly lags
    /// behind the agent cursor.
    func nudge() {
        guard window?.isVisible == true else { return }
        refreshWindowFrame(display: false)
    }

    private func createWindow() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: horizontalPadding * 2 + 1, height: minBubbleHeight),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        w.level = .screenSaver
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.alphaValue = defaultAlpha
        w.ignoresMouseEvents = true

        let bubbleView = NSView(frame: w.contentView!.bounds)
        bubbleView.autoresizingMask = [.width, .height]
        bubbleView.wantsLayer = true
        bubbleView.layer?.cornerRadius = bubbleCornerRadius
        bubbleView.layer?.masksToBounds = true
        bubbleView.layer?.backgroundColor = visualStyle.bubbleFillColor.cgColor

        let tf = NSTextField(frame: .zero)
        tf.isBezeled = false
        tf.drawsBackground = false
        tf.isEditable = false
        tf.isSelectable = false
        tf.alignment = .left
        tf.font = textFont
        tf.textColor = .white.withAlphaComponent(0.96)
        tf.stringValue = ""
        tf.wantsLayer = true
        tf.lineBreakMode = .byWordWrapping
        tf.maximumNumberOfLines = Int(maxTextLines)
        tf.usesSingleLineMode = false
        tf.cell?.wraps = true
        tf.cell?.lineBreakMode = .byWordWrapping
        tf.cell?.truncatesLastVisibleLine = true

        bubbleView.addSubview(tf)
        textField = tf

        w.contentView = bubbleView
        window = w
        self.bubbleView = bubbleView

        layoutBubble(for: currentText)
    }

    private func fadeOutInAnimation() -> CAAnimation {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0.5
        animation.toValue = 1.0
        animation.duration = 0.3
        return animation
    }

    private func startFollowingCursor() {
        guard displayLinkWrapper == nil else { return }

        let wrapper = HUDDisplayLinkWrapper()
        wrapper.start { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, window?.isVisible == true else { return }
                refreshWindowFrame(display: false)
            }
        }
        displayLinkWrapper = wrapper
    }

    private func stopFollowingCursor() {
        displayLinkWrapper?.stop()
        displayLinkWrapper = nil
    }

    private func refreshWindowFrame(display: Bool) {
        guard let window else { return }
        let anchorPoint = currentAnchorPoint()
        guard let screen = DesktopCoordinateSpace.screen(containing: anchorPoint) else { return }
        let bounds = screen.visibleFrame.insetBy(dx: screenInset, dy: screenInset)
        let placement = preferredPlacement(near: anchorPoint, within: bounds, windowSize: window.frame.size)
        let offset = resolvedOffset(for: placement, windowSize: window.frame.size)
        let origin = CGPoint(x: anchorPoint.x + offset.x, y: anchorPoint.y + offset.y)
        let frame = clampedFrame(origin: origin, size: window.frame.size, within: bounds)

        guard !window.frame.equalTo(frame) else {
            return
        }

        if window.frame.size == frame.size {
            window.setFrameOrigin(frame.origin)
        } else {
            window.setFrame(frame, display: display)
        }
    }

    private func layoutBubble(for text: String) {
        guard let window, let bubbleView, let textField else { return }

        let bubbleSize = preferredBubbleSize(for: text)
        window.setContentSize(bubbleSize)
        bubbleView.frame = NSRect(origin: .zero, size: bubbleSize)
        bubbleView.alphaValue = defaultAlpha
        bubbleView.layer?.cornerRadius = bubbleCornerRadius
        bubbleView.layer?.backgroundColor = visualStyle.bubbleFillColor.cgColor

        let textOriginX = horizontalPadding
        let textWidth = bubbleSize.width - horizontalPadding * 2
        let textHeight = measuredTextSize(for: text).height
        textField.frame = NSRect(
            x: textOriginX,
            y: floor((bubbleSize.height - textHeight) / 2),
            width: textWidth,
            height: textHeight
        )
        textField.stringValue = text
    }

    private func commitVisualState() {
        window?.displayIfNeeded()
        window?.contentView?.displayIfNeeded()
        CATransaction.flush()
    }

    private func preferredBubbleSize(for text: String) -> NSSize {
        let measured = measuredTextSize(for: text)
        let width = max(
            horizontalPadding * 2,
            min(
                maxBubbleWidth,
                horizontalPadding + measured.width + textWidthSlack + horizontalPadding
            )
        )
        let height = max(minBubbleHeight, verticalPadding + measured.height + verticalPadding)
        return NSSize(width: ceil(width), height: ceil(height))
    }

    private func measuredTextSize(for text: String) -> NSSize {
        let maxTextWidth = maxBubbleWidth - horizontalPadding * 2
        let lineHeight = ceil(textFont.ascender - textFont.descender + textFont.leading)
        let maxTextHeight = max(lineHeight, lineHeight * maxTextLines)
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: maxTextWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: textFont]
        )

        return NSSize(
            width: ceil(bounds.width),
            height: ceil(min(maxTextHeight, max(lineHeight, bounds.height)))
        )
    }

    private func preferredPlacement(near mouseLocation: CGPoint, within bounds: CGRect, windowSize: NSSize) -> BubblePlacement {
        let keepoutRect = CGRect(
            x: mouseLocation.x - cursorKeepoutRadius,
            y: mouseLocation.y - cursorKeepoutRadius,
            width: cursorKeepoutRadius * 2,
            height: cursorKeepoutRadius * 2
        )

        let placements = BubblePlacement.allCases
        let firstPlacement = placements[0]
        let firstOrigin = origin(for: firstPlacement, mouseLocation: mouseLocation, windowSize: windowSize)
        var bestPlacement = firstPlacement
        var bestFrame = clampedFrame(origin: firstOrigin, size: windowSize, within: bounds)
        var bestOverlap = overlapArea(between: bestFrame, and: keepoutRect)
        var bestDisplacement = displacement(from: firstOrigin, to: bestFrame.origin)
        var bestPriority = firstPlacement.priority

        for placement in placements.dropFirst() {
            let origin = origin(for: placement, mouseLocation: mouseLocation, windowSize: windowSize)
            let candidateFrame = clampedFrame(origin: origin, size: windowSize, within: bounds)
            let overlap = overlapArea(between: candidateFrame, and: keepoutRect)
            let displacement = displacement(from: origin, to: candidateFrame.origin)

            let shouldReplace =
                overlap < bestOverlap ||
                (overlap == bestOverlap && displacement < bestDisplacement) ||
                (overlap == bestOverlap && displacement == bestDisplacement && placement.priority < bestPriority)

            if shouldReplace {
                bestPlacement = placement
                bestFrame = candidateFrame
                bestOverlap = overlap
                bestDisplacement = displacement
                bestPriority = placement.priority
            }
        }

        return bestPlacement
    }

    private func currentAnchorPoint() -> CGPoint {
        switch anchorMode {
        case .pointer:
            // Follow the agent-sprite's pose (AppKit y-up, set by
            // `DaemonCursor.applyPose` every bezier frame) instead of
            // `NSEvent.mouseLocation`. NSEvent only updates when AppKit
            // dispatches a mouse event to the app queue, which lags
            // during our synthetic `CGEvent.post` stream — the user
            // saw the bubble stay put while the sprite animated away.
            // When the sprite isn't materialized yet (pre-session /
            // background mode), fall back to the real cursor.
            let spritePose = DaemonCursor.shared.currentPoseAppKitScreenPoint
            if spritePose != .zero {
                return spritePose
            }
            return NSEvent.mouseLocation
        case let .fixed(point):
            return point
        }
    }

    private func resolvedOffset(for placement: BubblePlacement, windowSize: NSSize) -> CGPoint {
        let targetOffset = placement.offset(for: windowSize, xGap: cursorOffsetX, yGap: cursorOffsetY)
        let currentOffset = presentedOffset(default: targetOffset)

        guard let currentPlacement else {
            currentPlacement = placement
            animatedOffset = targetOffset
            offsetAnimation = nil
            return targetOffset
        }

        if currentPlacement != placement {
            self.currentPlacement = placement
            if currentOffset == targetOffset {
                animatedOffset = targetOffset
                offsetAnimation = nil
                return targetOffset
            }

            animatedOffset = currentOffset
            offsetAnimation = OffsetAnimation(
                from: currentOffset,
                to: targetOffset,
                startTime: CACurrentMediaTime(),
                duration: offsetAnimationDuration
            )
            return currentOffset
        }

        if offsetAnimation != nil {
            if offsetAnimation?.to != targetOffset {
                animatedOffset = currentOffset
                offsetAnimation = OffsetAnimation(
                    from: currentOffset,
                    to: targetOffset,
                    startTime: CACurrentMediaTime(),
                    duration: offsetAnimationDuration
                )
                return currentOffset
            }

            let interpolated = presentedOffset(default: targetOffset)
            animatedOffset = interpolated
            return interpolated
        }

        animatedOffset = targetOffset
        return targetOffset
    }

    private func clampedFrame(origin: CGPoint, size: NSSize, within bounds: CGRect) -> CGRect {
        let clampedOrigin = CGPoint(
            x: min(max(bounds.minX, origin.x), bounds.maxX - size.width),
            y: min(max(bounds.minY, origin.y), bounds.maxY - size.height)
        )
        return CGRect(origin: clampedOrigin, size: size)
    }

    private func overlapArea(between lhs: CGRect, and rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        return intersection.width * intersection.height
    }

    private func displacement(from source: CGPoint, to target: CGPoint) -> CGFloat {
        let dx = target.x - source.x
        let dy = target.y - source.y
        return dx * dx + dy * dy
    }

    private func origin(for placement: BubblePlacement, mouseLocation: CGPoint, windowSize: NSSize) -> CGPoint {
        let offset = placement.offset(for: windowSize, xGap: cursorOffsetX, yGap: cursorOffsetY)
        return CGPoint(x: mouseLocation.x + offset.x, y: mouseLocation.y + offset.y)
    }

    private func presentedOffset(default defaultOffset: CGPoint) -> CGPoint {
        guard let animation = offsetAnimation else {
            return animatedOffset ?? defaultOffset
        }

        let elapsed = max(0, CACurrentMediaTime() - animation.startTime)
        let rawProgress = min(1, elapsed / animation.duration)
        let progress = easeInOut(rawProgress)
        let offset = CGPoint(
            x: animation.from.x + (animation.to.x - animation.from.x) * progress,
            y: animation.from.y + (animation.to.y - animation.from.y) * progress
        )

        if rawProgress >= 1 {
            offsetAnimation = nil
            animatedOffset = animation.to
            return animation.to
        }

        return offset
    }

    private func easeInOut(_ progress: CGFloat) -> CGFloat {
        progress * progress * (3 - 2 * progress)
    }
}

private final class HUDDisplayLinkWrapper {
    private var link: CVDisplayLink?
    private var onTick: (() -> Void)?

    func start(onTick: @escaping () -> Void) {
        self.onTick = onTick
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let link else { return }

        CVDisplayLinkSetOutputCallback(link, { _, _, _, _, _, userInfo in
            guard let userInfo else { return kCVReturnSuccess }
            let wrapper = Unmanaged<HUDDisplayLinkWrapper>.fromOpaque(userInfo).takeUnretainedValue()
            wrapper.onTick?()
            return kCVReturnSuccess
        }, Unmanaged.passUnretained(self).toOpaque())

        CVDisplayLinkStart(link)
    }

    func stop() {
        guard let link else { return }
        CVDisplayLinkStop(link)
        self.link = nil
        onTick = nil
    }

    deinit {
        if link != nil { stop() }
    }
}
