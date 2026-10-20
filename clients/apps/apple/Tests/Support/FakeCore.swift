import Foundation
@testable import Comma

/**
 * The client core as a test plays it: calls answered by name, and topics whose values the test gives. Values pass
 * through JSON first, so the app reads them as Foundation objects, as it reads the core's. A call with no answer
 * answers null.
 */
final class FakeCore: CoreAPI, @unchecked Sendable {
    typealias Answer = @Sendable (_ params: [String: Any]) throws -> Any?
    typealias Source = @Sendable (_ topic: [String: Any]) -> Any?

    private struct Subscriber {
        let topic: [String: Any]
        let push: @Sendable (Any?) -> Void
    }

    private let lock = NSLock()
    private var answers: [String: Answer] = [:]
    private var made: [(name: String, params: [String: Any])] = []
    private var sources: [String: Source] = [:]
    private var subscribers: [UUID: Subscriber] = [:]
    private var waiting: [(name: String, matches: @Sendable ([String: Any]) -> Bool, continuation: CheckedContinuation<[String: Any], Never>)] = []

    func on(_ name: String, _ answer: @escaping Answer) { lock.withLock { answers[name] = answer } }

    /// What a new subscriber to `topic` (by name) first gets; nothing until `publish` when there is no source.
    func serve(_ topic: String, _ source: @escaping Source) { lock.withLock { sources[topic] = source } }

    /// The params of each `name` call so far, oldest first.
    func calls(_ name: String) -> [[String: Any]] { lock.withLock { made.filter { $0.name == name }.map(\.params) } }

    /// The first `name` call whose params `matches` accepts: one made already, else the next.
    func first(_ name: String, where matches: @escaping @Sendable ([String: Any]) -> Bool = { _ in true }) async -> [String: Any] {
        await withCheckedContinuation { continuation in
            lock.withLock {
                if let made = made.first(where: { $0.name == name && matches($0.params) }) {
                    continuation.resume(returning: made.params)
                } else {
                    waiting.append((name, matches, continuation))
                }
            }
        }
    }

    /// The topics subscribed now.
    func topics(_ name: String) -> [[String: Any]] {
        lock.withLock { subscribers.values.map(\.topic).filter { $0["topic"] as? String == name } }
    }

    /// Gives `value` to the subscribers of the topic `name` whose params include `matching`.
    func publish(_ name: String, matching: [String: String] = [:], _ value: Any) {
        let json = Self.foundation(value)
        let targets = lock.withLock {
            subscribers.values.filter { subscriber in
                subscriber.topic["topic"] as? String == name &&
                    matching.allSatisfy { subscriber.topic[$0.key] as? String == $0.value }
            }
        }
        for target in targets { target.push(json) }
    }

    nonisolated(nonsending) func call(_ name: String, _ params: [String: Any]) async throws -> CoreJSON {
        nonisolated(unsafe) let params = params
        let (answer, ready) = lock.withLock { () -> (Answer?, [CheckedContinuation<[String: Any], Never>]) in
            made.append((name, params))
            let ready = waiting.filter { $0.name == name && $0.matches(params) }
            waiting.removeAll { $0.name == name && $0.matches(params) }
            return (answers[name], ready.map(\.continuation))
        }
        for continuation in ready { continuation.resume(returning: params) }
        return CoreJSON(value: try answer?(params).map(Self.foundation))
    }

    func subscribe<T: Sendable>(_ topic: [String: Any], read: @escaping @Sendable (Any?) -> T) -> AsyncStream<TopicValue<T>> {
        nonisolated(unsafe) let topic = topic
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            let source = lock.withLock { () -> Source? in
                subscribers[id] = Subscriber(topic: topic) { value in continuation.yield(.value(read(value))) }
                return sources[topic["topic"] as? String ?? ""]
            }
            if let first = source?(topic) { continuation.yield(.value(read(Self.foundation(first)))) }
            continuation.onTermination = { [weak self] _ in _ = self?.lock.withLock { self?.subscribers.removeValue(forKey: id) } }
        }
    }

    private static func foundation(_ value: Any) -> Any {
        guard JSONSerialization.isValidJSONObject(value) else { return value }
        return (try? JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: value))) ?? value
    }
}
