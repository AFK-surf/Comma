import Foundation
import Testing
@testable import CommaCore

@Suite("SSE framing")
struct SSEParserTests {
    @Test func fragmentedUTF8MultilineCRLFAndTruncatedTail() throws {
        var parser = SSEParser()
        let value = Data(": heartbeat\r\nevent: snapshot\r\ndata: {\"type\":\"snapshot\",\r\ndata: \"title\":\"你好\"}\r\n\r\n".utf8)
        var result: [SSEFrame] = []
        for byte in value { result += try parser.append(Data([byte])) }
        #expect(result.count == 1)
        #expect(try JSONDecoder().decode(ConversationEvent.self, from: result[0].data).title == "你好")
        #expect(try parser.append(Data("data: {\"type\":\"snapshot\"}".utf8)).isEmpty)
        #expect(try parser.finish().isEmpty)
    }
}
