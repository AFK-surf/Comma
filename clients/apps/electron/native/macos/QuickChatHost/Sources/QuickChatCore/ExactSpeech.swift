/// What the exact transcribers heard, one transcript per language, and the
/// pauses where both finalized. The words between two pauses are told in the
/// language they were spoken in, so a Chinese sentence and an English one
/// each come out right:
///
/// - A transcript mostly not in its language's script heard another
///   language. zh-CN writes English speech in Latin letters, confidently; it
///   counts only when no transcript is in its own script.
/// - Of the rest, the more confident one with words, the person's language
///   (the first) on a tie. Chinese and mixed sentences score higher in zh-CN,
///   English ones in en-US.
///
/// Natural pauses and the length limit close adjacent server clips, preferably
/// at a completed phrase boundary. Each answer replaces only that clip's
/// device words, in audio order. A failed clip keeps its device words.
public struct ExactSpeech: Sendable {
    /// Final words over seconds `start`…`end` of the audio. Both transcribers
    /// hear the same audio, so their times compare.
    public struct Segment: Sendable {
        let start: Double
        let end: Double
        let text: String
        let confidences: [Double]
        let continuesPrevious: Bool

        public init(
            start: Double, end: Double, text: String, confidences: [Double],
            continuesPrevious: Bool = false
        ) {
            self.start = start
            self.end = end
            self.text = text
            self.confidences = confidences
            self.continuesPrevious = continuesPrevious
        }
    }

    /// The most audio one clip carries, in seconds: what goes to the server
    /// grows with the time spoken, not with its square.
    public static let clipLength = 60.0

    /// The server's words for the audio over `clip`.
    private struct Heard: Sendable {
        let clip: Range<Double>
        let text: String
    }

    /// A stretch of audio: the server's words for a clip, or each
    /// transcript's segments between two pauses.
    private enum Piece {
        case server(String)
        case device([[Segment]])
    }

    /// Per transcript: whether its language is written in CJK characters.
    private let writesCJK: [Bool]
    private var segments: [[Segment]]
    private var pauses: [Double] = []
    /// The server's words so far, by clip, in the order of the audio.
    private var heard: [Heard] = []

    public init(writesCJK: [Bool]) {
        self.writesCJK = writesCJK
        segments = writesCJK.map { _ in [] }
    }

    public mutating func add(_ segment: Segment, from transcript: Int) {
        segments[transcript].append(segment)
    }

    /// A clip checkpoint used to assemble words from the two languages.
    public mutating func pause(at seconds: Double) {
        guard !pauses.contains(seconds) else { return }
        pauses.append(seconds)
    }

    /// Prefer a completed phrase near the length limit. Both languages must
    /// agree that no completed phrase crosses it; otherwise use the limit.
    public func checkpoint(after start: Double, through limit: Double) -> Double {
        let earliest = max(start, limit - 10)
        // Final result runs arrive in audio order. Older history cannot cross
        // a candidate here, so only inspect the last ten seconds of runs.
        let all = segments.flatMap { $0.reversed().prefix { $0.end > earliest } }
        return all.map(\.end).filter { end in
            end > earliest && end <= limit &&
                !all.contains { $0.start < end && $0.end > end }
        }.max() ?? limit
    }

    /// The server's words for the audio over `clip`, one the recording queue
    /// requested. Words without any change nothing.
    public mutating func hearFromServer(_ text: String, for clip: Range<Double>) {
        guard Self.hasWords(text) else { return }
        heard.removeAll { $0.clip == clip }
        let after = heard.firstIndex { $0.clip.lowerBound >= clip.upperBound } ?? heard.endIndex
        heard.insert(Heard(clip: clip, text: text), at: after)
    }

    /// What was said; nil while no transcript has words.
    public var text: String? {
        text(through: .infinity)
    }

    /// What was said before the pause at `seconds`; nil while no transcript has words.
    public func text(through seconds: Double) -> String? {
        var text = SpeechText()
        var spoke = false
        for piece in pieces(through: seconds) {
            switch piece {
            case .server(let words):
                text.apply(words, isFinal: true)
            case .device(let stretch):
                guard let chosen = chosen(stretch) else { continue }
                var phrases: [String] = []
                for segment in stretch[chosen] {
                    if segment.continuesPrevious, !phrases.isEmpty {
                        phrases[phrases.count - 1] += segment.text
                    } else {
                        phrases.append(segment.continuesPrevious ? segment.text : String(segment.words))
                    }
                }
                for phrase in phrases { text.apply(phrase, isFinal: true) }
            }
            spoke = true
        }
        return spoke ? text.spoken : nil
    }

    /// The audio before `seconds` in order: the server's words where it
    /// heard a clip that ends by then, the device's stretches elsewhere.
    private func pieces(through seconds: Double) -> [Piece] {
        var pieces: [Piece] = []
        var from = 0.0
        for heard in heard where heard.clip.upperBound <= seconds {
            pieces += stretches(from: from, to: heard.clip.lowerBound)
            pieces.append(.server(heard.text))
            from = heard.clip.upperBound
        }
        return pieces + stretches(from: from, to: seconds)
    }

    /// The device's stretches between `from` and `to`, one per pause in
    /// between, and the words still being said when `to` is unbounded.
    private func stretches(from: Double, to: Double) -> [Piece] {
        var from = from
        var pieces: [Piece] = []
        for to in pauses.filter({ $0 > from && $0 <= to }).sorted() + (to == .infinity ? [.infinity] : []) {
            pieces.append(.device(stretch(from: from, to: to)))
            from = to
        }
        return pieces
    }

    /// Each transcript's segments between two pauses.
    private func stretch(from: Double, to: Double) -> [[Segment]] {
        segments.map { $0.filter { from < $0.middle && $0.middle <= to } }
    }

    private func chosen(_ stretch: [[Segment]]) -> Int? {
        let spoken = stretch.indices.filter { stretch[$0].contains { Self.hasWords($0.text) } }
        let native = spoken.filter { Self.isMostly(cjk: writesCJK[$0], stretch[$0]) }
        var best: Int?
        for index in native.isEmpty ? spoken : native {
            if best.map({ Self.confidence(stretch[index]) > Self.confidence(stretch[$0]) }) ?? true { best = index }
        }
        return best
    }

    /// Han, kana and Hangul letters against Latin words.
    private static func isMostly(cjk: Bool, _ segments: [Segment]) -> Bool {
        var characters = 0
        var words = 0
        var inWord = false
        for character in segments.map(\.text).joined(separator: " ") {
            if character.isCJK, character.isLetter { characters += 1 }
            let latin = character.isLatinWordCharacter && character.isLetter
            if latin, !inWord { words += 1 }
            inWord = latin
        }
        return cjk ? characters >= words : words >= characters
    }

    /// Fillers alone (嗯, um) are no words.
    private static func hasWords(_ text: String) -> Bool {
        SpeechText.withoutFillers(text).contains { $0.isLetter || $0.isNumber }
    }

    private static func confidence(_ segments: [Segment]) -> Double {
        let all = segments.flatMap(\.confidences)
        return all.isEmpty ? 0 : all.reduce(0, +) / Double(all.count)
    }
}

extension ExactSpeech.Segment {
    var middle: Double { (start + end) / 2 }

    /// Its text without the punctuation en-US can start one with ("... Remind me").
    var words: Substring { text.drop { $0.isPunctuation || $0.isWhitespace } }
}
