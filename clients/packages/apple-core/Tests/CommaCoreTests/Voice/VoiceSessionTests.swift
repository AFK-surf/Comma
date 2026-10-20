import Foundation
import Testing
@testable import CommaCore

@Suite("Voice call session")
struct VoiceSessionTests {
    private func call(_ transport: FakeVoiceTransport = FakeVoiceTransport(), speaker: FakeSpeaker = FakeSpeaker(),
                      credentials: FakeVoiceCredentials = FakeVoiceCredentials(),
                      scheduler: ManualVoiceScheduler = ManualVoiceScheduler()) throws -> VoiceSession {
        try VoiceSession(credentials: credentials, transport: transport, sink: speaker, version: "1.0", scheduler: scheduler)
    }

    /// Starts a call and returns its open socket.
    private func open(_ session: VoiceSession, _ transport: FakeVoiceTransport, index: Int = 0) async throws -> FakeVoiceSocket {
        session.start()
        let socket = await transport.socket(index)
        socket.open()
        drain(session)
        #expect(!socket.texts.isEmpty)
        return socket
    }

    @Test func readinessFailureRetainsNetworkCodeForDeviceDiagnostics() async throws {
        let transport = FakeVoiceTransport(readiness: [VoiceFailure(.interrupted, networkCode: -1009)])
        let session = try call(transport)
        let (diagnostics, continuation) = AsyncStream<String>.makeStream()
        session.onDiagnostic = { continuation.yield($0) }
        let states = VoiceStates(session)
        session.start()
        let state = await states.next { $0.phase == .failed }
        #expect(state?.result == .interrupted)
        var iterator = diagnostics.makeAsyncIterator()
        #expect(await iterator.next() == "prepare_failed stage=readiness result=interrupted network=-1009")
        #expect(transport.sockets.isEmpty)
        session.close()
        continuation.finish()
    }

    @Test func startFrameComesFirstThenPacedAudioAndSilenceWhileMuted() async throws {
        let transport = FakeVoiceTransport(), clock = ManualVoiceScheduler()
        let session = try call(transport, scheduler: clock)
        let socket = try await open(session, transport)
        #expect(textTypes(socket) == ["session.start"])
        #expect(session.snapshot().state.phase == .calling)
        #expect(socket.audio.isEmpty)

        var voice = Data(count: VoiceProtocol.frameBytes)
        voice[0] = 7
        session.offerAudio(voice)
        session.offerAudio(Data(count: 10)) // Not a 20 ms frame.
        clock.advance(frames: 2)
        #expect(socket.audio == [voice, Data(count: VoiceProtocol.frameBytes)])

        session.setMuted(true)
        session.offerAudio(voice)
        clock.advance(frames: 3)
        #expect(socket.audio.count == 5)
        #expect(socket.audio.dropFirst(2).allSatisfy { $0 == Data(count: VoiceProtocol.frameBytes) })

        session.setMuted(false)
        session.offerAudio(voice)
        clock.advance(frames: 1)
        #expect(socket.audio.last == voice)
        #expect(session.snapshot().stats.sentFrames == 6)
    }

    @Test func connectsOnlyOnceTheServerStartedAndItsAudioArrived() async throws {
        let transport = FakeVoiceTransport(), speaker = FakeSpeaker()
        let session = try call(transport, speaker: speaker)
        let socket = try await open(session, transport)
        socket.server(startedJSON)
        #expect(session.snapshot().state.startedByServer)
        #expect(session.snapshot().state.phase == .calling)
        socket.emit(.binary(Data(count: 480)))
        #expect(session.snapshot().state.phase == .connected)
        #expect(speaker.played == [Data(count: 480)])
        #expect(session.snapshot().state.maxDurationSeconds == 1800)
    }

    @Test func marksAreAcknowledgedOnlyOncePlayedAndClearAcknowledgesTheRest() async throws {
        let transport = FakeVoiceTransport(), speaker = FakeSpeaker()
        let session = try call(transport, speaker: speaker)
        let socket = try await open(session, transport)
        socket.emit(.binary(Data(count: 960)))
        socket.server(#"{"type":"output.mark","name":"a"}"#)
        drain(session)
        #expect(speaker.markCount == 1)
        #expect(!textTypes(socket).contains("output.played"))
        speaker.playOut()
        drain(session)
        #expect(socket.texts.contains(#"{"name":"a","type":"output.played"}"#))

        socket.server(#"{"type":"output.mark","name":"b"}"#)
        socket.server(#"{"type":"output.mark","name":"c"}"#)
        socket.server(#"{"type":"output.clear"}"#)
        drain(session)
        #expect(textTypes(socket).filter { $0 == "output.played" }.count == 3)
        #expect(speaker.clearCount >= 1)
        // A late playback callback for a cleared mark sends nothing more.
        speaker.playOut()
        drain(session)
        #expect(textTypes(socket).filter { $0 == "output.played" }.count == 3)
    }

    @Test func anExpiredKeyIsReplacedOnceThenTheCallFails() async throws {
        let transport = FakeVoiceTransport(), credentials = FakeVoiceCredentials()
        let session = try call(transport, credentials: credentials)
        let states = VoiceStates(session)
        _ = try await open(session, transport)
        transport.sockets[0].emit(.failed(status: 401))
        let retry = await transport.socket(1)
        drain(session)
        #expect(credentials.counts == (endpoint: 2, invalidate: 1))
        #expect(transport.sockets[0].cancelled)
        #expect(session.snapshot().state.phase == .calling)

        retry.emit(.closed(code: nil, reason: "revoked"))
        let failed = await states.next { $0.phase == .failed }
        #expect(failed?.result == .credentialsExpired)
        #expect(credentials.counts == (endpoint: 2, invalidate: 2))
        #expect(transport.sockets.count == 2)
    }

    /// A key revoked once the call is under way ends the call; it is not redialed with a fresh key.
    @Test func aKeyRevokedDuringTheCallEndsItWithoutRedialing() async throws {
        let transport = FakeVoiceTransport(), credentials = FakeVoiceCredentials()
        let session = try call(transport, credentials: credentials)
        let states = VoiceStates(session)
        let socket = try await open(session, transport)
        socket.server(startedJSON)
        _ = await states.next { $0.startedByServer }
        socket.emit(.closed(code: 4401, reason: "revoked"))
        // A redial would publish a fresh preparing state first.
        let next = await states.next { $0.phase == .failed || $0.phase == .preparing }
        #expect(next?.phase == .failed)
        #expect(next?.result == .credentialsExpired)
        #expect(credentials.counts == (endpoint: 1, invalidate: 1))
        #expect(transport.sockets.count == 1)
    }

    @Test func serverRefusalsAndEndsBecomeTheCallResult() async throws {
        let busyTransport = FakeVoiceTransport(readiness: [VoiceFailure(.busy)])
        let refused = try call(busyTransport)
        let refusals = VoiceStates(refused)
        refused.start()
        let failed = await refusals.next { $0.phase == .failed }
        #expect(failed?.result == .busy)
        #expect(busyTransport.sockets.isEmpty)

        let transport = FakeVoiceTransport()
        let session = try call(transport)
        let socket = try await open(session, transport)
        socket.server(#"{"type":"error","code":4409,"message":"busy"}"#)
        #expect(session.snapshot().state.result == .busy)
        #expect(socket.cancelled)

        let ended = try call(transport)
        let second = try await open(ended, transport, index: 1)
        second.server(#"{"type":"session.ended","reason":"agent_hangup","duration_s":12.5}"#)
        #expect(ended.snapshot().state.phase == .ended)
        #expect(second.closed && !second.cancelled)
    }

    @Test func hangUpAsksTheServerToEndThenClosesWhenItDoesNot() async throws {
        let transport = FakeVoiceTransport(), clock = ManualVoiceScheduler()
        let session = try call(transport, scheduler: clock)
        let socket = try await open(session, transport)
        clock.advance(frames: 1)
        session.hangUp()
        drain(session)
        #expect(textTypes(socket).last == "session.end")
        #expect(session.snapshot().state.phase == .ending)
        let sent = socket.audio.count

        clock.advance(by: VoiceSession.hangUpGrace - 1)
        #expect(session.snapshot().state.phase == .ending)
        #expect(!socket.cancelled)
        clock.advance(by: 1)
        #expect(session.snapshot().state.phase == .ended)
        #expect(socket.cancelled)
        #expect(socket.audio.count == sent)
    }

    @Test func malformedDownlinkAudioInterruptsTheCall() async throws {
        let transport = FakeVoiceTransport()
        let session = try call(transport)
        let socket = try await open(session, transport)
        socket.emit(.binary(Data(count: 3)))
        #expect(session.snapshot().state.result == .interrupted)
    }

    @Test func uplinkSkipsFramesWhileTheSocketIsBackedUp() async throws {
        let transport = FakeVoiceTransport(), clock = ManualVoiceScheduler()
        let session = try call(transport, scheduler: clock)
        let socket = try await open(session, transport)
        socket.backlog = VoiceSession.maxQueuedUplinkBytes + 1
        clock.advance(frames: 3)
        #expect(session.snapshot().stats.stalledFrames == 3)
        #expect(socket.audio.isEmpty)

        socket.backlog = 0
        clock.advance(frames: 1)
        #expect(socket.audio.count == 1)
    }
}
