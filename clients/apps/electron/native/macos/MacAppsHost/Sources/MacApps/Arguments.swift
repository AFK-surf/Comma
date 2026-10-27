import Foundation
import MCP

/// A tool call's arguments, read with the type and bounds the tool expects.
/// Every reader throws `invalid_arguments` naming the field.
public struct Arguments: Sendable {
    public let values: [String: Value]

    public init(_ values: [String: Value]) {
        self.values = values
    }

    /// Present and not null.
    public func has(_ key: String) -> Bool {
        guard let value = values[key] else { return false }
        if case .null = value { return false }
        return true
    }

    /// Present and explicitly null: the caller asks to clear the field.
    public func isNull(_ key: String) -> Bool {
        guard let value = values[key] else { return false }
        if case .null = value { return true }
        return false
    }

    public func string(_ key: String) throws -> String? {
        guard has(key) else { return nil }
        guard let text = values[key]?.stringValue else {
            throw ToolFailure.invalidArguments(key, "\(key) must be a string.")
        }
        return text
    }

    public func requiredString(_ key: String) throws -> String {
        guard let text = try string(key)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            throw ToolFailure.invalidArguments(key, "\(key) is required.")
        }
        return text
    }

    public func choice(_ key: String, _ allowed: [String], default fallback: String) throws -> String {
        guard let text = try string(key) else { return fallback }
        guard allowed.contains(text) else {
            throw ToolFailure.invalidArguments(key, "\(key) must be one of: \(allowed.joined(separator: ", ")).")
        }
        return text
    }

    public func int(_ key: String, default fallback: Int? = nil, in range: ClosedRange<Int>) throws -> Int? {
        guard has(key) else { return fallback }
        let number: Int?
        switch values[key] {
        case let .int(value): number = value
        case let .double(value) where value.rounded() == value: number = Int(value)
        default: number = nil
        }
        guard let number, range.contains(number) else {
            throw ToolFailure.invalidArguments(
                key, "\(key) must be an integer from \(range.lowerBound) to \(range.upperBound).")
        }
        return number
    }

    public func limit(default fallback: Int, max: Int) throws -> Int {
        try int("limit", default: fallback, in: 1...max) ?? fallback
    }

    public func double(_ key: String) throws -> Double? {
        guard has(key) else { return nil }
        switch values[key] {
        case let .double(value): return value
        case let .int(value): return Double(value)
        default: throw ToolFailure.invalidArguments(key, "\(key) must be a number.")
        }
    }

    public func bool(_ key: String) throws -> Bool? {
        guard has(key) else { return nil }
        guard let flag = values[key]?.boolValue else {
            throw ToolFailure.invalidArguments(key, "\(key) must be true or false.")
        }
        return flag
    }

    public func strings(_ key: String) throws -> [String] {
        guard has(key) else { return [] }
        guard let items = values[key]?.arrayValue else {
            throw ToolFailure.invalidArguments(key, "\(key) must be a list of strings.")
        }
        return try items.map { item in
            guard let text = item.stringValue else {
                throw ToolFailure.invalidArguments(key, "\(key) must be a list of strings.")
            }
            return text
        }
    }

    public func ints(_ key: String, in range: ClosedRange<Int>) throws -> [Int] {
        guard has(key) else { return [] }
        guard let items = values[key]?.arrayValue else {
            throw ToolFailure.invalidArguments(key, "\(key) must be a list of integers.")
        }
        return try items.map { item in
            guard let number = item.intValue, range.contains(number) else {
                throw ToolFailure.invalidArguments(
                    key, "Each \(key) value must be an integer from \(range.lowerBound) to \(range.upperBound).")
            }
            return number
        }
    }

    public func date(_ key: String) throws -> (date: Date, dateOnly: Bool)? {
        guard let text = try string(key) else { return nil }
        guard let parsed = DateText.parse(text) else {
            throw ToolFailure.invalidArguments(
                key, "\(key) must be an ISO 8601 date or date-time, such as 2026-10-12 or 2026-10-12T15:00.")
        }
        return parsed
    }

    public func requiredDate(_ key: String) throws -> (date: Date, dateOnly: Bool) {
        guard let parsed = try date(key) else {
            throw ToolFailure.invalidArguments(key, "\(key) is required.")
        }
        return parsed
    }
}
