import CUShared
import Darwin
import Foundation

/// `AgentSummaryBackend` that delegates every observer summary request
/// to the host via a UNIX-domain socket.
///
/// Lifecycle:
///   - The host creates a listener at `ObserverStartArgs.bridgeSocketPath`
///     before it tells the daemon to start a foreground session.
///   - `ObserverManager` calls `makeSession(logger:)` on session start.
///   - Each `summarizeObservation` / `requestFinalSummary` opens a fresh
///     connection to that socket, sends one `ObserverBridgeRequest`
///     frame, reads one `ObserverBridgeResponse` frame, closes.
///   - The host runs the actual LLM call and returns the text.
///
/// Using one-request-per-connection keeps the daemon side stateless and
/// sidesteps session-fan-out concerns; the host server accepts as many
/// concurrent connections as the OS allows.
public struct BridgeObserverSummaryBackend: AgentSummaryBackend {
    public let socketPath: String
    public let requestTimeoutSeconds: Int

    public init(socketPath: String, requestTimeoutSeconds: Int = 60) {
        self.socketPath = socketPath
        self.requestTimeoutSeconds = max(5, requestTimeoutSeconds)
    }

    public func makeSession(logger: @escaping @Sendable (String) -> Void) -> any AgentSummarySession {
        BridgeObserverSummarySession(
            socketPath: socketPath,
            requestTimeoutSeconds: requestTimeoutSeconds,
            logger: logger
        )
    }
}

public actor BridgeObserverSummarySession: AgentSummarySession {
    private let socketPath: String
    private let requestTimeoutSeconds: Int
    private let logger: @Sendable (String) -> Void

    public init(
        socketPath: String,
        requestTimeoutSeconds: Int,
        logger: @escaping @Sendable (String) -> Void
    ) {
        self.socketPath = socketPath
        self.requestTimeoutSeconds = requestTimeoutSeconds
        self.logger = logger
    }

    public func summarizeObservation(
        timelineEntries: [ObserverTimelineEntry],
        roundIndex: Int,
        sessionStartedAt: Double
    ) async throws -> String {
        let request = ObserverBridgeRequest(
            kind: .round,
            roundIndex: roundIndex,
            sessionStartedAt: sessionStartedAt,
            timeline: timelineEntries.map(Self.wire)
        )
        return try await send(request: request, label: "round \(roundIndex)")
    }

    public func requestFinalSummary(
        timelineEntries: [ObserverTimelineEntry],
        sessionStartedAt: Double
    ) async throws -> String {
        let request = ObserverBridgeRequest(
            kind: .final,
            roundIndex: 0,
            sessionStartedAt: sessionStartedAt,
            timeline: timelineEntries.map(Self.wire)
        )
        return try await send(request: request, label: "final")
    }

    private func send(request: ObserverBridgeRequest, label: String) async throws -> String {
        let path = socketPath
        let timeout = requestTimeoutSeconds
        logger("[observer] -> host (\(label))")
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let text = try Self.exchange(
                        socketPath: path,
                        timeoutSeconds: timeout,
                        request: request
                    )
                    continuation.resume(returning: text)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func wire(_ entry: ObserverTimelineEntry) -> ObserverBridgeTimelineEntry {
        ObserverBridgeTimelineEntry(
            type: entry.type == .summary ? .summary : .capture,
            timestampMs: entry.timestampMs,
            text: entry.text,
            frameBase64: entry.frameBase64,
            frameMimeType: entry.frameMimeType,
            displayIndex: entry.displayIndex,
            sequence: entry.sequence
        )
    }

    private static func exchange(
        socketPath: String,
        timeoutSeconds: Int,
        request: ObserverBridgeRequest
    ) throws -> String {
        let fd = try dial(socketPath: socketPath, timeoutSeconds: timeoutSeconds)
        defer { close(fd) }
        let payload = try JSONEncoder().encode(request)
        try DaemonWire.writeFrame(fd: fd, payload: payload)
        let responseData = try DaemonWire.readFrame(fd: fd)
        let decoded: ObserverBridgeResponse
        do {
            decoded = try JSONDecoder().decode(ObserverBridgeResponse.self, from: responseData)
        } catch {
            throw ObserverRuntimeError.invalidSummaryResponse(String(describing: error))
        }
        if decoded.ok, let text = decoded.text, !text.isEmpty {
            return text
        }
        let message = decoded.error ?? "bridge returned an empty observer response"
        // The server classifies unrecoverable conditions (missing auth,
        // unsupported model) in its error string. Everything else is
        // treated as retryable — we only flag fatal when the server
        // explicitly says so in the message.
        let fatal = message.lowercased().contains("fatal")
            || message.lowercased().contains("unauth")
            || message.lowercased().contains("api key")
        throw ObserverRuntimeError.summaryRequestFailed(message, fatal: fatal)
    }

    private static func dial(socketPath: String, timeoutSeconds: Int) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 {
            throw ObserverRuntimeError.summaryRequestFailed(
                "socket() failed errno=\(errno)",
                fatal: false
            )
        }

        var timeout = timeval(
            tv_sec: __darwin_time_t(timeoutSeconds),
            tv_usec: 0
        )
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPath = MemoryLayout.size(ofValue: addr.sun_path)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < maxPath else {
            close(fd)
            throw ObserverRuntimeError.summaryRequestFailed(
                "socket path too long: \(socketPath)",
                fatal: true
            )
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            let typed = buffer.bindMemory(to: CChar.self)
            for (offset, byte) in pathBytes.enumerated() {
                typed[offset] = CChar(bitPattern: byte)
            }
            typed[pathBytes.count] = 0
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, size)
            }
        }
        if result != 0 {
            let code = errno
            close(fd)
            throw ObserverRuntimeError.summaryRequestFailed(
                "connect() errno=\(code) path=\(socketPath)",
                fatal: false
            )
        }
        return fd
    }
}
