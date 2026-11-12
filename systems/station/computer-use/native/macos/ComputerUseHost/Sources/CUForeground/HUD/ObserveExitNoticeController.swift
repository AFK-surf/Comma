import AppKit

@MainActor
final class ObserveExitNoticeController: OverlayWindowSource {
    private let message = "Esc 退出 Computer Use"
    private let topInset: CGFloat = 18
    private let minimumWidth: CGFloat = 380
    private let horizontalPadding: CGFloat = 24
    private let verticalPadding: CGFloat = 10
    private let textWidthSlack: CGFloat = 8
    private let font = NSFont.systemFont(ofSize: 13, weight: .medium)
    private let backgroundColor = NSColor(calibratedWhite: 0.22, alpha: 0.84)

    private var window: NSWindow?
    private var textField: NSTextField?

    var overlayWindows: [NSWindow] {
        window.map { [$0] } ?? []
    }

    init() {
        OverlayWindowRegistry.shared.register(self)
    }

    func show(near point: CGPoint) {
        if window == nil {
            createWindow()
        }

        guard let window, let textField else { return }

        let appKitPoint = DesktopCoordinateSpace.appKitPoint(fromScreenPoint: point)
        guard let screen = DesktopCoordinateSpace.screen(containing: appKitPoint) else { return }

        textField.stringValue = message
        let textSize = measuredTextSize(for: message)
        let contentWidth = max(textSize.width + textWidthSlack, minimumWidth - horizontalPadding * 2)
        let size = NSSize(
            width: ceil(contentWidth + horizontalPadding * 2),
            height: ceil(textSize.height + verticalPadding * 2)
        )

        window.setContentSize(size)
        window.contentView?.frame = NSRect(origin: .zero, size: size)
        window.contentView?.layer?.cornerRadius = size.height / 2
        textField.frame = NSRect(
            x: horizontalPadding,
            y: floor((size.height - textSize.height) / 2),
            width: floor(size.width - horizontalPadding * 2),
            height: textSize.height
        )

        let visibleFrame = screen.visibleFrame
        let origin = CGPoint(
            x: floor(visibleFrame.midX - size.width / 2),
            y: floor(visibleFrame.maxY - topInset - size.height)
        )
        window.setFrame(NSRect(origin: origin, size: size), display: true)
        window.orderFront(nil)
    }

    func hide() {
        window?.orderOut(nil)
    }
}

private extension ObserveExitNoticeController {
    func createWindow() {
        let window = NSWindow(
            contentRect: .zero,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let contentView = NSView(frame: .zero)
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = backgroundColor.cgColor
        contentView.layer?.masksToBounds = true

        let textField = NSTextField(labelWithString: message)
        textField.alignment = .center
        textField.font = font
        textField.textColor = .white
        textField.lineBreakMode = .byClipping
        textField.maximumNumberOfLines = 1

        contentView.addSubview(textField)
        window.contentView = contentView

        self.window = window
        self.textField = textField
    }

    func measuredTextSize(for text: String) -> NSSize {
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )

        return NSSize(width: ceil(bounds.width), height: ceil(bounds.height))
    }
}
