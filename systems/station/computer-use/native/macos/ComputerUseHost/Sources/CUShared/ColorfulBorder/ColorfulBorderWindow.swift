import AppKit

/// NSWindow that hosts a `ColorfulBorderView` and positions itself around a
/// target rectangle. Adapted from the legacy ComputerUse
/// `DimmedWorkspace/ColorfulBorderWindow.swift` implementation to preserve its
/// proven overlay ordering and visibility behavior.
final class ColorfulBorderWindow: NSWindow {
    let borderView: ColorfulBorderView

    static let glowPadding: CGFloat = 80
    static let glowScale: CGFloat = 0.7

    init() {
        borderView = ColorfulBorderView(frame: .zero)

        super.init(
            contentRect: .zero,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        isReleasedWhenClosed = false
        animationBehavior = .none
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        collectionBehavior = [.transient, .fullScreenNone, .canJoinAllSpaces]
        level = .normal

        alphaValue = 0
        contentView = borderView
    }

    private var fadeInWorkItem: DispatchWorkItem?

    func fadeIn() {
        fadeInWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                self.animator().alphaValue = 1
            }
        }
        fadeInWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    func resetFade() {
        fadeInWorkItem?.cancel()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            self.animator().alphaValue = 0
        }
        fadeIn()
    }

    override func constrainFrameRect(_ frameRect: NSRect, to _: NSScreen?) -> NSRect {
        frameRect
    }

    /// `focusedWindowBounds` is in AX (Quartz) screen space — y-down from the
    /// top-left of the primary display, matching `kCGWindowBounds`.
    func update(
        focusedWindowBounds: CGRect,
        anchorWindowNumber: Int,
        cornerRadius: CGFloat
    ) {
        let padding = Self.glowPadding
        let appKitFrame = Self.appKitRect(fromScreenRect: focusedWindowBounds)

        let extendedFrame = appKitFrame.insetBy(dx: -2, dy: -2)
        let windowFrame = extendedFrame.insetBy(dx: -padding, dy: -padding)
        setFrame(windowFrame, display: true)

        let innerRect = CGRect(
            x: padding,
            y: padding,
            width: extendedFrame.width,
            height: extendedFrame.height
        )

        borderView.updateGeometry(.init(
            innerRect: innerRect,
            cornerRadius: cornerRadius,
            glowScale: Self.glowScale
        ))

        order(.below, relativeTo: anchorWindowNumber)
    }

    /// Inlined equivalent of legacy `DesktopCoordinateSpace.appKitRect(fromScreenRect:)`.
    private static func appKitRect(fromScreenRect rect: CGRect) -> CGRect {
        let bridgeHeight = CGDisplayBounds(CGMainDisplayID()).height
        return CGRect(
            x: rect.minX,
            y: bridgeHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }
}
