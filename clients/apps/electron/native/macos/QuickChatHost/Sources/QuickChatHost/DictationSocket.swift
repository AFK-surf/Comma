import Foundation
import QuickChatCore

/// One run of live dictation: 16 kHz mono s16le PCM goes up, the words come down.
@MainActor
protocol DictationConnection: AnyObject {
    /// The socket's events in order. The stream ends after `done` or `unavailable`.
    var events: AsyncStream<DictationEvent> { get }
    func send(_ pcm: Data)
    /// The speaker is done: the last segments settle, then `done`.
    func end()
    func cancel()
}

/// Live dictation over `CommaWeb.DictationSocket`, opened with a ticket from Main.
@MainActor
final class DictationSocket: DictationConnection {
    let events: AsyncStream<DictationEvent>
    private let continuation: AsyncStream<DictationEvent>.Continuation
    private let task: URLSessionWebSocketTask

    init?(ticket: DictationTicket) {
        guard var components = URLComponents(string: ticket.url) else { return nil }
        components.queryItems = [URLQueryItem(name: "ticket", value: ticket.ticket)]
        guard let url = components.url else { return nil }
        (events, continuation) = AsyncStream.makeStream(of: DictationEvent.self)
        task = URLSession.shared.webSocketTask(with: url)
        task.resume()
        Task { [weak self] in await self?.read() }
    }

    func send(_ pcm: Data) {
        task.send(.data(pcm)) { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor in self?.fail() }
        }
    }

    func end() {
        task.send(.string(#"{"type":"end"}"#)) { _ in }
    }

    func cancel() {
        task.cancel(with: .goingAway, reason: nil)
        continuation.finish()
    }

    private func read() async {
        while true {
            do {
                guard case let .string(text) = try await task.receive(),
                      let event = DictationEvent(message: text) else { continue }
                continuation.yield(event)
                if event == .done {
                    continuation.finish()
                    return
                }
            } catch {
                fail()
                return
            }
        }
    }

    private func fail() {
        continuation.yield(.unavailable)
        continuation.finish()
    }
}

/// Tickets for live dictation, through Main (`quickChat.dictationTicket`).
/// Main answers each `dictationTicket` once; one not answered in
/// `limit` counts as none.
@MainActor
final class DictationTickets {
    static let limit: Duration = .seconds(5)
    private let emit: (HostEvent) -> Void
    private var waiting: [String: CheckedContinuation<DictationTicket?, Never>] = [:]

    init(emit: @escaping (HostEvent) -> Void) {
        self.emit = emit
    }

    func ticket() async -> DictationTicket? {
        let requestId = UUID().uuidString
        return await withCheckedContinuation { continuation in
            waiting[requestId] = continuation
            emit(.dictationTicket(requestId: requestId))
            Task { [weak self] in
                try? await Task.sleep(for: Self.limit)
                self?.receive(requestId: requestId, ticket: nil)
            }
        }
    }

    func receive(requestId: String, ticket: DictationTicket?) {
        waiting.removeValue(forKey: requestId)?.resume(returning: ticket)
    }
}
