import SwiftUI
import UIKit

extension View {
    /// Shows the picks in the composer's field (`ConversationPane.pickRanges`) in the brand colour. Apply it to a
    /// view around the field, not to the field: a view laid behind the field itself would take the field's
    /// accessibility identifier from it. `ranges` holds the picks of `text`, read in the
    /// view's body so a change to what counts as a pick (the skills catalog loading) draws them again; `rangesIn`
    /// reads them from text the field holds that the draft does not hold yet, as while typing. `hidden` follows the
    /// field's own text while the fill wave hides it.
    func pickTint(text: String, ranges: [Range<String.Index>], hidden: Bool,
                  rangesIn: @escaping (String) -> [Range<String.Index>]) -> some View {
        background(PickTint(picks: Picks(text: text, ranges: ranges.map { NSRange($0, in: text) }, hidden: hidden,
                                         rangesIn: rangesIn))
            // Nothing to read or find: the field, its identifier and its focus stay one element.
            .accessibilityHidden(true))
    }
}

/// A SwiftUI text field has no colour per range, so this colours its text view's own text: the picks in the brand
/// colour, the rest in the text colour. The view sits behind the field's container, finds the one editable text view
/// inside it, and becomes its text storage's delegate, which colours every edit before it is laid out and drawn:
/// typing, a pick, and SwiftUI writing the text or its colour again (as it does when the appearance changes). The
/// caret, the selection and a word still being composed stay the field's own.
private struct PickTint: UIViewRepresentable {
    let picks: Picks

    func makeUIView(context: Context) -> PickTintView { PickTintView() }

    func updateUIView(_ view: PickTintView, context: Context) {
        view.picks = picks
        view.tint()
    }

    static func dismantleUIView(_ view: PickTintView, coordinator: ()) { view.release() }
}

private struct Picks {
    let text: String
    let ranges: [NSRange]
    let hidden: Bool
    let rangesIn: (String) -> [Range<String.Index>]

    func ranges(for string: String) -> [NSRange] {
        string == text ? ranges : rangesIn(string).map { NSRange($0, in: string) }
    }
}

private final class PickTintView: UIView, NSTextStorageDelegate {
    var picks: Picks?
    private weak var field: UITextView?
    /// Made once, so a run already coloured compares equal and is left alone.
    private static let text = UIColor(CommaTheme.textPrimary)
    private static let brand = UIColor(CommaTheme.brandSolid)

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { release() } else { tint() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        tint()
    }

    /// Hands the text storage back.
    func release() {
        if field?.textStorage.delegate === self { field?.textStorage.delegate = nil }
        field = nil
    }

    /// Colours the field's text now, for a change that edits no text: the picks or the fill wave's hiding. It opens an
    /// edit only when a colour is wrong.
    func tint() {
        guard let storage = locate()?.textStorage, !wrongRuns(of: storage).isEmpty else { return }
        storage.beginEditing()
        colour(storage)
        storage.endEditing()
    }

    nonisolated func textStorage(_ textStorage: NSTextStorage, willProcessEditing editedMask: NSTextStorage.EditActions,
                                 range editedRange: NSRange, changeInLength delta: Int) {
        // Text storage is edited on the main thread, where its text view lives.
        nonisolated(unsafe) let storage = textStorage
        MainActor.assumeIsolated { colour(storage) }
    }

    /// The picks in the brand colour and the rest in the text colour, both clear while the field hides its text.
    /// Only a run whose colour differs changes, compared as drawn, so the text colour SwiftUI writes as the member types
    /// is left alone and plain typing edits nothing. A word still being composed is left as the keyboard draws it, and
    /// coloured once it is committed.
    private func colour(_ storage: NSTextStorage) {
        guard let field else { return }
        for (range, color) in wrongRuns(of: storage) { storage.addAttribute(.foregroundColor, value: color, range: range) }
        // What is typed next takes the text colour, even straight after a pick.
        guard let picks, field.markedTextRange == nil else { return }
        let base = picks.hidden ? UIColor.clear : Self.text
        if !Self.same(field.typingAttributes[.foregroundColor] as? UIColor, base, traits: field.traitCollection) {
            field.typingAttributes[.foregroundColor] = base
        }
    }

    /// The runs of the field's text whose colour is wrong, with the colour each should have.
    private func wrongRuns(of storage: NSTextStorage) -> [(NSRange, UIColor)] {
        guard let picks, let field, field.textStorage === storage, field.markedTextRange == nil else { return [] }
        let base = picks.hidden ? UIColor.clear : Self.text
        let brand = picks.hidden ? UIColor.clear : Self.brand
        return Self.runs(length: storage.length, picks: picks.ranges(for: storage.string), base: base, brand: brand)
            .filter { !Self.holds(storage, $0.1, in: $0.0, traits: field.traitCollection) }
    }

    /// The text as runs of one colour: the picks, merged where they meet, in the brand colour, the rest in `base`.
    private static func runs(length: Int, picks: [NSRange], base: UIColor, brand: UIColor) -> [(NSRange, UIColor)] {
        var runs: [(NSRange, UIColor)] = [], cursor = 0
        for pick in picks.filter({ NSMaxRange($0) <= length }).sorted(by: { $0.location < $1.location }) {
            let start = max(pick.location, cursor), end = NSMaxRange(pick)
            guard end > start else { continue }
            if start > cursor { runs.append((NSRange(location: cursor, length: start - cursor), base)) }
            if let last = runs.last, last.1 === brand, NSMaxRange(last.0) == start {
                runs[runs.count - 1].0.length += end - start
            } else {
                runs.append((NSRange(location: start, length: end - start), brand))
            }
            cursor = end
        }
        if cursor < length { runs.append((NSRange(location: cursor, length: length - cursor), base)) }
        return runs
    }

    /// Whether all of `range` is drawn in `color`.
    private static func holds(_ storage: NSTextStorage, _ color: UIColor, in range: NSRange, traits: UITraitCollection) -> Bool {
        var holds = true
        storage.enumerateAttribute(.foregroundColor, in: range) { value, _, stop in
            if !same(value as? UIColor, color, traits: traits) { holds = false; stop.pointee = true }
        }
        return holds
    }

    /// Whether two colours draw alike in `traits`, whatever their make: SwiftUI writes its own resolved colour.
    private static func same(_ color: UIColor?, _ other: UIColor, traits: UITraitCollection) -> Bool {
        guard let color else { return false }
        if color === other { return true }
        var a = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0)), b = a
        color.resolvedColor(with: traits).getRed(&a.0, green: &a.1, blue: &a.2, alpha: &a.3)
        other.resolvedColor(with: traits).getRed(&b.0, green: &b.1, blue: &b.2, alpha: &b.3)
        return abs(a.0 - b.0) < 0.004 && abs(a.1 - b.1) < 0.004 && abs(a.2 - b.2) < 0.004 && abs(a.3 - b.3) < 0.004
    }

    /// The field: the editable text view centred inside this view (text in the transcript is never editable), kept
    /// while it stays in the window, as it may run past this view while the card grows a line. It is looked for again
    /// once it leaves, as SwiftUI may replace it. A text storage with a delegate of its own is left alone.
    private func locate() -> UITextView? {
        guard let window, bounds.width > 0 else { return nil }
        if let field, field.window === window { return field }
        release()
        let mine = convert(bounds, to: window)
        func inside(_ view: UITextView) -> Bool {
            let frame = view.convert(view.bounds, to: window)
            return view.isEditable && mine.contains(CGPoint(x: frame.midX, y: frame.midY))
        }
        var ancestor = superview
        while let current = ancestor {
            if let found = Self.textViews(in: current).first(where: inside) {
                guard found.textStorage.delegate == nil else { return nil }
                found.textStorage.delegate = self
                field = found
                return found
            }
            ancestor = current.superview
        }
        return nil
    }

    private static func textViews(in view: UIView) -> [UITextView] {
        if let textView = view as? UITextView { return [textView] }
        return view.subviews.flatMap(textViews)
    }
}
