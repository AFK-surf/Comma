import Foundation
import Testing
@testable import CommaCore

@Suite("HTTPS voice framing")
struct HTTPVoiceFramingTests {
    @Test func fragmentedAndCoalescedAudioPreserveClearOrder() throws {
        let audio = Data(repeating: 7, count: 960)
        let clear = Data(#"{"type":"output.clear"}"#.utf8)
        let wire = HTTPVoiceFraming.encode(2, audio) + HTTPVoiceFraming.encode(1, clear) + HTTPVoiceFraming.encode(2, audio)
        for chunkSize in [1, 4, 100, wire.count] {
            var parser = HTTPVoiceFraming()
            var received: [(UInt8, Data)] = []
            for offset in stride(from: 0, to: wire.count, by: chunkSize) {
                try parser.receive(wire.subdata(in: offset..<min(wire.count, offset + chunkSize))) { received.append(($0, $1)) }
            }
            #expect(received.map(\.0) == [2, 1, 2])
            #expect(received.map(\.1) == [audio, clear, audio])
        }
    }

    @Test func manyCoalescedFramesDoNotRequireAnUnboundedBuffer() throws {
        let audio = Data(repeating: 0, count: 16_384)
        let wire = (0..<20).reduce(into: Data()) { data, _ in data.append(HTTPVoiceFraming.encode(2, audio)) }
        var parser = HTTPVoiceFraming()
        var count = 0
        try parser.receive(wire) { kind, data in
            #expect(kind == 2 && data == audio)
            count += 1
        }
        #expect(count == 20)
    }

    @Test func rejectsOversizedFrameBeforeItsPayloadArrives() {
        var parser = HTTPVoiceFraming()
        #expect(throws: VoiceFailure.self) {
            try parser.receive(Data([2, 0, 0, 0x40, 1])) { _, _ in Issue.record("oversized frame delivered") }
        }
    }
}
