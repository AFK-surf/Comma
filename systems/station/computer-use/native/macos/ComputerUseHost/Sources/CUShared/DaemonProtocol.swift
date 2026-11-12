import Foundation

public struct DaemonResponse: Codable {
    public var ok: Bool
    public var text: String?
    public var error: String?

    public init(ok: Bool, text: String? = nil, error: String? = nil) {
        self.ok = ok
        self.text = text
        self.error = error
    }

    public static func success(_ text: String) -> DaemonResponse {
        DaemonResponse(ok: true, text: text, error: nil)
    }

    public static func failure(_ error: String) -> DaemonResponse {
        DaemonResponse(ok: false, text: nil, error: error)
    }
}

public enum ModeKind: String, Codable, Sendable, CaseIterable {
    case foreground
    case background
}

public struct SessionControl: Codable, Sendable {
    public enum Op: String, Codable, Sendable { case start, stop }

    public var op: Op
    public var mode: ModeKind?
    public var foreground: ForegroundStartArgs?
    public var background: BackgroundStartArgs?

    public init(
        op: Op,
        mode: ModeKind? = nil,
        foreground: ForegroundStartArgs? = nil,
        background: BackgroundStartArgs? = nil
    ) {
        self.op = op
        self.mode = mode
        self.foreground = foreground
        self.background = background
    }
}

public struct ForegroundStartArgs: Codable, Sendable {
    public var apps: [String]
    public var display: Int?
    /// Optional observer bridge config. `nil` disables observer summaries.
    public var observer: ObserverStartArgs?

    public init(
        apps: [String] = [],
        display: Int? = nil,
        observer: ObserverStartArgs? = nil
    ) {
        self.apps = apps
        self.display = display
        self.observer = observer
    }
}

public struct ObserverStartArgs: Codable, Sendable {
    /// Filesystem path to a UNIX-domain socket where the host accepts observer
    /// summary requests. The daemon connects to this socket per-round and
    /// delegates summary work to the host.
    public var bridgeSocketPath: String?
    public var captureIntervalMs: Int?
    public var finalSummaryTimeoutMs: Int?

    public init(
        bridgeSocketPath: String? = nil,
        captureIntervalMs: Int? = nil,
        finalSummaryTimeoutMs: Int? = nil
    ) {
        self.bridgeSocketPath = bridgeSocketPath
        self.captureIntervalMs = captureIntervalMs
        self.finalSummaryTimeoutMs = finalSummaryTimeoutMs
    }
}

/// Framed JSON exchanged between the daemon's `ObserverBridgeBackend`
/// and the host's observer bridge server. One request per socket
/// connection; wire framing is 4-byte big-endian length + UTF-8 JSON.
public struct ObserverBridgeRequest: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case round
        case final
    }

    public var kind: Kind
    /// Monotonic round counter the daemon assigns, handy for logging.
    public var roundIndex: Int
    /// Epoch-ms at session start. This lets the host render the same
    /// Epoch-ms at session start. This lets the host render elapsed timelines.
    public var sessionStartedAt: Double
    public var timeline: [ObserverBridgeTimelineEntry]

    public init(
        kind: Kind,
        roundIndex: Int,
        sessionStartedAt: Double,
        timeline: [ObserverBridgeTimelineEntry]
    ) {
        self.kind = kind
        self.roundIndex = roundIndex
        self.sessionStartedAt = sessionStartedAt
        self.timeline = timeline
    }
}

public struct ObserverBridgeTimelineEntry: Codable, Sendable {
    public enum EntryType: String, Codable, Sendable {
        case summary
        case capture
    }

    public var type: EntryType
    public var timestampMs: Double
    /// Populated when `type == .summary` — the prior round's summary text.
    public var text: String?
    /// Populated when `type == .capture` — base64 PNG/JPEG bytes.
    public var frameBase64: String?
    public var frameMimeType: String?
    public var displayIndex: Int
    public var sequence: Int

    public init(
        type: EntryType,
        timestampMs: Double,
        text: String? = nil,
        frameBase64: String? = nil,
        frameMimeType: String? = nil,
        displayIndex: Int = 1,
        sequence: Int = 0
    ) {
        self.type = type
        self.timestampMs = timestampMs
        self.text = text
        self.frameBase64 = frameBase64
        self.frameMimeType = frameMimeType
        self.displayIndex = displayIndex
        self.sequence = sequence
    }
}

public struct ObserverBridgeResponse: Codable, Sendable {
    public var ok: Bool
    public var text: String?
    public var error: String?

    public init(ok: Bool, text: String? = nil, error: String? = nil) {
        self.ok = ok
        self.text = text
        self.error = error
    }

    public static func success(_ text: String) -> ObserverBridgeResponse {
        ObserverBridgeResponse(ok: true, text: text, error: nil)
    }

    public static func failure(_ error: String) -> ObserverBridgeResponse {
        ObserverBridgeResponse(ok: false, text: nil, error: error)
    }
}

public struct BackgroundStartArgs: Codable, Sendable {
    public init() {}
}

public enum DaemonPaths {
    /// Runtime directory for ComputerUse artifacts such as screenshots and
    /// workspace-isolation snapshots.
    public static var runtimeDirectory: URL {
        if let configured = ProcessInfo.processInfo.environment["COMMA_COMPUTER_USE_RUNTIME_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("surf.comma", isDirectory: true)
            .appendingPathComponent("computer-use", isDirectory: true)
    }

    public static func ensureRuntimeDirectory() throws {
        try FileManager.default.createDirectory(
            at: runtimeDirectory,
            withIntermediateDirectories: true
        )
    }
}

public enum DaemonWireError: Error, CustomStringConvertible {
    case socketCreate(Int32)
    case socketBind(Int32, path: String)
    case socketListen(Int32)
    case socketConnect(Int32, path: String)
    case socketAccept(Int32)
    case writeFailed(Int32)
    case readFailed(Int32)
    case incompleteRead(expected: Int, got: Int)
    case payloadTooLarge(Int)
    case encodeFailed(String)
    case decodeFailed(String)

    public var description: String {
        switch self {
        case let .socketCreate(code):
            "socket() failed errno=\(code)"
        case let .socketBind(code, path):
            "bind() failed errno=\(code) path=\(path)"
        case let .socketListen(code):
            "listen() failed errno=\(code)"
        case let .socketConnect(code, path):
            "connect() failed errno=\(code) path=\(path)"
        case let .socketAccept(code):
            "accept() failed errno=\(code)"
        case let .writeFailed(code):
            "write failed errno=\(code)"
        case let .readFailed(code):
            "read failed errno=\(code)"
        case let .incompleteRead(expected, got):
            "incomplete read expected=\(expected) got=\(got)"
        case let .payloadTooLarge(n):
            "payload too large: \(n) bytes"
        case let .encodeFailed(message):
            "encode failed: \(message)"
        case let .decodeFailed(message):
            "decode failed: \(message)"
        }
    }
}

/// Read/write framed JSON messages over a file descriptor.
/// Frame: 4-byte big-endian length + UTF-8 JSON payload.
public enum DaemonWire {
    public static let maxPayload = 64 * 1024 * 1024

    public static func encode(_ value: some Encodable) throws -> Data {
        do {
            return try JSONEncoder().encode(value)
        } catch {
            throw DaemonWireError.encodeFailed(String(describing: error))
        }
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw DaemonWireError.decodeFailed(String(describing: error))
        }
    }

    public static func writeFrame(fd: Int32, payload: Data) throws {
        guard payload.count <= maxPayload else {
            throw DaemonWireError.payloadTooLarge(payload.count)
        }

        var lengthBE = UInt32(payload.count).bigEndian
        try withUnsafeBytes(of: &lengthBE) { buffer in
            try writeAll(fd: fd, bytes: buffer)
        }
        try payload.withUnsafeBytes { buffer in
            try writeAll(fd: fd, bytes: buffer)
        }
    }

    public static func readFrame(fd: Int32) throws -> Data {
        var header = Data(count: 4)
        try header.withUnsafeMutableBytes { buffer in
            try readAll(fd: fd, into: buffer)
        }
        let length = Int(UInt32(bigEndian: header.withUnsafeBytes { $0.load(as: UInt32.self) }))
        guard length >= 0, length <= maxPayload else {
            throw DaemonWireError.payloadTooLarge(length)
        }

        var payload = Data(count: length)
        try payload.withUnsafeMutableBytes { buffer in
            try readAll(fd: fd, into: buffer)
        }
        return payload
    }

    private static func writeAll(fd: Int32, bytes: UnsafeRawBufferPointer) throws {
        var remaining = bytes.count
        var offset = 0
        while remaining > 0 {
            let written = Darwin.write(
                fd,
                bytes.baseAddress!.advanced(by: offset),
                remaining
            )
            if written > 0 {
                offset += written
                remaining -= written
                continue
            }
            if written == -1, errno == EINTR {
                continue
            }
            throw DaemonWireError.writeFailed(errno)
        }
    }

    private static func readAll(fd: Int32, into buffer: UnsafeMutableRawBufferPointer) throws {
        var remaining = buffer.count
        var offset = 0
        while remaining > 0 {
            let got = Darwin.read(
                fd,
                buffer.baseAddress!.advanced(by: offset),
                remaining
            )
            if got > 0 {
                offset += got
                remaining -= got
                continue
            }
            if got == 0 {
                throw DaemonWireError.incompleteRead(
                    expected: buffer.count,
                    got: offset
                )
            }
            if got == -1, errno == EINTR {
                continue
            }
            throw DaemonWireError.readFailed(errno)
        }
    }
}
