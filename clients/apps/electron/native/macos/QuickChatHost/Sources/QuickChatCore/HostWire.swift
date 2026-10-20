import Foundation

/// Main → QuickChatHost, one JSON object per stdin line.
public enum HostCommand: Decodable, Equatable, Sendable {
    /// The interface text in Comma's language. Sent first, and again when it changes.
    case configure(QuickChatStrings)
    /// Whether the Message for a `submit` was accepted.
    case result(requestId: String, ok: Bool, message: String?)
    /// The server's words for a `transcribe`; nil when it could not transcribe it.
    case transcript(clipId: String, text: String?)
    /// The person clicked the menu-bar item: listen, as a double tap of ⌘ does.
    case listen

    private enum CodingKeys: String, CodingKey {
        case type, strings, requestId, ok, message, clipId, text
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "configure":
            self = .configure(try container.decode(QuickChatStrings.self, forKey: .strings))
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
        case let type:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container, debugDescription: "Unknown command \(type)"
            )
        }
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
    /// Over the words while they are edited: a tap of ⌘ listens again.
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
        }
    }
}
