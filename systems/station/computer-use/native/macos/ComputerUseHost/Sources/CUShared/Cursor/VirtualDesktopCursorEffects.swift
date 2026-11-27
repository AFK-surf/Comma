import AppKit
import CoreGraphics
import QuartzCore

/// Visual enhancements rendered directly on the secondary virtual display
/// around the AI cursor so every glide, click, and focus action is clearly
/// legible both inside the scaled Notch thumbnail and in the full viewer.
@MainActor
public final class VirtualDesktopClickRipple {
    public static let shared = VirtualDesktopClickRipple()

    private var activePanels: [NSPanel] = []
    private var badgePanel: NSPanel?
    private var badgeLabel: String?

    /// Exact sRGB blue (#1040F2) sampled from `OverlayCursor.png` so the pointer
    /// arrow, `Comma AI` name tag, and click ripple read as one unified cursor.
    public static let cursorAccent = NSColor(srgbRed: 0.0627, green: 0.2510, blue: 0.9490, alpha: 1)

    private init() {}

    /// Updates or creates the compact name tag that follows the AI cursor on
    /// the secondary virtual desktop, matched to the cursor arrow's color and
    /// crisp white outline.
    public func updateCursorBadge(at appKitScreenPoint: CGPoint, label: String = "Comma AI") {
        if let existing = badgePanel, badgeLabel == label {
            existing.setFrameOrigin(Self.badgeOrigin(for: appKitScreenPoint, size: existing.frame.size))
            existing.orderFrontRegardless()
            return
        }
        hideCursorBadge()

        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let textWidth = ceil((label as NSString).size(withAttributes: [.font: font]).width)
        let size = CGSize(width: textWidth + 18, height: 22)

        let panel = NSPanel(
            contentRect: NSRect(origin: Self.badgeOrigin(for: appKitScreenPoint, size: size), size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        panel.contentView = Self.makeBadgeView(label: label, size: size, font: font)
        panel.orderFrontRegardless()
        badgePanel = panel
        badgeLabel = label
    }

    public func hideCursorBadge() {
        badgePanel?.orderOut(nil)
        badgePanel?.close()
        badgePanel = nil
        badgeLabel = nil
    }

    /// Builds the unified cursor label view (shared by live panel and offscreen previews).
    public static func makeBadgeView(
        label: String = "Comma AI",
        size: CGSize? = nil,
        font: NSFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    ) -> NSView {
        let textWidth = ceil((label as NSString).size(withAttributes: [.font: font]).width)
        let resolvedSize = size ?? CGSize(width: textWidth + 18, height: 22)

        let container = NSView(frame: NSRect(origin: .zero, size: resolvedSize))
        container.wantsLayer = true
        container.layer?.backgroundColor = cursorAccent.cgColor
        container.layer?.cornerRadius = resolvedSize.height / 2
        container.layer?.cornerCurve = .circular
        container.layer?.masksToBounds = true
        // Crisp white stroke matching the pointer sprite's white border so arrow
        // and label read as a single cohesive multiplayer cursor on any surface.
        container.layer?.borderWidth = 1.25
        container.layer?.borderColor = NSColor.white.withAlphaComponent(0.95).cgColor

        let text = NSTextField(labelWithString: label)
        text.font = font
        text.textColor = .white
        text.alignment = .center
        let textHeight = ceil(text.fittingSize.height)
        text.frame = NSRect(
            x: 0,
            y: round((resolvedSize.height - textHeight) / 2) + 0.5,
            width: resolvedSize.width,
            height: textHeight
        )
        container.addSubview(text)
        return container
    }

    /// Bottom-right of the cursor tip, tucked cleanly beside the arrow sprite.
    private static func badgeOrigin(for point: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: round(point.x + 12), y: round(point.y - size.height - 10))
    }

    /// Spawns a soft click ripple centered at `appKitScreenPoint`: a tinted press
    /// disc that settles quickly and a thin ring that expands and fades.
    public func emit(at appKitScreenPoint: CGPoint) {
        let size: CGFloat = 96
        let origin = CGPoint(
            x: appKitScreenPoint.x - size / 2,
            y: appKitScreenPoint.y - size / 2
        )
        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: NSSize(width: size, height: size)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        let host = NSView(frame: NSRect(origin: .zero, size: NSSize(width: size, height: size)))
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        let center = CGPoint(x: size / 2, y: size / 2)
        let tint = Self.cursorAccent

        // Press disc: appears at once, then shrinks slightly and fades.
        let disc = Self.circleLayer(radius: 11, center: center, bounds: size)
        disc.fillColor = tint.withAlphaComponent(0.20).cgColor
        disc.strokeColor = nil
        host.layer?.addSublayer(disc)

        // Ring: expands from the press point and dissolves.
        let ring = Self.circleLayer(radius: 12, center: center, bounds: size)
        ring.fillColor = nil
        ring.strokeColor = tint.withAlphaComponent(0.72).cgColor
        ring.lineWidth = 1.5
        host.layer?.addSublayer(ring)

        let duration: CFTimeInterval = 0.6
        let easeOut = CAMediaTimingFunction(controlPoints: 0.2, 0.7, 0.3, 1.0)

        disc.add(Self.animation("transform.scale", from: 1.0, to: 0.82, duration: 0.32, timing: easeOut), forKey: "pressScale")
        disc.add(Self.animation("opacity", from: 1.0, to: 0.0, duration: 0.36, timing: easeOut), forKey: "pressOpacity")
        ring.add(Self.animation("transform.scale", from: 0.7, to: 3.4, duration: duration, timing: easeOut), forKey: "rippleScale")
        ring.add(Self.animation("opacity", from: 1.0, to: 0.0, duration: duration, timing: easeOut), forKey: "rippleOpacity")
        ring.add(Self.animation("lineWidth", from: 1.5, to: 0.5, duration: duration, timing: easeOut), forKey: "rippleLine")

        panel.contentView = host
        panel.orderFrontRegardless()
        activePanels.append(panel)

        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.05) { [weak self, weak panel] in
            guard let panel else { return }
            panel.orderOut(nil)
            panel.close()
            self?.activePanels.removeAll { $0 === panel }
        }
    }

    public func tearDown() {
        hideCursorBadge()
        for panel in activePanels {
            panel.orderOut(nil)
            panel.close()
        }
        activePanels.removeAll()
    }

    private static func circleLayer(radius: CGFloat, center: CGPoint, bounds: CGFloat) -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.bounds = CGRect(x: 0, y: 0, width: bounds, height: bounds)
        layer.position = center
        layer.path = CGPath(
            ellipseIn: CGRect(
                x: bounds / 2 - radius,
                y: bounds / 2 - radius,
                width: radius * 2,
                height: radius * 2
            ),
            transform: nil
        )
        return layer
    }

    private static func animation(
        _ keyPath: String,
        from: CGFloat,
        to: CGFloat,
        duration: CFTimeInterval,
        timing: CAMediaTimingFunction
    ) -> CABasicAnimation {
        let anim = CABasicAnimation(keyPath: keyPath)
        anim.fromValue = from
        anim.toValue = to
        anim.duration = duration
        anim.timingFunction = timing
        anim.fillMode = .forwards
        anim.isRemovedOnCompletion = false
        return anim
    }
}
