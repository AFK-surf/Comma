import AppKit

/// Quick Chat's two buttons under the words: close and send. Their panel
/// takes clicks but never the keyboard and never activates Comma, so the app
/// in front stays in front and Return and Esc keep working.
@MainActor
final class QuickChatControls {
    var onClose: (() -> Void)?
    var onSend: (() -> Void)?

    private static let size: CGFloat = 32
    private static let gap: CGFloat = 12

    private let panel = ControlPanel()
    private let close = IconButton(symbol: "xmark", style: .secondary)
    private let send = IconButton(symbol: "arrow.up", style: .primary)

    init() {
        let content = panel.contentView!
        for (index, button) in [close, send].enumerated() {
            button.frame = CGRect(x: CGFloat(index) * (Self.size + Self.gap), y: 0, width: Self.size, height: Self.size)
            content.addSubview(button)
        }
        close.action = { [weak self] in self?.onClose?() }
        send.action = { [weak self] in self?.onSend?() }
    }

    func configure(close closeLabel: String, send sendLabel: String) {
        close.setAccessibilityLabel(closeLabel)
        send.setAccessibilityLabel(sendLabel)
    }

    /// `center` is in screen coordinates.
    func show(at center: CGPoint, canSend: Bool) {
        let width = Self.size * 2 + Self.gap
        panel.setFrame(
            CGRect(x: (center.x - width / 2).rounded(), y: (center.y - Self.size / 2).rounded(),
                   width: width, height: Self.size),
            display: false
        )
        setCanSend(canSend)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    func setCanSend(_ canSend: Bool) {
        send.isEnabled = canSend
    }

    /// Once the words leave, the buttons go at once: they are done.
    func hide() {
        panel.orderOut(nil)
    }
}

/// Borderless, clear and non-activating; it can never be key.
private final class ControlPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        animationBehavior = .none
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        let view = NSView()
        view.wantsLayer = true
        contentView = view
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A round icon button. Close is dark glass, like the Dock's surroundings it
/// sits on; send is the light, primary one and dims while there is nothing
/// to send.
private final class IconButton: NSView {
    enum Style {
        case primary
        case secondary
    }

    var action: (() -> Void)?
    var isEnabled = true {
        didSet { if isEnabled != oldValue { update() } }
    }

    private let style: Style
    /// Background, border and glyph; it scales about its center when pressed.
    private let face = CALayer()
    private let icon = CALayer()
    private var hovered = false
    private var pressed = false

    init(symbol: String, style: Style) {
        self.style = style
        super.init(frame: .zero)
        wantsLayer = true
        layer!.addSublayer(face)
        face.masksToBounds = true
        if style == .secondary {
            face.borderWidth = 0.5
            face.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!
            .withSymbolConfiguration(configuration)!
        image.isTemplate = true
        // The glyph is drawn as a mask and filled with the style's color.
        let mask = CALayer()
        mask.contents = image
        mask.contentsGravity = .center
        icon.mask = mask
        face.addSublayer(icon)
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self
        ))
        update()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        face.frame = bounds
        face.cornerRadius = bounds.height / 2
        icon.frame = bounds
        icon.mask?.frame = bounds
        icon.mask?.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        update()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        update()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressed = true
        update()
    }

    override func mouseUp(with event: NSEvent) {
        guard pressed else { return }
        pressed = false
        update()
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action?() }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func isAccessibilityEnabled() -> Bool { isEnabled }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        action?()
        return true
    }

    private func update() {
        let active = isEnabled && hovered
        let (background, glyph): (NSColor, NSColor) = switch style {
        case .primary:
            (NSColor.white.withAlphaComponent(active ? 1 : 0.9), NSColor.black.withAlphaComponent(0.85))
        case .secondary:
            (NSColor.black.withAlphaComponent(active ? 0.44 : 0.32), NSColor.white.withAlphaComponent(0.86))
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        face.backgroundColor = background.cgColor
        icon.backgroundColor = glyph.cgColor
        face.opacity = isEnabled ? 1 : 0.35
        face.setAffineTransform(pressed ? CGAffineTransform(scaleX: 0.94, y: 0.94) : .identity)
        CATransaction.commit()
    }
}

/// A line of text above the words: tap ⌘ to keep talking while they are
/// edited, or what keeps Quick Chat from listening. It is plain text with
/// the words' halo, in the overlay, so it takes no clicks.
@MainActor
final class ResumeTip {
    let layer = CATextLayer()

    init() {
        layer.alignmentMode = .center
        layer.anchorPoint = CGPoint(x: 0.5, y: 0)
        layer.opacity = 0
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.6
        layer.shadowRadius = 4
        layer.shadowOffset = .zero
        layer.filters = [CoreAnimationPrivate.filter("gaussianBlur", ["inputRadius": 0])]
    }

    var isShown: Bool { layer.opacity > 0 }

    /// Its bottom center at `point`. It rises 4 pt into place, out of a
    /// slight blur, as it fades in; once shown it follows `point` at once.
    func show(_ text: String, at point: CGPoint, scale: CGFloat) {
        let string = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.6),
        ])
        let size = string.size()
        let appearing = layer.opacity == 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.string = string
        layer.contentsScale = scale
        layer.bounds = CGRect(x: 0, y: 0, width: size.width.rounded(.up) + 2, height: size.height.rounded(.up))
        layer.position = point
        layer.opacity = 1
        CATransaction.commit()
        guard appearing else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        let rise = CABasicAnimation(keyPath: "transform.translation.y")
        rise.fromValue = -4
        rise.toValue = 0
        let focus = CABasicAnimation(keyPath: "filters.gaussianBlur.inputRadius")
        focus.fromValue = 3
        focus.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [fade, rise, focus]
        group.duration = 0.32
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
        layer.add(group, forKey: "show")
    }

    func hide() {
        guard layer.opacity > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = 0
        CATransaction.commit()
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.12
        layer.add(fade, forKey: "show")
    }
}
