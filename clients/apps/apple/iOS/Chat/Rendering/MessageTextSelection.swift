import SwiftUI
import UIKit
import CommaCore

/**
 * Text selection in one message's bubbles, which the long-press menu's Select Text starts. SwiftUI's `Text` selects
 * only the whole of itself, and a bubble is many of them (a paragraph, a list item, a table cell each), so while a
 * message is selected in, each of its bubbles shows its words as one text the system selects in
 * (`SelectableBubbleText`): a selection starts and stops anywhere in the bubble. A tap in the transcript outside the
 * bubbles ends it.
 */
@MainActor final class MessageSelectionController: NSObject, UIGestureRecognizerDelegate {
    let rowID: String
    private let end: () -> Void
    private let views = NSHashTable<UITextView>.weakObjects()
    private lazy var tap = UITapGestureRecognizer(target: self, action: #selector(tappedOutside))
    private var started = false

    init(rowID: String, end: @escaping () -> Void) {
        self.rowID = rowID
        self.end = end
    }

    /// A bubble's text is on screen. The message's first one takes the selection, whole, so the handles show where
    /// to drag from.
    fileprivate func attach(_ view: UITextView, first: Bool) {
        views.add(view)
        if tap.view == nil, let scroll = view.enclosingScrollView {
            tap.cancelsTouchesInView = false
            tap.delegate = self
            scroll.addGestureRecognizer(tap)
        }
        guard first, !started else { return }
        started = true
        view.becomeFirstResponder()
        view.selectAll(nil)
    }

    fileprivate func detach(_ view: UITextView) {
        views.remove(view)
        if views.allObjects.isEmpty { tap.view?.removeGestureRecognizer(tap) }
    }

    @objc private func tappedOutside() {
        tap.view?.removeGestureRecognizer(tap)
        end()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let touched = touch.view else { return true }
        return !views.allObjects.contains { touched.isDescendant(of: $0) }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

extension EnvironmentValues {
    /// Set on the bubbles of the message being selected in.
    @Entry var messageSelection: MessageSelectionController?
}

/// A bubble's words as one selectable text, sized as the text it stands in for.
struct SelectableBubbleText: UIViewRepresentable {
    let text: NSAttributedString
    /// The handles and the highlight, which must read on the bubble's fill.
    var tint: UIColor? = nil
    /// The message's first bubble, which takes the selection when it starts.
    var first = true
    let controller: MessageSelectionController

    func makeUIView(context: Context) -> BubbleTextView {
        let view = BubbleTextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.dataDetectorTypes = []
        // A long press on selected text picks a word, as on any other; it does not lift the text to drag it away.
        view.textDragInteraction?.isEnabled = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.accessibilityIdentifier = "messageTextSelection"
        view.controller = controller
        view.first = first
        return view
    }

    func updateUIView(_ view: BubbleTextView, context: Context) {
        if view.attributedText != text { view.attributedText = text }
        if let tint { view.tintColor = tint }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: BubbleTextView, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 10_000
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: min(ceil(size.width), width), height: ceil(size.height))
    }

    static func dismantleUIView(_ view: BubbleTextView, coordinator: ()) {
        view.controller?.detach(view)
        view.controller = nil
    }

    final class BubbleTextView: UITextView {
        fileprivate var controller: MessageSelectionController?
        fileprivate var first = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            // After this pass, when the text has its frame and can show a selection.
            Task { @MainActor [weak self] in
                guard let self, self.window != nil else { return }
                self.controller?.attach(self, first: self.first)
            }
        }
    }
}

private extension UIView {
    var enclosingScrollView: UIScrollView? {
        var view = superview
        while let current = view {
            if let scroll = current as? UIScrollView { return scroll }
            view = current.superview
        }
        return nil
    }
}

/**
 * A bubble's blocks as one attributed text in the bubbles' type: a list item after its marker, a table's cells on one
 * line with tabs between them, code in the code face.
 */
@MainActor enum SelectableMessageText {
    /// What differs between an agent's bubble and a person's: the words' colour, a link's, and whether inline code
    /// takes its own colours (on a person's coloured bubble it keeps the words').
    struct Palette {
        var text = UIColor(CommaTheme.textPrimary)
        var link = UIColor(CommaTheme.markdownLink)
        var colorsCode = true
    }

    /// The bubbles' measures (`MarkdownBlockView`, `MarkdownListView`, `MarkdownTableView`), so a bubble keeps its
    /// shape when its text becomes selectable.
    private static let lineSpacing: CGFloat = 3
    private static let blockSpacing: CGFloat = 12
    private static let headingSpacing: CGFloat = 20
    private static let itemSpacing: CGFloat = 8
    private static let markerGap: CGFloat = 6
    private static let quoteIndent: CGFloat = 16
    private static let cellPadding: CGFloat = 24
    private static let cellMaxWidth: CGFloat = 220
    private static let rowSpacing: CGFloat = 14

    private static var bodyFont: UIFont { .preferredFont(forTextStyle: .body) }
    private static var codeFont: UIFont {
        .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize, weight: .regular)
    }
    private static var tableFont: UIFont { .preferredFont(forTextStyle: .subheadline) }

    /// A person's message as its bubble draws it (`MessageBubbles.inline`), in `color`.
    static func person(_ value: AttributedString, color: UIColor) -> NSAttributedString {
        let palette = Palette(text: color, link: color, colorsCode: false)
        let out = NSMutableAttributedString()
        append(styled(value, font: bodyFont, palette: palette, mentions: true), to: out, font: bodyFont, spacing: 0, indent: 0,
               lineSpacing: 0)
        return out
    }

    /// The blocks of one prose bubble.
    static func prose(_ blocks: [MarkdownBlock]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        blocks.forEach { append($0, to: out, leading: 0, depth: 0) }
        return out
    }

    static func code(_ text: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        append(.code(language: nil, text: text), to: out, leading: 0, depth: 0)
        return out
    }

    /// Whether the rows as lines lie on the table's own grid (`MarkdownTableView`), which then stays under them: no
    /// cell wraps in its column, and the first column starts at its leading edge, where a line starts.
    static func liesOnGrid(_ table: MarkdownTable) -> Bool {
        guard table.alignments.first ?? .leading == .leading else { return false }
        return cells(table).allSatisfy { row in row.allSatisfy { ceil($0.size().width) <= cellMaxWidth } }
    }

    private static func cells(_ table: MarkdownTable) -> [[NSAttributedString]] {
        let palette = Palette()
        return ([table.head] + table.rows).enumerated().map { index, row in
            row.map { styled($0, font: index == 0 ? tableFont.with(.traitBold) : tableFont, palette: palette) }
        }
    }

    /// A table's rows as lines, a tab between cells. `columns` are the spans of the grid's columns from the text's
    /// leading edge, where the grid is under the text: a cell stands in its column as the grid aligns it. Without
    /// them each column is as wide as its cells; `width` is then the table's, which its last column fills.
    static func table(_ table: MarkdownTable, columns: [ClosedRange<CGFloat>]? = nil) -> (text: NSAttributedString, width: CGFloat) {
        let rows = cells(table)
        var widths: [CGFloat] = []
        for row in rows {
            for (column, cell) in row.enumerated() {
                let width = min(max(ceil(cell.size().width), 60), cellMaxWidth) + cellPadding
                if column < widths.count { widths[column] = max(widths[column], width) } else { widths.append(width) }
            }
        }
        var stops: [NSTextTab] = []
        var x: CGFloat = 0
        if let columns {
            for (column, span) in columns.enumerated().dropFirst() {
                let alignment = table.alignments.indices.contains(column) ? table.alignments[column] : .leading
                switch alignment {
                case .leading: stops.append(NSTextTab(textAlignment: .natural, location: span.lowerBound))
                case .center: stops.append(NSTextTab(textAlignment: .center, location: (span.lowerBound + span.upperBound) / 2))
                case .trailing: stops.append(NSTextTab(textAlignment: .right, location: span.upperBound))
                }
            }
        } else {
            for width in widths.dropLast() {
                x += width
                stops.append(NSTextTab(textAlignment: .natural, location: x))
            }
        }
        let out = NSMutableAttributedString()
        for row in rows {
            let line = NSMutableAttributedString()
            for (column, cell) in row.enumerated() {
                if column > 0 { line.append(NSAttributedString(string: "\t", attributes: [.font: tableFont])) }
                line.append(cell)
            }
            append(line, to: out, font: tableFont, spacing: rowSpacing, indent: 0, tabs: stops, lineSpacing: 0)
        }
        return (out, widths.reduce(0, +) - cellPadding)
    }

    /// `leading` is where the block's lines start; `marker` a list item's, at its own place before the first line.
    private static func append(_ block: MarkdownBlock, to out: NSMutableAttributedString, leading: CGFloat, depth: Int,
                               spacing: CGFloat? = nil, marker: (text: String, x: CGFloat)? = nil) {
        let palette = Palette()
        let above = spacing ?? { if case .heading = block { headingSpacing } else { blockSpacing } }()
        func line(_ text: NSAttributedString, font: UIFont, lineSpacing: CGFloat = lineSpacing) {
            guard let marker else {
                return append(text, to: out, font: font, spacing: above, indent: leading, lineSpacing: lineSpacing)
            }
            let marked = NSMutableAttributedString(string: marker.text + "\t", attributes: [.font: bodyFont, .foregroundColor: palette.text])
            marked.append(text)
            append(marked, to: out, font: font, spacing: above, indent: leading, hanging: marker.x,
                   tabs: [NSTextTab(textAlignment: .natural, location: leading)], lineSpacing: lineSpacing)
        }
        switch block {
        case .paragraph(let value):
            line(styled(value, font: bodyFont, palette: palette), font: bodyFont)
        case .heading(let level, let value):
            let font: UIFont = level == 1 ? .preferredFont(forTextStyle: .title3).with(.traitBold) : .preferredFont(forTextStyle: .headline)
            line(styled(value, font: font, palette: palette), font: font, lineSpacing: 0)
        case .list(let ordered, let start, let items):
            let base = leading + (depth == 0 ? 2 : 0)
            for (index, item) in items.enumerated() {
                let box = item.checked.map { $0 ? "☑" : "☐" }
                let mark = box ?? (ordered ? "\(start + index)." : ["•", "◦", "▪"][min(depth, 2)])
                let width = ceil((mark as NSString).size(withAttributes: [.font: bodyFont]).width)
                // A number ends where its column does; a bullet sits in the middle of its own.
                let column = max(width, box != nil || ordered ? 18 : 12)
                let x = base + (ordered && box == nil ? column - width : (column - width) / 2)
                let content = base + column + markerGap
                let first = index == 0 ? above : itemSpacing
                let blocks = item.blocks.isEmpty ? [MarkdownBlock.paragraph(AttributedString(" "))] : item.blocks
                for (position, child) in blocks.enumerated() {
                    append(child, to: out, leading: content, depth: depth + 1, spacing: position == 0 ? first : itemSpacing,
                           marker: position == 0 ? (mark, x) : nil)
                }
            }
        case .quote(let blocks):
            for (position, child) in blocks.enumerated() {
                append(child, to: out, leading: leading + quoteIndent, depth: depth, spacing: position == 0 ? above : itemSpacing)
            }
        case .code(_, let text):
            line(NSAttributedString(string: text, attributes: [.font: codeFont, .foregroundColor: palette.text]), font: codeFont,
                 lineSpacing: 0)
        case .table(let table):
            let rows = self.table(table).text
            append(rows, to: out, font: tableFont, spacing: above, indent: leading, lineSpacing: 0)
        case .divider:
            break
        }
    }

    /// Adds `text` as the next paragraphs: `spacing` above the first unless it opens the bubble, every line at
    /// `indent`, the first at `hanging` when a marker stands there.
    private static func append(_ text: NSAttributedString, to out: NSMutableAttributedString, font: UIFont, spacing: CGFloat,
                               indent: CGFloat, hanging: CGFloat? = nil, tabs: [NSTextTab]? = nil, lineSpacing: CGFloat) {
        guard text.length > 0 else { return }
        // The break ends the paragraph above and carries its attributes.
        if out.length > 0 { out.append(NSAttributedString(string: "\n", attributes: out.attributes(at: out.length - 1, effectiveRange: nil))) }
        let start = out.length
        out.append(text)
        let style = NSMutableParagraphStyle()
        // SwiftUI puts a line spacing in place of the font's leading, where UIKit adds it to the leading.
        style.lineSpacing = lineSpacing > 0 ? max(0, lineSpacing - leading(font)) : 0
        style.firstLineHeadIndent = indent
        style.headIndent = indent
        if let tabs { style.tabStops = tabs }
        let range = NSRange(location: start, length: out.length - start)
        out.addAttribute(.swiftUILineSpacing, value: lineSpacing, range: range)
        // A nested text (a table's rows) keeps the paragraph styles it came with.
        out.enumerateAttribute(.paragraphStyle, in: range) { value, part, _ in
            if value == nil { out.addAttribute(.paragraphStyle, value: style, range: part) }
        }
        guard start > 0 || hanging != nil else { return }
        let end = (out.string as NSString).paragraphRange(for: NSRange(location: start, length: 0))
        let current = out.attribute(.paragraphStyle, at: start, effectiveRange: nil) as? NSParagraphStyle ?? style
        let first = current.mutableCopy() as! NSMutableParagraphStyle
        // The line above ends with its line spacing, which SwiftUI leaves out after a text's last line.
        if start > 0 {
            let before = out.attribute(.swiftUILineSpacing, at: start - 1, effectiveRange: nil) as? CGFloat
            first.paragraphSpacingBefore = max(0, spacing - (before ?? 0))
        }
        if let hanging { first.firstLineHeadIndent = hanging }
        out.addAttribute(.paragraphStyle, value: first, range: end)
    }

    /// What a text view adds to `font`'s ascent and descent for each line, measured in one.
    private static func leading(_ font: UIFont) -> CGFloat {
        let key = "\(font.fontName) \(font.pointSize)"
        if let known = leadings[key] { return known }
        let view = UITextView()
        view.isScrollEnabled = false
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        func height(_ string: String) -> CGFloat {
            view.attributedText = NSAttributedString(string: string, attributes: [.font: font])
            return view.sizeThatFits(CGSize(width: 1_000, height: CGFloat.greatestFiniteMagnitude)).height
        }
        let leading = max(0, height("A\nA") - height("A") - (font.ascender - font.descender))
        leadings[key] = leading
        return leading
    }

    private static var leadings: [String: CGFloat] = [:]

    /// Inline text in UIKit's attributes: emphasis as the font's traits, code and formulas in the code face, a link
    /// in the link colour. A link opens nothing here, so a touch on it starts a selection. The one font the text
    /// sets itself is the code face in an agent's message and, with `mentions`, a mention's weight in a person's.
    private static func styled(_ value: AttributedString, font: UIFont, palette: Palette, mentions: Bool = false) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for run in value.runs {
            let intent = run.inlinePresentationIntent ?? []
            var runFont = font
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: palette.text]
            if intent.contains(.code) || (run.swiftUI.font != nil && !mentions) {
                // An agent's inline code, and a formula's source, which has no fill.
                runFont = codeFont
                if palette.colorsCode, intent.contains(.code) || run.swiftUI.backgroundColor != nil {
                    attributes[.backgroundColor] = UIColor(CommaTheme.markdownInlineCodeBackground)
                    attributes[.foregroundColor] = UIColor(CommaTheme.markdownInlineCode)
                }
            } else if run.swiftUI.font != nil {
                runFont = font.with(.traitBold)
            }
            if intent.contains(.stronglyEmphasized) { runFont = runFont.with(.traitBold) }
            if intent.contains(.emphasized) { runFont = runFont.with(.traitItalic) }
            if intent.contains(.strikethrough) || run.swiftUI.strikethroughStyle != nil {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if run.link != nil, run.link?.scheme != "comma" {
                attributes[.foregroundColor] = palette.link
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            attributes[.font] = runFont
            out.append(NSAttributedString(string: String(value[run.range].characters), attributes: attributes))
        }
        return out
    }
}

private extension NSAttributedString.Key {
    /// The line spacing SwiftUI gives the paragraph, which the paragraph after it reads.
    static let swiftUILineSpacing = NSAttributedString.Key("surf.comma.swiftUILineSpacing")
}

private extension UIFont {
    func with(_ trait: UIFontDescriptor.SymbolicTraits) -> UIFont {
        fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(trait)).map { UIFont(descriptor: $0, size: 0) } ?? self
    }
}
