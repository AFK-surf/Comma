#if os(macOS)
import Foundation
import Testing
@testable import CommaCore

/// SalixWeb's integration test supplies a live HTTP listener and a fake model.
@Suite("HTTPS voice end to end")
struct HTTPVoiceIntegrationTests {
    private struct Credentials: VoiceCredentialSource {
        let endpointValue: VoiceEndpoint
        func endpoint() async throws -> VoiceEndpoint { endpointValue }
        func invalidate() async {}
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["COMMA_VOICE_HTTP_TEST_URL"] != nil))
    func realServerPlaysClearsAcknowledgesAndHangsUp() async throws {
        let env = ProcessInfo.processInfo.environment
        let base = try #require(env["COMMA_VOICE_HTTP_TEST_URL"])
        let key = try #require(env["COMMA_VOICE_HTTP_TEST_KEY"])
        let endpoint = try VoiceEndpoint(sessionsURL: base.replacingOccurrences(of: "http://", with: "ws://") + "/sessions",
                                         readinessURL: base, bearer: key)
        let sink = FakeSpeaker()
        let session = try VoiceSession(credentials: Credentials(endpointValue: endpoint),
            transport: HTTPVoiceTransport(), sink: sink, version: "http-integration")
        let states = VoiceStates(session)
        let (signals, continuation) = AsyncStream<Void>.makeStream()
        session.onDiagnostic = { _ in continuation.finish() }
        session.onTranscript = { _, _, _ in continuation.yield(()) }
        session.start()
        var signal = signals.makeAsyncIterator()
        _ = await signal.next()
        #expect(sink.played.contains(Data([1, 0])))
        sink.playOut()
        session.offerAudio(Data(repeating: 42, count: 960))
        _ = await signal.next()
        #expect(session.snapshot().state.phase == .connected)
        #expect(sink.played.contains(Data([1, 0])))
        #expect(sink.played.contains(Data([2, 0])))
        #expect(sink.clearCount >= 2)
        sink.playOut()
        #expect(session.snapshot().stats.acknowledgedMarks >= 1)
        session.hangUp()
        let ended = await states.next { $0.phase == .ended || $0.phase == .failed }
        #expect(ended?.result == .ended)
        continuation.finish()
        session.close()
    }
}
#endif
