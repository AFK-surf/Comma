import Foundation

/// A character that opens a composer menu: `@` for Task mentions, `/` for skills and agent commands. The rules
/// follow the desktop matcher (`findAiInputMenuMatch`, ui richText.ts): a trigger opens its menu at the start of
/// the text or after whitespace, and the query runs from it to the caret without whitespace. A CJK input method
/// may commit the fullwidth ＠ or ／ instead; they open the same menu.
public enum ComposerTrigger: String, CaseIterable, Sendable {
    case mention = "@", skill = "/"

    /// The trigger `character` stands for, fullwidth forms included.
    public init?(_ character: Character) {
        switch character {
        case "@", "＠": self = .mention
        case "/", "／": self = .skill
        default: return nil
        }
    }
}

/// An open menu: its trigger, where it sits and what has been typed after it.
public struct ComposerTriggerMatch: Equatable, Sendable {
    public let trigger: ComposerTrigger
    /// From the trigger character to the caret, as indices of the text that was matched.
    public let range: Range<String.Index>
    public let query: String
}

/// A draft after a composer edit, with the caret to put back.
public struct ComposerEdit: Equatable, Sendable {
    public let text: String
    /// An insertion point in `text`, on a character boundary.
    public let caret: String.Index
}

/// What a tap on a trigger button does to the draft.
public enum ComposerTriggerToggle: Equatable, Sendable {
    case edit(ComposerEdit)
    /// The tapped trigger's menu is open on a query: close it and leave the text alone.
    case dismiss
}

extension ComposerTrigger {
    /// The menu `selection` opens in `text`. A nil selection is a caret at the end; a range, or a selection that
    /// does not fit `text`, opens nothing, as a non-collapsed selection does on the desktop.
    ///
    /// The candidate is the run between the last whitespace before the caret and the caret, so the cost follows
    /// the run, not the text. The run must start with a trigger that does not appear again in it, which is what
    /// the desktop's `lastIndexOf` amounts to: "/a/b" and "@a@b" open nothing, "@x/y" opens @ on "x/y".
    public static func match(in text: String, selection: Range<String.Index>?) -> ComposerTriggerMatch? {
        guard let selection else { return match(in: text, caret: text.endIndex) }
        guard selection.isEmpty, let caret = validated(selection, in: text)?.lowerBound else { return nil }
        return match(in: text, caret: caret)
    }

    /// A tap on `trigger`'s button. With the caret right after a bare trigger, the same button removes it and the
    /// other button swaps it; with a query after the same trigger, the tap closes the menu. Otherwise the ASCII
    /// trigger replaces the selection, or goes at the end when there is none or it does not fit, after a space
    /// unless it starts the text or follows whitespace. A menu closed with Escape is the app's to reopen.
    public static func toggling(_ trigger: ComposerTrigger, in text: String,
                                selection: Range<String.Index>?) -> ComposerTriggerToggle {
        let range = selection.flatMap { validated($0, in: text) } ?? text.endIndex..<text.endIndex
        if range.isEmpty, let open = match(in: text, caret: range.lowerBound) {
            switch (open.trigger == trigger, open.query.isEmpty) {
            case (true, true): return .edit(replacing(open.range, in: text, with: ""))
            case (true, false): return .dismiss
            case (false, true): return .edit(replacing(open.range, in: text, with: trigger.rawValue))
            case (false, false): break
            }
        }
        let needsSpace = range.lowerBound > text.startIndex && !text[text.index(before: range.lowerBound)].isWhitespace
        return .edit(replacing(range, in: text, with: (needsSpace ? " " : "") + trigger.rawValue))
    }

    /// `match` replaced by a picked row's `insertion`. With `trailingSpace` the caret lands after one whitespace:
    /// one that already follows is reused, otherwise a space is added. `match` must come from `text`.
    public static func completing(_ match: ComposerTriggerMatch, in text: String, with insertion: String,
                                  trailingSpace: Bool) -> ComposerEdit {
        let end = match.range.upperBound
        guard trailingSpace else { return replacing(match.range, in: text, with: insertion) }
        if end < text.endIndex, text[end].isWhitespace {
            return replacing(match.range.lowerBound..<text.index(after: end), in: text, with: insertion + String(text[end]))
        }
        return replacing(match.range, in: text, with: insertion + " ")
    }

    /// Whether `range` is a selection of `text`: within bounds, on character boundaries.
    public static func valid(_ range: Range<String.Index>, in text: String) -> Bool {
        validated(range, in: text) != nil
    }

    /// `range` as `text`'s own indices, or nil when it does not fit. A selection can outlive the text it was taken
    /// from: a send clears the draft, a restore or a Routine replaces it, and the router keeps one composer across
    /// conversations. Hand the returned range on rather than `range`. Never traps; the cost is the distance from
    /// the range's start to the end of the text.
    public static func validated(_ range: Range<String.Index>, in text: String) -> Range<String.Index>? {
        guard let upper = boundary(at: range.upperBound, in: text, from: text.endIndex),
              let lower = boundary(at: range.lowerBound, in: text, from: upper) else { return nil }
        return lower..<upper
    }

    private static func match(in text: String, caret: String.Index) -> ComposerTriggerMatch? {
        var start = caret
        while start > text.startIndex, !text[text.index(before: start)].isWhitespace { start = text.index(before: start) }
        guard start < caret, let trigger = ComposerTrigger(text[start]) else { return nil }
        let query = text[text.index(after: start)..<caret]
        guard !query.contains(text[start]) else { return nil }
        return ComposerTriggerMatch(trigger: trigger, range: start..<caret, query: String(query))
    }

    /// `text` with `range` replaced, the caret after the replacement. The seam is counted in UTF-8 so it is a
    /// position in the new string; the caret is the new string's last character boundary at or before it, which
    /// differs only when the seam fuses two characters.
    private static func replacing(_ range: Range<String.Index>, in text: String, with insertion: String) -> ComposerEdit {
        var result = String(text[..<range.lowerBound]) + insertion
        let offset = result.utf8.count
        result += text[range.upperBound...]
        let seam = result.utf8.index(result.utf8.startIndex, offsetBy: offset)
        var caret = result.endIndex
        while caret > seam { caret = result.index(before: caret) }
        return ComposerEdit(text: result, caret: caret)
    }

    /// `index` as one of `text`'s own character boundaries at or before `limit`, or nil.
    ///
    /// Only comparisons are safe on an index that may come from another string. The standard library's
    /// conversions trap on an index of the other encoding (UIKit hands the field UTF-16 strings, Swift edits build
    /// UTF-8 ones) that lies past the end of the view they convert through, and `String.Index(_:within:)` trusts
    /// the character alignment an index carries from the string that made it. So the boundary is found by walking
    /// `text`'s own boundaries back from `limit`. An index of the other encoding is read at its raw offset: never a
    /// trap, at worst a misplaced caret in non-ASCII text.
    private static func boundary(at index: String.Index, in text: String, from limit: String.Index) -> String.Index? {
        guard index <= limit else { return nil }
        var boundary = limit
        while boundary > index { boundary = text.index(before: boundary) }
        return boundary == index ? boundary : nil
    }
}
