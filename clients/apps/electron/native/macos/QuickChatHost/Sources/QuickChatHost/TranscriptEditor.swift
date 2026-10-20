import AppKit

/// The words as text to edit, in place of the drawn ones. It is set like
/// `TranscriptLayer`'s words: the same font and size, centered in the box,
/// growing above it and scrolling past `maximumHeight`. So the words stay
/// where they are when it opens. A text view gives input methods, selection
/// and undo. Return sends and Esc closes, as while listening.
@MainActor
final class TranscriptEditor: NSObject, NSTextViewDelegate {
    enum Command {
        case send
        case cancel
    }

    var onCommand: ((Command) -> Void)?
    /// After each change the person makes, while composing with an input method too.
    var onChange: (() -> Void)?
    /// The text area's width; its frame is the coordinate space of `view`.
    var width: CGFloat = 0

    /// In the key panel's content view, whose bounds use the text area's coordinates.
    let view = NSScrollView()
    private let textView = ComposingTextView()

    override init() {
        super.init()
        view.drawsBackground = false
        view.hasVerticalScroller = false
        view.isHidden = true
        // The drawn words' halo. On the scroll view, so its clip view does not cut it.
        view.wantsLayer = true
        view.layer?.shadowColor = NSColor.black.cgColor
        view.layer?.shadowOpacity = 0.6
        view.layer?.shadowRadius = 8
        view.layer?.shadowOffset = .zero
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.insertionPointColor = .white
        textView.selectedTextAttributes = [.backgroundColor: NSColor.white.withAlphaComponent(0.25)]
        textView.delegate = self
        textView.onMarkedText = { [weak self] in self?.textDidChange(Notification(name: NSText.didChangeNotification)) }
        view.documentView = textView
    }

    var isOpen: Bool { !view.isHidden }
    var text: String { textView.string }
    /// An input method is composing in it.
    var isComposing: Bool { textView.hasMarkedText() }
    /// How far the text is scrolled back from its last line.
    var scrolledBack: CGFloat { max(0, textView.frame.height - view.documentVisibleRect.maxY) }

    /// Shows `text` with the caret at its end, scrolled back from its last
    /// line as far as the drawn words were, and takes the keyboard.
    func open(_ text: String, scrolledBack: CGFloat) {
        textView.string = text
        textView.undoManager?.removeAllActions()
        view.isHidden = false
        fitText()
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        let hidden = textView.frame.height - view.contentSize.height
        if hidden > 0 { textView.scroll(NSPoint(x: 0, y: max(0, hidden - scrolledBack))) }
        view.window?.makeFirstResponder(textView)
        // Keys replayed in this same turn go through the input method too.
        textView.inputContext?.activate()
    }

    /// Other words in place of the text, which the person has not changed:
    /// the caret stays where it was in the part both share, else goes to the end.
    func replace(with text: String) {
        let caret = textView.selectedRange()
        let shared = (text.commonPrefix(with: textView.string) as NSString).length
        textView.string = text
        textView.undoManager?.removeAllActions()
        fitText()
        let location = NSMaxRange(caret) <= shared ? caret.location : (text as NSString).length
        textView.setSelectedRange(NSRange(location: location, length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
    }

    func close() {
        guard isOpen else { return }
        view.isHidden = true
        view.window?.makeFirstResponder(nil)
    }

    /// Replays an input from before the editor opened: a click places the
    /// caret (`point` in the text area's coordinates), a shortcut runs, and a
    /// key is typed through the input method, Return and Esc included.
    func replay(_ event: NSEvent, at point: CGPoint) {
        if event.type == .leftMouseDown {
            let index = textView.characterIndexForInsertion(at: textView.convert(point, from: view.superview))
            textView.setSelectedRange(NSRange(location: index, length: 0))
        } else if !performKeyEquivalent(event) {
            textView.keyDown(with: event)
        }
    }

    /// ⌘A, ⌘C, ⌘X, ⌘V, ⌘Z and ⇧⌘Z, which no menu provides here.
    func performKeyEquivalent(_ event: NSEvent) -> Bool {
        guard isOpen else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch (event.charactersIgnoringModifiers?.lowercased(), modifiers) {
        case ("a", [.command]): textView.selectAll(nil)
        case ("c", [.command]): textView.copy(nil)
        case ("x", [.command]): textView.cut(nil)
        case ("v", [.command]): textView.paste(nil)
        case ("z", [.command]): textView.undoManager?.undo()
        case ("z", [.command, .shift]): textView.undoManager?.redo()
        default: return false
        }
        return true
    }

    // MARK: NSTextViewDelegate

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            onCommand?(.send)
        case #selector(NSResponder.cancelOperation(_:)):
            onCommand?(.cancel)
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            break
        default:
            return false
        }
        return true
    }

    func textDidChange(_ notification: Notification) {
        fitText()
        onChange?()
    }

    // MARK: Layout

    /// Sets the text as the drawn words would be: the size that fits the box,
    /// centered in it while it fits, above it once it does not.
    private func fitText() {
        guard let storage = textView.textStorage, let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }
        let size = TranscriptLayer.fit(textView.string, width: width).fontSize
        let attributes: [NSAttributedString.Key: Any] = [
            .font: TranscriptLayer.font(size: size),
            .paragraphStyle: TranscriptLayer.paragraph(size: size),
            .foregroundColor: NSColor(cgColor: TranscriptLayer.wordColor)!,
        ]
        storage.addAttributes(attributes, range: NSRange(location: 0, length: storage.length))
        textView.typingAttributes = attributes
        textView.frame.size.width = width
        layoutManager.ensureLayout(for: container)
        textView.sizeToFit()
        // An empty text still has the line the caret is on.
        let height = layoutManager.usedRect(for: container).height.rounded(.up)
        let shown = min(height, TranscriptLayer.maximumHeight)
        let bottom = height <= TranscriptLayer.boxHeight ? (TranscriptLayer.boxHeight - height) / 2 : 0
        view.frame = CGRect(x: 0, y: bottom, width: width, height: shown)
    }
}

/// Composing with an input method changes the text without `textDidChange`;
/// this reports each change, so the editor fits the composition too. It
/// draws without font smoothing, which thickens text by about a sixth: the
/// drawn words are filled outlines, and the two must look the same.
private final class ComposingTextView: NSTextView {
    var onMarkedText: (() -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.cgContext.setShouldSmoothFonts(false)
        super.draw(dirtyRect)
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        onMarkedText?()
    }
}
