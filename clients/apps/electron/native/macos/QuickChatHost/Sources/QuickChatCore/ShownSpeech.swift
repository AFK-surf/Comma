import Foundation

/// The words Quick Chat shows while it listens. The live transcriber is quick
/// but rough; the exact one, whose words Enter sends, has them only once both
/// are finalized at a pause (`SpeechPause`). From then on the exact words
/// stand for everything said before that pause, and the live words for what
/// was said after it. So the words become what is sent sentence by
/// sentence, and editing or sending does not change them.
public struct ShownSpeech: Equatable, Sendable {
    /// Live words from `start` seconds of the audio on.
    struct Phrase: Equatable, Sendable {
        var start: Double
        var text: String
    }

    /// A live phrase begun this close before the pause is the next one: the
    /// live transcriber starts it where it was finalized, give or take a frame.
    static let samePoint = 0.1

    /// Text the speech continues, kept as it is (`SpeechText.draft`).
    public let draft: String
    /// The exact words, through the pause at `exactEnd` seconds.
    private var exact = ""
    private var exactEnd = 0.0
    /// Live phrases finalized since, and the one still being heard.
    private var live: [Phrase] = []
    private var volatile: Phrase?

    public init(draft: String = "") {
        self.draft = draft
    }

    /// A live result: a volatile one replaces the previous volatile words, a
    /// final one is kept. One begun before the exact words end is in them.
    public mutating func hear(_ text: String, from start: Double, isFinal: Bool) {
        let phrase = Phrase(start: start, text: text)
        guard isAfterExact(phrase) else { return }
        if isFinal {
            live.append(phrase)
            volatile = nil
        } else {
            volatile = phrase
        }
    }

    /// The exact words of everything said before the pause at `end` seconds.
    public mutating func hearExactly(_ text: String, through end: Double) {
        exact = text
        exactEnd = end
        live = live.filter(isAfterExact)
        volatile = volatile.flatMap { isAfterExact($0) ? $0 : nil }
    }

    /// What was said, without the draft.
    public var spoken: String {
        let heard = live.map(\.text) + [volatile?.text].compactMap { $0 }
        return SpeechText.normalized(heard.reduce(exact) { SpeechText.joined($0, $1) })
    }

    public var text: String {
        SpeechText.joined(draft, spoken)
    }

    private func isAfterExact(_ phrase: Phrase) -> Bool {
        phrase.start >= exactEnd - Self.samePoint
    }
}
