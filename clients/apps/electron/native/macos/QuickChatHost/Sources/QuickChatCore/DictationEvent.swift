import Foundation

/// What live dictation's socket says (`CommaWeb.DictationSocket`), and
/// `unavailable` when it failed or there is none.
public enum DictationEvent: Equatable, Sendable {
    /// A segment's words so far, the whole segment each time.
    case partial(segment: Int, text: String)
    /// A segment's settled words.
    case final(segment: Int, text: String)
    /// Every segment is final after `end`.
    case done
    case unavailable

    private struct Wire: Decodable {
        var type: String
        var segment: Int?
        var text: String?
    }

    /// One text message of the socket; nil for one this does not know.
    public init?(message: String) {
        guard let wire = try? JSONDecoder().decode(Wire.self, from: Data(message.utf8)) else { return nil }
        switch (wire.type, wire.segment, wire.text) {
        case let ("partial", segment?, text?): self = .partial(segment: segment, text: text)
        case let ("final", segment?, text?): self = .final(segment: segment, text: text)
        case ("done", _, _): self = .done
        default: return nil
        }
    }
}
