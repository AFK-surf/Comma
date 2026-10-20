import AppKit

/// The overlay: transparent, over the whole screen and the Dock. It never
/// takes keys or clicks; clicks reach the windows below.
final class EffectPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        animationBehavior = .none
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        let view = NSView()
        view.wantsLayer = true
        contentView = view
        CoreAnimationPrivate.hostLayersInWindowServer(self)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Holds the keyboard while Quick Chat is open, without activating Comma: the
/// app in front stays in front. Its owner lays it over the words, so a click
/// on them or a scroll over them reaches it and one beside them reaches the
/// app below; with no words it takes no clicks. Losing the keyboard (a click
/// elsewhere, ⌘Tab) closes Quick Chat.
final class KeyPanel: NSPanel {
    /// Every key while no text view has the keyboard.
    var onKeyDown: ((NSEvent) -> Void)?
    /// ⌘. and other cancel commands.
    var onCancel: (() -> Void)?
    /// A click on the words, at a point in the content view's bounds.
    var onClick: ((NSEvent, CGPoint) -> Void)?
    var onScroll: ((NSEvent) -> Void)?
    var onResign: (() -> Void)?
    /// Editing's ⌘ shortcuts, which no menu provides here.
    var onKeyEquivalent: ((NSEvent) -> Bool)?

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
        ignoresMouseEvents = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        animationBehavior = .none
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        let surface = Surface()
        surface.panel = self
        contentView = surface
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        onResign?()
    }

    override func keyDown(with event: NSEvent) {
        onKeyDown?(event)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        onKeyEquivalent?(event) ?? false
    }

    /// Takes the clicks and scrolls that reach the panel outside the editor.
    private final class Surface: NSView {
        weak var panel: KeyPanel?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            panel?.onClick?(event, convert(event.locationInWindow, from: nil))
        }

        override func scrollWheel(with event: NSEvent) {
            panel?.onScroll?(event)
        }
    }
}
