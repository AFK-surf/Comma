import Foundation
import os

/// A call or topic that failed. `code` is the core's (a server's codes pass through), `status` the HTTP status when it
/// came from a server.
struct CoreError: Error, Equatable, LocalizedError {
    let code: String
    let message: String
    var status: Int? = nil
    /// What else the server said, as it said it (its JSON error body), for a UI that words it.
    var detail: NSDictionary? = nil

    var errorDescription: String? { message.isEmpty ? code : message }
}

/// A JSON value as the core gives it: Foundation's (`NSDictionary`, `NSArray`, `NSString`, `NSNumber`, `NSNull`), never
/// changed after it is made, so it may cross threads. A part a topic's delta did not change is the same object as in
/// the value before.
struct CoreJSON: @unchecked Sendable {
    let value: Any?
}

/// A topic's value as the app reads it, or why there is none now.
enum TopicValue<T: Sendable>: Sendable {
    case value(T)
    case failed(CoreError)
}

/// The core as the app's features use it: named calls and topics. Tests put a fake in its place.
protocol CoreAPI: AnyObject, Sendable {
    /// A named call's answer, or a `CoreError`. Cancelled, the core is told to stop it.
    nonisolated(nonsending) func call(_ name: String, _ params: [String: Any]) async throws -> CoreJSON
    /// A call that says how it goes before it answers: each of its progress values, in order, on the client's queue.
    nonisolated(nonsending) func call(_ name: String, _ params: [String: Any],
                                      progress: @escaping @Sendable (CoreJSON) -> Void) async throws -> CoreJSON
    /// A topic's values, each the whole current value read by `read` on the client's queue. The topic is let go when
    /// the stream ends.
    func subscribe<T: Sendable>(_ topic: [String: Any], read: @escaping @Sendable (Any?) -> T) -> AsyncStream<TopicValue<T>>
    /// A place for a screen view's pictures (`devices.openScreenView`'s `sink`): the core's thread calls `handler` for
    /// each, with no JSON. Nil where pictures come only as progress.
    func screenSink(_ handler: @escaping @Sendable (ScreenFrame) -> Void) -> ScreenSinkToken?
}

extension CoreAPI {
    func screenSink(_ handler: @escaping @Sendable (ScreenFrame) -> Void) -> ScreenSinkToken? { nil }
    nonisolated(nonsending) func call(_ name: String) async throws -> CoreJSON { try await call(name, [:]) }
    /// A fake that has no progress to give answers as a plain call does.
    nonisolated(nonsending) func call(_ name: String, _ params: [String: Any],
                                      progress: @escaping @Sendable (CoreJSON) -> Void) async throws -> CoreJSON {
        try await call(name, params)
    }
}

/// What the core needs of the app besides its UI (CoreHost.swift is the app's). Each `call` is answered once through
/// `reply`, on any thread; `abort` names one given up and is never answered.
protocol CoreHostOps: AnyObject, Sendable {
    /// The JSON the core starts with (`MobileStart` in the core's phone host).
    func startConfig() -> [String: Any]
    func call(_ op: String, id: UInt64, input: [String: Any], bytes: Data?, reply: CoreReply)
    /// Answers at once: the value, or throws `HostFailure`.
    func callSync(_ op: String, input: [String: Any]) throws -> Any?
    /// A core started: the app tells it of requests the server refused through `engine`. Nil: it stopped.
    func attached(_ engine: (any CoreEngine)?)
}

/// Why a host operation failed; `kind` is SQLite's (`full`, `busy`) when it said so.
struct HostFailure: Error {
    let message: String
    var kind: String? = nil
}

/// The answer to one host call.
struct CoreReply: Sendable {
    let ok: @Sendable (_ json: [String: Any], _ bytes: Data?) -> Void
    let fail: @Sendable (_ message: String) -> Void

    func ok(_ json: [String: Any] = [:]) { ok(json, nil) }
    func ok(bytes: Data) { ok([:], bytes) }
}

/// One running core. Tests put a fake in its place.
protocol CoreEngine: AnyObject, Sendable {
    func receive(_ json: String)
    /// The server refused a request the app made for `lease` (JSON) with `status` (401 or 409).
    func rejected(lease: String, status: Int)
    func complete(_ id: UInt64, json: String?, error: String?, bytes: Data?)
    /// Stops this core and waits for its thread to end.
    func close()
}

/// What a running core asks of the app, called on the core's own thread.
protocol CoreEngineHost: AnyObject, Sendable {
    func call(_ id: UInt64, op: String, json: Data, bytes: Data?)
    func callSync(_ op: String, json: Data) -> Data
    func emit(_ json: Data)
    func fatal(_ reason: String)
    /// A screen view's picture for its decoder, on the core's thread: `bytes` valid only during the call.
    func screenFrame(_ frame: ScreenFrame)
}

extension CoreEngineHost {
    func screenFrame(_ frame: ScreenFrame) {}
}

/// A screen view's picture as the core hands it to the app's decoder (core screen-views.ts, host `screenFrames`):
/// `kind` 1 an H.264 config, 2 an H.265 one (`bytes` its avcC or hvcC), 3 a frame, 4 a key frame. `bytes` is the
/// core's memory, valid only while the sink runs: a sink copies what it keeps.
struct ScreenFrame {
    let sink: Int
    let kind: Int
    let ts: Double
    let width: Int
    let height: Int
    let bytes: UnsafeRawBufferPointer
}

/// A decoder's place for its view's pictures, until `close`.
final class ScreenSinkToken: Sendable {
    let id: Int
    private let closing: @Sendable () -> Void
    init(id: Int, close: @escaping @Sendable () -> Void) { self.id = id; closing = close }
    func close() { closing() }
    deinit { closing() }
}

/// Starts an engine that asks `host` for what it needs; `config` is the JSON the core's script starts with.
typealias CoreEngineFactory = @Sendable (_ config: String, _ host: any CoreEngineHost) throws -> any CoreEngine

/**
 * The app's side of the client core, as `CommaCore.kt` is Android's: one core at a time, calls with request ids, and
 * subscriptions that survive the core starting again. Everything here runs on one queue of its own, apart from the
 * core's thread.
 *
 * A core that fails (`CoreEngineHost.fatal`) is closed and another started, after 0, 1, 2, 5, 10 then 30 s for one
 * that keeps failing. Calls under way then fail with `core_restarted` (whether they ran is unknown: the caller
 * decides); subscriptions are made again by themselves.
 */
final class CoreClient: CoreAPI, @unchecked Sendable {
    private final class Subscription {
        let topic: [String: Any]
        let onValue: (Any?) -> Void
        let onError: (CoreError) -> Void
        /// The whole current value, which deltas apply to; nil until the first value and after an error.
        var value: Any?
        var has = false

        init(topic: [String: Any], onValue: @escaping (Any?) -> Void, onError: @escaping (CoreError) -> Void) {
            self.topic = topic; self.onValue = onValue; self.onError = onError
        }
    }

    private static let retryMs: [Int] = [0, 1_000, 2_000, 5_000, 10_000, 30_000]
    private static let steadyNanos: UInt64 = 60_000_000_000

    private let engines: CoreEngineFactory
    private let host: any CoreHostOps
    private let queue: DispatchQueue
    private let onFault: @Sendable (String) -> Void

    // Confined to `queue`.
    private var engine: (any CoreEngine)?
    private var nextId: UInt64 = 1
    private var calls: [UInt64: (Result<CoreJSON, CoreError>) -> Void] = [:]
    /// The progress of the calls that asked for it, by id; gone with their answer.
    private var progress: [UInt64: (CoreJSON) -> Void] = [:]
    private var subscriptions: [UInt64: Subscription] = [:]
    /// The order subscriptions were made in, which they are made again in.
    private var order: [UInt64] = []
    private var failures = 0
    private var startedAt: UInt64 = 0
    private var closed = false

    init(engines: @escaping CoreEngineFactory, host: any CoreHostOps,
         queue: DispatchQueue = DispatchQueue(label: "comma-core-client"),
         onFault: @escaping @Sendable (String) -> Void = { _ in }) {
        self.engines = engines; self.host = host; self.queue = queue; self.onFault = onFault
        queue.async { self.start() }
    }

    private func start() {
        guard !closed else { return }
        let sink = EngineSink(client: self)
        let started: any CoreEngine
        do {
            started = try engines(Self.text(host.startConfig()), sink)
        } catch {
            onFault("the core did not start: \(error)")
            retry()
            return
        }
        sink.engine = started
        engine = started
        startedAt = DispatchTime.now().uptimeNanoseconds
        host.attached(started)
        for id in order {
            guard let subscription = subscriptions[id] else { continue }
            post(["id": id, "subscribe": subscription.topic])
        }
    }

    /// Relays the core's thread to the client's queue, for the engine it was made for only.
    private final class EngineSink: CoreEngineHost, @unchecked Sendable {
        weak var client: CoreClient?
        /// Set once the engine is made, before it can say anything that needs it.
        var engine: (any CoreEngine)? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
        private let lock = NSLock()
        private weak var stored: (any CoreEngine)?

        init(client: CoreClient) { self.client = client }

        func call(_ id: UInt64, op: String, json: Data, bytes: Data?) {
            guard let client, let engine else { return }
            client.hostCall(id, op: op, json: json, bytes: bytes, engine: engine)
        }

        func callSync(_ op: String, json: Data) -> Data {
            guard let client else { return Data(#"{"error":"the app is gone"}"#.utf8) }
            return client.hostCallSync(op, json: json)
        }

        func emit(_ json: Data) {
            guard let client, let engine else { return }
            client.queue.async { if client.engine === engine { client.receive(json) } }
        }

        func screenFrame(_ frame: ScreenFrame) {
            client?.screenFrame(frame)
        }

        func fatal(_ reason: String) {
            guard let client, let engine else { return }
            client.queue.async { if client.engine === engine { client.restart(reason) } }
        }
    }

    private func hostCall(_ id: UInt64, op: String, json: Data, bytes: Data?, engine: any CoreEngine) {
        let reply = CoreReply(
            ok: { json, bytes in engine.complete(id, json: Self.text(json), error: nil, bytes: bytes) },
            fail: { message in engine.complete(id, json: nil, error: message, bytes: nil) })
        guard let input = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else {
            if op != "abort" { reply.fail("the call's input is not JSON") }
            return
        }
        host.call(op, id: id, input: input, bytes: bytes, reply: reply)
    }

    private func hostCallSync(_ op: String, json: Data) -> Data {
        var answer: [String: Any]
        do {
            let input = (try JSONSerialization.jsonObject(with: json)) as? [String: Any] ?? [:]
            answer = ["value": try host.callSync(op, input: input) ?? NSNull()]
        } catch let failure as HostFailure {
            answer = ["error": failure.message]
            if let kind = failure.kind { answer["kind"] = kind }
        } catch {
            answer = ["error": "\(error)"]
        }
        return (try? JSONSerialization.data(withJSONObject: answer)) ?? Data(#"{"error":"the answer is not JSON"}"#.utf8)
    }

    private func restart(_ reason: String) {
        onFault(reason)
        // A core that ran a while failed for a new reason: the pauses start over.
        if DispatchTime.now().uptimeNanoseconds - startedAt > Self.steadyNanos { failures = 0 }
        let old = engine
        engine = nil
        // The core's thread has ended before the app lets go of what it was using (its databases, its requests).
        old?.close()
        host.attached(nil)
        rejectCalls(CoreError(code: "core_restarted", message: "The core started again."))
        for subscription in subscriptions.values { subscription.has = false }
        retry()
    }

    private func retry() {
        let delay = Self.retryMs[min(failures, Self.retryMs.count - 1)]
        failures += 1
        queue.asyncAfter(deadline: .now() + .milliseconds(delay)) { self.start() }
    }

    private func rejectCalls(_ error: CoreError) {
        let waiting = Array(calls.values)
        calls.removeAll()
        progress.removeAll()
        for call in waiting { call(.failure(error)) }
    }

    private func post(_ message: [String: Any]) {
        engine?.receive(Self.text(message))
    }

    private func receive(_ json: Data) {
        guard let message = (try? JSONSerialization.jsonObject(with: json)) as? NSDictionary,
              let id = (message["id"] as? NSNumber)?.uint64Value else { return }
        if let subscription = subscriptions[id] {
            if let value = message["value"] {
                subscription.value = value
                subscription.has = true
            } else if let delta = message["delta"] {
                guard subscription.has else { return }
                subscription.value = Delta.apply(subscription.value, delta as? NSArray ?? [])
            } else if message["error"] != nil {
                subscription.has = false
                subscription.value = nil
                subscription.onError(Self.error(message["error"]))
                return
            } else {
                return
            }
            subscription.onValue(subscription.value)
            return
        }
        guard let call = calls[id] else { return }
        if let ok = message["ok"] {
            calls[id] = nil
            progress[id] = nil
            call(.success(CoreJSON(value: ok is NSNull ? nil : ok)))
        } else if message["error"] != nil {
            calls[id] = nil
            progress[id] = nil
            call(.failure(Self.error(message["error"])))
        } else if let value = message["value"] {
            progress[id]?(CoreJSON(value: value is NSNull ? nil : value))
        }
    }

    private static func error(_ body: Any?) -> CoreError {
        let body = body as? NSDictionary
        let code = (body?["code"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "internal"
        return CoreError(
            code: code,
            message: body?["message"] as? String ?? "",
            status: (body?["status"] as? NSNumber)?.intValue,
            detail: body?["detail"] as? NSDictionary
        )
    }

    static func text(_ json: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.fragmentsAllowed]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    nonisolated(nonsending) func call(_ name: String, _ params: [String: Any]) async throws -> CoreJSON {
        try await call(name, params, onProgress: nil)
    }

    nonisolated(nonsending) func call(_ name: String, _ params: [String: Any],
                                      progress: @escaping @Sendable (CoreJSON) -> Void) async throws -> CoreJSON {
        try await call(name, params, onProgress: progress)
    }

    private nonisolated(nonsending) func call(_ name: String, _ params: [String: Any],
                                              onProgress: (@Sendable (CoreJSON) -> Void)?) async throws -> CoreJSON {
        let box = CallBox(params)
        let state = CallState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CoreJSON, any Error>) in
                queue.async {
                    if self.closed {
                        continuation.resume(throwing: CoreError(code: "closed", message: "The core is closed."))
                    } else if self.engine == nil {
                        continuation.resume(throwing: CoreError(code: "core_restarted", message: "The core started again."))
                    } else if state.cancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        let id = self.nextId
                        self.nextId += 1
                        state.id = id
                        self.calls[id] = { result in continuation.resume(with: result.mapError { $0 as any Error }) }
                        if let onProgress { self.progress[id] = onProgress }
                        self.post(["id": id, "call": name, "params": box.params])
                    }
                }
            }
        } onCancel: {
            queue.async {
                state.cancelled = true
                guard let id = state.id, let waiting = self.calls.removeValue(forKey: id) else { return }
                self.progress[id] = nil
                self.post(["id": id, "cancel": true])
                waiting(.failure(CoreError(code: "cancelled", message: "The call was cancelled.")))
            }
        }
    }

    /// A call's state, read and written on the client's queue only.
    private final class CallState: @unchecked Sendable {
        var id: UInt64?
        var cancelled = false
    }

    private final class CallBox: @unchecked Sendable {
        let params: [String: Any]
        init(_ params: [String: Any]) { self.params = params }
    }

    // The screen views' decoders, by sink: read on the core's thread for each picture, so behind a lock of their own.
    private let sinkLock = NSLock()
    private var sinks: [Int: @Sendable (ScreenFrame) -> Void] = [:]
    private var nextSink = 1

    func screenSink(_ handler: @escaping @Sendable (ScreenFrame) -> Void) -> ScreenSinkToken? {
        let id = sinkLock.withLock { () -> Int in
            let id = nextSink
            nextSink += 1
            sinks[id] = handler
            return id
        }
        return ScreenSinkToken(id: id) { [weak self] in
            guard let self else { return }
            _ = self.sinkLock.withLock { self.sinks.removeValue(forKey: id) }
        }
    }

    /// One picture, on the core's thread: to its view's decoder, if it still has one.
    fileprivate func screenFrame(_ frame: ScreenFrame) {
        guard let handler = sinkLock.withLock({ sinks[frame.sink] }) else { return }
        handler(frame)
    }

    func subscribe<T: Sendable>(_ topic: [String: Any], read: @escaping @Sendable (Any?) -> T) -> AsyncStream<TopicValue<T>> {
        let box = CallBox(topic)
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let state = CallState()
            queue.async {
                guard !self.closed else { continuation.finish(); return }
                let id = self.nextId
                self.nextId += 1
                state.id = id
                self.subscriptions[id] = Subscription(
                    topic: box.params,
                    onValue: { continuation.yield(.value(read($0))) },
                    onError: { continuation.yield(.failed($0)) })
                self.order.append(id)
                self.post(["id": id, "subscribe": box.params])
            }
            continuation.onTermination = { _ in
                self.queue.async {
                    guard let id = state.id, self.subscriptions.removeValue(forKey: id) != nil else { return }
                    self.order.removeAll { $0 == id }
                    self.post(["id": id, "unsubscribe": true])
                }
            }
        }
    }

    /// Stops the core for good; `done` runs once its thread ended and its databases closed.
    func close(then done: (@Sendable () -> Void)? = nil) {
        queue.async {
            self.closed = true
            self.rejectCalls(CoreError(code: "closed", message: "The core is closed."))
            self.subscriptions.removeAll()
            self.order.removeAll()
            let old = self.engine
            self.engine = nil
            old?.close()
            self.host.attached(nil)
            done?()
        }
    }
}

/// The Hermes engine (CommaEngine.mm) as a `CoreEngine`.
final class HermesCoreEngine: NSObject, CoreEngine, CommaEngineHost, @unchecked Sendable {
    private let host: any CoreEngineHost
    private var engine: CommaEngine!

    init(script: Data, config: String, host: any CoreEngineHost) {
        self.host = host
        super.init()
        engine = CommaEngine(script: script, config: config, host: self)
    }

    func receive(_ json: String) { engine.receive(json) }
    func rejected(lease: String, status: Int) { engine.rejected(lease, status: status) }
    func complete(_ id: UInt64, json: String?, error: String?, bytes: Data?) {
        engine.complete(id, json: json.map { Data($0.utf8) }, error: error, bytes: bytes)
    }
    func close() { engine.close() }

    func engineCall(_ identifier: UInt64, op: String, json: Data, bytes: Data?) { host.call(identifier, op: op, json: json, bytes: bytes) }
    func engineCallSync(_ op: String, json: Data) -> Data? { host.callSync(op, json: json) }
    func engineEmit(_ json: Data) { host.emit(json) }
    func engineScreenFrame(_ sink: UInt32, kind: Int32, ts: Double, width: Int32, height: Int32, bytes: UnsafeRawPointer, length: Int) {
        host.screenFrame(ScreenFrame(sink: Int(sink), kind: Int(kind), ts: ts, width: Int(width), height: Int(height),
                                     bytes: UnsafeRawBufferPointer(start: bytes, count: length)))
    }
    func engineFatal(_ reason: String) { host.fatal(reason) }
}
