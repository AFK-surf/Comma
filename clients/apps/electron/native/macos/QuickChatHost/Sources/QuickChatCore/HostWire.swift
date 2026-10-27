import Foundation

/// Main → QuickChatHost, one JSON object per stdin line.
public enum HostCommand: Decodable, Equatable, Sendable {
    /// The interface text in Comma's language, and the modifier whose double tap
    /// opens Quick Chat (nil: a global shortcut Main holds opens it). Sent
    /// first, and again when either changes.
    case configure(QuickChatStrings, tap: TapModifier?)
    /// Whether the Message for a `submit` was accepted.
    case result(requestId: String, ok: Bool, message: String?)
    /// The server's words for a `transcribe`; nil when it could not transcribe it.
    case transcript(clipId: String, text: String?)
    /// The ticket for a `dictationTicket`; nil when there is no live dictation now.
    case dictationTicket(requestId: String, ticket: DictationTicket?)
    /// The menu-bar item or Quick Chat's global shortcut: listen, as a double tap does.
    case listen

    private enum CodingKeys: String, CodingKey {
        case type, strings, tap, requestId, ok, message, clipId, text, url, ticket
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "configure":
            // A configure without `tap` keeps ⌘.
            self = .configure(
                try container.decode(QuickChatStrings.self, forKey: .strings),
                tap: container.contains(.tap) ? try container.decodeIfPresent(TapModifier.self, forKey: .tap) : .meta
            )
        case "result":
            self = .result(
                requestId: try container.decode(String.self, forKey: .requestId),
                ok: try container.decode(Bool.self, forKey: .ok),
                message: try container.decodeIfPresent(String.self, forKey: .message)
            )
        case "listen":
            self = .listen
        case "transcript":
            self = .transcript(
                clipId: try container.decode(String.self, forKey: .clipId),
                text: try container.decodeIfPresent(String.self, forKey: .text)
            )
        case "dictationTicket":
            let url = try container.decodeIfPresent(String.self, forKey: .url)
            let ticket = try container.decodeIfPresent(String.self, forKey: .ticket)
            self = .dictationTicket(
                requestId: try container.decode(String.self, forKey: .requestId),
                ticket: url.flatMap { url in ticket.map { DictationTicket(url: url, ticket: $0) } }
            )
        case let type:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container, debugDescription: "Unknown command \(type)"
            )
        }
    }
}

/// A modifier whose double tap opens Quick Chat, as Main names it.
public enum TapModifier: String, Decodable, Equatable, Sendable {
    case alt, control, meta, shift
}

/// Where live dictation's socket is (`/v1/comma/dictation`), and the one-use ticket that opens it.
public struct DictationTicket: Equatable, Sendable {
    public var url: String
    public var ticket: String

    public init(url: String, ticket: String) {
        self.url = url
        self.ticket = ticket
    }
}

public struct QuickChatStrings: Codable, Equatable, Sendable {
    /// Shown in the text area until the first words arrive.
    public var listening: String
    /// The buttons' labels for VoiceOver: close (Esc) and send (Return).
    public var close: String
    public var send: String
    /// While macOS downloads the speech model for the language.
    public var preparing: String
    public var microphoneDenied: String
    public var speechUnavailable: String
    /// The send failed; it waits in the Notch to be sent again.
    public var sendFailed: String
    /// Over the words while they are edited: a tap of the modifier (or the shortcut) listens again.
    public var resume: String

    public init(
        listening: String, close: String, send: String, preparing: String,
        microphoneDenied: String, speechUnavailable: String, sendFailed: String, resume: String
    ) {
        self.listening = listening
        self.close = close
        self.send = send
        self.preparing = preparing
        self.microphoneDenied = microphoneDenied
        self.speechUnavailable = speechUnavailable
        self.sendFailed = sendFailed
        self.resume = resume
    }

    /// Until Main's `configure` arrives.
    public static let english = QuickChatStrings(
        listening: "Listening…",
        close: "Close",
        send: "Send",
        preparing: "Preparing speech recognition…",
        microphoneDenied: "Allow Comma to use the microphone in System Settings.",
        speechUnavailable: "Speech recognition is unavailable.",
        sendFailed: "Couldn’t send. Try again from the Notch.",
        resume: "Press ⌘ to continue"
    )
}

/// QuickChatHost → Main, one JSON object per stdout line.
public enum HostEvent: Encodable, Equatable, Sendable {
    case ready
    /// Enter was pressed. Main shows the pending send while its clips finish.
    case preparing(requestId: String, text: String, update: Bool = false)
    /// Enter was pressed on this text; Main sends the Message and answers `result`.
    /// `audio` (M4A, base64 on the wire) is what the microphone heard after
    /// `draft`, for the server to transcribe; `text` is sent when it cannot.
    /// A prepared submit is valid only while Main still holds its pending send.
    case submit(requestId: String, text: String, draft: String, audio: Data?, prepared: Bool = false)
    /// One audio clip (M4A, base64). Send-time clips wait for transcription admission.
    case transcribe(clipId: String, audio: Data, waitForSlot: Bool = false)
    /// A ticket for live dictation, answered by the command of the same name.
    case dictationTicket(requestId: String)

    private enum CodingKeys: String, CodingKey {
        case type, requestId, text, draft, audio, clipId, prepared, update, waitForSlot
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ready:
            try container.encode("ready", forKey: .type)
        case let .preparing(requestId, text, update):
            try container.encode("preparing", forKey: .type)
            try container.encode(requestId, forKey: .requestId)
            try container.encode(text, forKey: .text)
            if update { try container.encode(true, forKey: .update) }
        case let .submit(requestId, text, draft, audio, prepared):
            try container.encode("submit", forKey: .type)
            try container.encode(requestId, forKey: .requestId)
            try container.encode(text, forKey: .text)
            try container.encode(draft, forKey: .draft)
            try container.encodeIfPresent(audio, forKey: .audio)
            if prepared { try container.encode(true, forKey: .prepared) }
        case let .transcribe(clipId, audio, waitForSlot):
            try container.encode("transcribe", forKey: .type)
            try container.encode(clipId, forKey: .clipId)
            try container.encode(audio, forKey: .audio)
            if waitForSlot { try container.encode(true, forKey: .waitForSlot) }
        case let .dictationTicket(requestId):
            try container.encode("dictationTicket", forKey: .type)
            try container.encode(requestId, forKey: .requestId)
        }
    }
}
