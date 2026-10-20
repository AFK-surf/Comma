import Foundation

// Generic wire shapes shared by every endpoint: an arbitrary JSON value, a cursor page and a timestamp.

public enum JSONValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), null, array([JSONValue]), object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode(Double.self) { self = .number(value) }
        else if let value = try? c.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let value): try c.encode(value)
        case .number(let value): try c.encode(value)
        case .bool(let value): try c.encode(value)
        case .null: try c.encodeNil()
        case .array(let value): try c.encode(value)
        case .object(let value): try c.encode(value)
        }
    }
    public var string: String? { if case .string(let value) = self { value } else { nil } }
    public var object: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
    public var array: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
    public var number: Double? { if case .number(let value) = self { value } else { nil } }
    public var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
}

public struct Page<Element: Codable & Sendable>: Codable, Sendable {
    public let data: [Element]
    public let hasMore: Bool?
    public let nextCursor: String?
    enum CodingKeys: String, CodingKey { case data, hasMore = "has_more", nextCursor = "next_cursor" }
    public init(data: [Element], hasMore: Bool? = nil, nextCursor: String? = nil) {
        self.data = data; self.hasMore = hasMore; self.nextCursor = nextCursor
    }
}

extension Date {
    /// Below this a wire timestamp is Unix seconds; from it up, Unix milliseconds. Today's values sit near
    /// 1.8e9 seconds and 1.8e12 milliseconds, so any bound between 1e10 and 1e12 tells them apart. 1e10 is the
    /// desktop's bound (`normalizeUnixTimestampMs`), so both clients read every value as the same instant. It
    /// keeps seconds valid until November 2286, and only milliseconds before 26 April 1970 read as seconds.
    static let wireMillisecondsFloor: Double = 10_000_000_000

    /// A timestamp as the API sends it: Unix seconds or Unix milliseconds, for the same field.
    public init(wireTimestamp value: Double) {
        self.init(timeIntervalSince1970: value < Self.wireMillisecondsFloor ? value : value / 1000)
    }
}
