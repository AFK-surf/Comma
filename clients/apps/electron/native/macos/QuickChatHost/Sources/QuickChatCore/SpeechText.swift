import Foundation

/// The words said so far: committed segments, then the segment still being
/// recognized. A volatile result replaces the previous volatile text; a final
/// one is committed and starts the next segment.
public struct SpeechText: Equatable, Sendable {
    /// Text the speech continues, kept as it is: words kept from an earlier
    /// Quick Chat, or words the person edited.
    public let draft: String
    public private(set) var committed = ""
    public private(set) var volatile = ""

    public init(draft: String = "") {
        self.draft = draft
    }

    /// What was said, without the draft.
    public var spoken: String {
        Self.normalized(Self.joined(committed, volatile))
    }

    /// What is shown, and what Enter sends.
    public var text: String {
        Self.joined(draft, spoken)
    }

    public mutating func apply(_ segment: String, isFinal: Bool) {
        if isFinal {
            committed = Self.joined(committed, segment)
            volatile = ""
        } else {
            volatile = segment
        }
    }

    /// Joined in Comma's Chinese style (`needsSpace`): Latin words keep a
    /// space between segments, and so does an English sentence's end before
    /// the next ("reply. Then"); Chinese and a Latin word or digit get one,
    /// CJK text has none.
    public static func joined(_ head: String, _ tail: String) -> String {
        guard let last = head.last, let first = tail.first else { return head + tail }
        if last.isWhitespace || first.isWhitespace { return head + tail }
        let latin = (last.isLatinWordCharacter || ".,!?;:".contains(last)) && first.isLatinWordCharacter
        return latin || needsSpace(between: last, and: first, heard: false) ? head + " " + tail : head + tail
    }

    /// The recognizer separates its phrases with spaces, also inside Chinese
    /// ("清单 ，然后"), and spaces Chinese and English unevenly ("用Comma",
    /// "Figma里的"). Spaces follow `needsSpace`, runs of spaces become one,
    /// and fillers are left out.
    static func normalized(_ text: String) -> String {
        var result = ""
        var heardSpace = false
        for character in withoutFillers(text).trimmingCharacters(in: .whitespacesAndNewlines) {
            if character.isWhitespace {
                heardSpace = true
                continue
            }
            if let last = result.last, needsSpace(between: last, and: character, heard: heardSpace) {
                result.append(" ")
            }
            heardSpace = false
            result.append(character)
        }
        return result
    }

    /// Comma's Chinese style, as in its zh-CN text: one space between Chinese
    /// and a Latin word or digit, and after English punctuation before
    /// Chinese ("tonight. 这个"); none between two CJK characters or next to
    /// full-width punctuation. Elsewhere a space stays where it was heard.
    static func needsSpace(between last: Character, and next: Character, heard: Bool) -> Bool {
        guard last.isCJK || next.isCJK else { return heard }
        if last.isCJK { return last.isLetter && next.isLatinWordCharacter }
        return next.isLetter && (last.isLatinWordCharacter || ".,!?;:".contains(last))
    }

    /// Sounds made while thinking, never words: 呃 and 嗯 anywhere.
    static let fillerCharacters: Set<Character> = ["呃", "嗯"]
    /// Fillers as words of their own; inside a word they are words (金额, 好啊).
    static let fillerWords: Set<String> = ["额", "啊", "um", "umm", "uh", "uhh", "uhm", "er", "erm", "hm", "hmm"]

    /// `text` without fillers. A comma after one goes with it ("然后，呃，看"
    /// becomes "然后，看"), and so does a comma before one that ends a sentence.
    static func withoutFillers(_ text: String) -> String {
        let characters = Array(text)
        var result = ""
        var index = 0
        while index < characters.count {
            // A Latin word, or one character.
            let latin = characters[index].isLatinWordCharacter
            var end = index + 1
            if latin {
                while end < characters.count, characters[end].isLatinWordCharacter { end += 1 }
            }
            let token = String(characters[index..<end])
            let alone = (index == 0 || characters[index - 1].isBoundary)
                && (end == characters.count || characters[end].isBoundary)
            // "UM" and "ER" in capitals are names.
            let filler = latin
                ? fillerWords.contains(token.lowercased()) && token != token.uppercased()
                : fillerCharacters.contains(characters[index]) || alone && fillerWords.contains(token)
            guard filler else {
                result += token
                index = end
                continue
            }
            var next = end
            while next < characters.count, characters[next].isWhitespace { next += 1 }
            if next < characters.count, characters[next].isComma {
                next += 1
            } else if next == characters.count || characters[next].isPunctuation,
                      let last = result.lastIndex(where: { !$0.isWhitespace }), result[last].isComma {
                result.removeSubrange(last...)
            }
            index = next
        }
        return result
    }
}

extension Character {
    /// Han, kana, Hangul and the CJK punctuation and full-width forms.
    var isCJK: Bool {
        unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x1100...0x11FF, 0x2E80...0x2FDF, 0x3000...0x303F, 0x3040...0x30FF,
                 0x3100...0x312F, 0x3130...0x318F, 0x31A0...0x31FF, 0x3200...0x9FFF,
                 0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFFEF,
                 0x20000...0x3134F:
                return true
            default:
                return false
            }
        }
    }

    var isLatinWordCharacter: Bool {
        !isCJK && (isLetter || isNumber)
    }

    var isComma: Bool {
        "，,、".contains(self)
    }

    /// Where a word ends: a space or punctuation.
    var isBoundary: Bool {
        isWhitespace || isPunctuation
    }
}
