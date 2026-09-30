import AppKit

final class NotchWindow: NSPanel {
    override init(
        contentRect: NSRect,
        styleMask: NSWindow.StyleMask,
        backing: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: styleMask.union(.nonactivatingPanel),
            backing: backing,
            defer: flag
        )

        isOpaque = false
        alphaValue = 1
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        backgroundColor = .clear
        isMovable = false
        collectionBehavior = [
            .fullScreenAuxiliary,
            .stationary,
            .canJoinAllSpaces,
            .ignoresCycle,
        ]
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        level = .statusBar + 8
        hasShadow = false
        title = NotchWindowMetadata.title
        identifier = NSUserInterfaceItemIdentifier(NotchWindowMetadata.automationIdentifier)
    }

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }
}
