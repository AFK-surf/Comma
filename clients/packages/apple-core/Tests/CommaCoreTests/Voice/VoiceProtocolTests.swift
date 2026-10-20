import Foundation
import Testing
@testable import CommaCore

@Suite("comma.voice.v1 wire codec")
struct VoiceProtocolTests {
    @Test func startNamesTheFormatAndClient() throws {
        let json = try #require(JSONSerialization.jsonObject(with: Data(try VoiceProtocol.start(version: "1.0.2", displayName: "  Ada ").utf8)) as? [String: String])
        #expect(json == ["type": "session.start", "audio_format": "pcm16_24k", "client": "comma-ios/1.0.2", "display_name": "Ada"])
        #expect(throws: CommaError.self) { try VoiceProtocol.start(version: "") }
    }

    @Test func decodesServerMessagesAndIgnoresTheRest() {
        #expect(VoiceProtocol.decode(startedJSON) == .started(callID: "call-1", audioFormat: "pcm16_24k", maxDurationSeconds: 1800))
        #expect(VoiceProtocol.decode(#"{"type":"output.mark","name":"m1","extra":1}"#) == .mark("m1"))
        #expect(VoiceProtocol.decode(#"{"type":"transcript","role":"agent","text":"Hi","final":true}"#) == .transcript(role: "agent", text: "Hi", final: true))
        #expect(VoiceProtocol.decode(#"{"type":"session.ended","reason":"completed","duration_s":null}"#) == .ended(reason: "completed", durationSeconds: nil))
        #expect(VoiceProtocol.decode(#"{"type":"error","code":4409,"message":"busy"}"#) == .error(code: 4409, message: "busy"))
        #expect(VoiceProtocol.decode(#"{"type":"future.thing"}"#) == nil)
        #expect(VoiceProtocol.decode(#"{"type":"output.mark"}"#) == nil)
        #expect(VoiceProtocol.decode(#"{"type":"error","code":true,"message":"x"}"#) == nil)
        #expect(VoiceProtocol.decode("not json") == nil)
        #expect(VoiceProtocol.decode(String(repeating: " ", count: VoiceProtocol.maxFrameBytes + 1)) == nil)
    }

    @Test func endsMapToWhatTheCallerIsTold() {
        #expect(VoiceProtocol.endedResult("agent_hangup") == .ended)
        #expect(VoiceProtocol.endedResult("revoked") == .credentialsExpired)
        #expect(VoiceProtocol.endedResult("draining") == .unavailable)
        #expect(VoiceProtocol.endedResult("idle_timeout") == .interrupted)
        // A refusal is an error frame first, even when the server then closes with 1000.
        #expect(VoiceProtocol.errorResult(code: 1000, message: "busy") == .unavailable)
        #expect(VoiceProtocol.errorResult(code: 4503, message: "disabled") == .disabled)
        #expect(VoiceProtocol.closeResult(code: nil, reason: "busy") == .busy)
        #expect(VoiceProtocol.closeResult(code: 4401, reason: "") == .credentialsExpired)
        #expect(VoiceProtocol.diagnosticReason("secret text") == "unrecognized")
    }
}
