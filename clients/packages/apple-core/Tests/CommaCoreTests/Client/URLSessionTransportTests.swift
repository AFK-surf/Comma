import Foundation
import Network
import Testing
@testable import CommaCore

/// A bounded local HTTP fixture keeps URLSession's real AsyncBytes adapter in the test path.
private final class LoopbackSSEServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "comma-core.sse-fixture")
    private let response: Data

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let body = "event: snapshot\ndata: {\"type\":\"snapshot\",\"messages\":[]}\n\n" +
            "event: message_draft_started\r\ndata: {\"type\":\"message_draft_started\",\"text\":\"你好\"}\r\n\r\n"
        response = Data(("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n" +
            "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body).utf8)
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/events")!)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [queue, response] connection in
                connection.start(queue: queue)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { _, _, _, error in
                    guard error == nil else { connection.cancel(); return }
                    connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                }
            }
            listener.start(queue: queue)
        }
    }
    func stop() { listener.cancel() }
}

@Suite("URLSession SSE framing", .serialized)
struct URLSessionTransportTests {
    @Test func liveTransportPreservesEventBoundariesAndUnicode() async throws {
        let server = try LoopbackSSEServer()
        let url = try await server.start()
        defer { server.stop() }
        let transport = URLSessionTransport()
        let response = try await transport.stream(for: URLRequest(url: url))
        defer { response.cancel() }
        var parser = SSEParser()
        var events: [ConversationEvent] = []
        for try await chunk in response.chunks {
            for frame in try parser.append(chunk) {
                events.append(try JSONDecoder().decode(ConversationEvent.self, from: frame.data))
            }
        }
        #expect(events.map(\.type) == ["snapshot", "message_draft_started"])
        #expect(events.last?.text == "你好")
    }
}
