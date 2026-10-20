import Foundation

/// How a call ended, as the caller sees it.
public enum VoiceCallResult: String, Sendable, Equatable {
    case ended, credentialsExpired, busy, unavailable, disabled, interrupted
}

/// One `comma.voice.v1` text message from Salix (docs/messaging-voice.md#websocket-voice-api).
public enum VoiceMessage: Sendable, Equatable, CustomStringConvertible {
    case started(callID: String, audioFormat: String, maxDurationSeconds: Int)
    case clear
    case mark(String)
    case transcript(role: String, text: String, final: Bool)
    case ended(reason: String, durationSeconds: Double?)
    case error(code: Int, message: String)

    /// Transcripts and server messages never reach logs.
    public var description: String {
        switch self {
        case .started: "started"
        case .clear: "clear"
        case .mark: "mark"
        case .transcript: "transcript([redacted])"
        case .ended(let reason, _): "ended(\(VoiceProtocol.diagnosticReason(reason)))"
        case .error(let code, _): "error(\(code))"
        }
    }
}

/// Wire codec with no audio, UI or transport dependency.
public enum VoiceProtocol {
    public static let subprotocol = "comma.voice.v1"
    public static let audioFormat = "pcm16_24k"
    public static let sampleRate = 24_000.0
    public static let maxFrameBytes = 16 * 1024
    /// 20 ms of 24 kHz mono PCM16.
    public static let frameBytes = 960
    public static let frameNanoseconds: UInt64 = 20_000_000

    public static func start(version: String, displayName: String? = nil) throws -> String {
        let client = "comma-ios/\(version)"
        guard !version.isEmpty, client.utf8.count <= 128 else { throw CommaError.invalidInput("Invalid client version.") }
        var message: [String: Any] = ["type": "session.start", "audio_format": audioFormat, "client": client]
        if let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            guard name.utf8.count <= 128 else { throw CommaError.invalidInput("Invalid display name.") }
            message["display_name"] = name
        }
        return try encode(message)
    }

    public static func played(_ name: String) -> String {
        (try? encode(["type": "output.played", "name": name])) ?? "{\"type\":\"output.played\"}"
    }

    public static let end = "{\"type\":\"session.end\"}"

    public static func validAudio(_ size: Int) -> Bool { (0...maxFrameBytes).contains(size) && size % 2 == 0 }

    /// Unknown types and fields, and malformed messages, are not application events.
    public static func decode(_ text: String) -> VoiceMessage? {
        let data = Data(text.utf8)
        guard data.count <= maxFrameBytes,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return nil }
        switch type {
        case "session.started":
            guard let id = json["call_id"] as? String, let format = json["audio_format"] as? String,
                  let limit = integer(json["max_duration_s"]) else { return nil }
            return .started(callID: id, audioFormat: format, maxDurationSeconds: limit)
        case "output.clear": return .clear
        case "output.mark":
            guard let name = json["name"] as? String else { return nil }
            return .mark(name)
        case "transcript":
            guard let role = json["role"] as? String, let text = json["text"] as? String,
                  let final = json["final"] as? Bool else { return nil }
            return .transcript(role: role, text: text, final: final)
        case "session.ended":
            guard let reason = json["reason"] as? String else { return nil }
            return .ended(reason: reason, durationSeconds: (json["duration_s"] as? NSNumber)?.doubleValue)
        case "error":
            guard let code = integer(json["code"]), let message = json["message"] as? String else { return nil }
            return .error(code: code, message: message)
        default: return nil
        }
    }

    /// An HTTP status or WebSocket close code.
    public static func result(code: Int?, reason: String? = nil) -> VoiceCallResult {
        switch code {
        case 1000: .ended
        case 401, 4401: .credentialsExpired
        case 409, 4409: .busy
        case 503, 4503: reason == "disabled" || reason == "voice calls are disabled" ? .disabled : .unavailable
        default: .interrupted
        }
    }

    /// An `error` always precedes a refusal or limit, even when the server then closes with 1000.
    public static func errorResult(code: Int, message: String) -> VoiceCallResult {
        let value = result(code: code, reason: message)
        return value == .ended ? .unavailable : value
    }

    /// The close reason is the server's end reason, which is more specific than the shared code.
    public static func closeResult(code: Int?, reason: String) -> VoiceCallResult {
        endReasons.contains(reason) ? endedResult(reason) : result(code: code, reason: reason)
    }

    public static func endedResult(_ reason: String) -> VoiceCallResult {
        switch reason {
        case "revoked": .credentialsExpired
        case "busy": .busy
        case "disabled": .disabled
        case "draining", "model_error", "unavailable", "node_full", "not_configured", "attach_timeout", "billing_unavailable":
            .unavailable
        case "bad_frame", "too_fast", "start_timeout", "idle_timeout", "pong_timeout", "slow_reader", "carrier_error", "other":
            .interrupted
        default: .ended
        }
    }

    /// A fixed vocabulary, safe for local diagnostics; any other text is reported as unrecognized.
    public static func diagnosticReason(_ reason: String) -> String { endReasons.contains(reason) ? reason : "unrecognized" }

    private static let endReasons: Set<String> = [
        "completed", "caller_hangup", "agent_hangup", "max_duration", "revoked", "busy", "disabled", "draining",
        "model_error", "unavailable", "node_full", "not_configured", "bad_frame", "too_fast", "start_timeout",
        "idle_timeout", "pong_timeout", "slow_reader", "carrier_error", "attach_timeout", "billing_unavailable", "other",
    ]

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.rounded() == double && abs(double) < 1e9 ? Int(double) : nil
    }

    private static func encode(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
}
