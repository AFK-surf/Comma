import Foundation

// Reading the core's JSON (Foundation's objects, as `CoreJSON` carries them) into Swift values: a value of the wrong
// type reads as absent, so a field the core adds or drops never stops a screen.

extension NSDictionary {
    /// A non-blank string; JSON null, numbers and blanks are absent.
    func string(_ key: String) -> String? {
        guard let value = self[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    /// A string as it is, blank or not.
    func text(_ key: String) -> String? { self[key] as? String }

    func int(_ key: String) -> Int? {
        guard let number = self[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        return value == value.rounded() && abs(value) < 9.0e15 ? Int(value) : nil
    }

    func double(_ key: String) -> Double? {
        guard let number = self[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }

    func bool(_ key: String) -> Bool { (self[key] as? NSNumber)?.boolValue ?? false }

    func object(_ key: String) -> NSDictionary? { self[key] as? NSDictionary }

    func array(_ key: String) -> NSArray? { self[key] as? NSArray }

    /// The objects of the list at `key`, others left out.
    func objects(_ key: String) -> [NSDictionary] { (self[key] as? NSArray)?.compactMap { $0 as? NSDictionary } ?? [] }

    func strings(_ key: String) -> [String] { (self[key] as? NSArray)?.compactMap { $0 as? String } ?? [] }
}

extension CoreJSON {
    var object: NSDictionary? { value as? NSDictionary }
    var array: NSArray? { value as? NSArray }

    /// The value as a `Decodable`, by way of its JSON text; nil when it does not decode.
    func decode<T: Decodable>(_ type: T.Type) -> T? {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

extension CoreAPI {
    /// A call's answer as an object; a `CoreError` when it is none.
    nonisolated(nonsending) func object(_ name: String, _ params: [String: Any] = [:]) async throws -> NSDictionary {
        guard let value = try await call(name, params).object else {
            throw CoreError(code: "bad_response", message: "\(name) answered no object.")
        }
        return value
    }

    /// The first value of `topic` that `read` makes something of, or nil when the topic failed first.
    nonisolated(nonsending) func first<T: Sendable>(_ topic: [String: Any], read: @escaping @Sendable (Any?) -> T?) async -> T? {
        for await value in subscribe(topic, read: read) {
            switch value {
            case .value(let read?): return read
            case .value: continue
            case .failed: return nil
            }
        }
        return nil
    }
}

/// One session operation's answer (the session contract's result): its value, or the error the contract names.
struct SessionOperation: Sendable {
    let value: CoreJSON?
    let code: String?
    /// Whole seconds until another try is worth it, when the server said.
    let retryAfterSeconds: Int?

    var ok: Bool { code == nil }

    init(_ answer: NSDictionary?) {
        if answer?.bool("ok") == true {
            value = CoreJSON(value: answer?.object("value")); code = nil; retryAfterSeconds = nil
        } else {
            let error = answer?.object("error")
            value = nil
            code = error?.string("code") ?? "unknown"
            retryAfterSeconds = error?.int("retryAfterMs").map { ($0 + 999) / 1000 }
        }
    }

    init(failure code: String) { value = nil; self.code = code; retryAfterSeconds = nil }

    /// Runs operation `name` on `core`: a core that started again reads as the network being away.
    nonisolated(nonsending) static func run(_ core: any CoreAPI, _ name: String, _ params: [String: Any]) async -> SessionOperation {
        do {
            return SessionOperation(try await core.call(name, params).object)
        } catch let error as CoreError {
            return SessionOperation(failure: error.code == "core_restarted" ? "network_unavailable" : "unknown")
        } catch {
            return SessionOperation(failure: "unknown")
        }
    }
}

/// Bytes as they cross to and from the core, in a call's params or answer and in a topic: `{"$bytes": base64}`.
enum CoreBytes {
    static func json(_ data: Data) -> [String: Any] { ["$bytes": data.base64EncodedString()] }

    /// The bytes `value` carries, or nil when it carries none.
    static func read(_ value: Any?) -> Data? {
        ((value as? NSDictionary)?["$bytes"] as? String).flatMap { Data(base64Encoded: $0) }
    }
}
