import Darwin
import Foundation

@available(macOS 14.0, *)
final class CommaComputerUseSocketServer {
    private var serverSocket: Int32 = -1
    private var isRunning = false
    private let socketPath: String
    private let authToken: String
    private let activeConnectionsLock = NSLock()
    private var activeConnections: Set<Int32> = []

    var onRequest: (@MainActor (CommaComputerUseRequest) async -> CommaComputerUseResponse)?
    var onShutdownRequested: (() -> Void)?

    init(socketPath: String, authToken: String) {
        self.socketPath = socketPath
        self.authToken = authToken
    }

    func start() throws {
        unlink(socketPath)
        try FileManager.default.createDirectory(
            atPath: (socketPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        serverSocket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            throw CommaSocketError("Failed to create socket")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= 104 else {
            close(serverSocket)
            throw CommaSocketError("Socket path is too long")
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            let raw = UnsafeMutableRawPointer(ptr)
            pathBytes.withUnsafeBufferPointer { buf in
                raw.copyMemory(from: buf.baseAddress!, byteCount: buf.count)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(serverSocket, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult == 0 else {
            close(serverSocket)
            throw CommaSocketError("Failed to bind socket: \(String(cString: strerror(errno)))")
        }
        guard chmod(socketPath, S_IRUSR | S_IWUSR) == 0 else {
            close(serverSocket)
            throw CommaSocketError("Failed to chmod socket: \(String(cString: strerror(errno)))")
        }

        guard listen(serverSocket, 5) == 0 else {
            close(serverSocket)
            throw CommaSocketError("Failed to listen on socket")
        }

        isRunning = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.acceptLoop()
        }
    }

    func stop() {
        stopAcceptingConnections()
        let connections = snapshotActiveConnections()
        for connection in connections {
            shutdown(connection, SHUT_RDWR)
        }
    }

    private func acceptLoop() {
        while isRunning {
            var clientAddr = sockaddr_un()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientSocket = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    accept(serverSocket, sockPtr, &clientAddrLen)
                }
            }

            guard clientSocket >= 0 else {
                if !isRunning { break }
                continue
            }

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.handleConnection(clientSocket)
            }
        }
    }

    private func handleConnection(_ clientSocket: Int32) {
        registerConnection(clientSocket)
        defer {
            unregisterConnection(clientSocket)
            close(clientSocket)
        }

        var buffer = [UInt8](repeating: 0, count: 65536)
        var accumulated = Data()

        var timeout = timeval(tv_sec: 60, tv_usec: 0)
        setsockopt(
            clientSocket,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )

        while true {
            let bytesRead = read(clientSocket, &buffer, buffer.count)
            if bytesRead <= 0 { break }
            accumulated.append(contentsOf: buffer[0..<bytesRead])

            if accumulated.contains(10) {
                break
            }
        }

        guard !accumulated.isEmpty else { return }

        guard
            let requestString = String(data: accumulated, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            let requestData = requestString.data(using: .utf8)
        else {
            sendStreamMessage(.final(.failure("Invalid JSON request")), to: clientSocket)
            return
        }

        let request: CommaComputerUseRequest
        do {
            request = try CommaComputerUseRequest(data: requestData, authToken: authToken)
        } catch CommaSocketUnauthorizedError.unauthorized {
            sendStreamMessage(.final(.failure("Unauthorized computer_use request")), to: clientSocket)
            return
        } catch {
            sendStreamMessage(.final(.failure("Invalid JSON request")), to: clientSocket)
            return
        }

        let semaphore = DispatchSemaphore(value: 0)
        let resultStateQueue = DispatchQueue(label: "CommaComputerUse.SocketServer.ResultState")
        var response = CommaComputerUseResponse.failure("No handler")
        var handlerCompleted = false

        Task { @MainActor [weak self] in
            guard let self, let handler = self.onRequest else {
                resultStateQueue.sync {
                    response = .failure("No handler registered")
                    handlerCompleted = true
                }
                semaphore.signal()
                return
            }

            let handledResponse = await handler(request)
            resultStateQueue.sync {
                response = handledResponse
                handlerCompleted = true
            }
            semaphore.signal()
        }

        let deadline: DispatchTime? = request.isWaitAction ? nil : (.now() + 60)
        while true {
            if semaphore.wait(timeout: .now() + 0.25) == .success {
                break
            }

            if let deadline, DispatchTime.now() >= deadline {
                resultStateQueue.sync {
                    if !handlerCompleted {
                        response = .failure("Timed out waiting for command response")
                    }
                }
                break
            }
        }

        sendStreamMessage(.final(resultStateQueue.sync { response }), to: clientSocket)
        if request.isShutdownControl {
            beginProcessShutdown(excluding: clientSocket)
        }
    }

    private func sendStreamMessage(_ message: CommaComputerUseStreamMessage, to clientSocket: Int32) {
        guard let json = message.toJSON() else { return }
        let data = Array((json + "\n").utf8)
        _ = write(clientSocket, data, data.count)
    }

    private func registerConnection(_ clientSocket: Int32) {
        activeConnectionsLock.lock()
        activeConnections.insert(clientSocket)
        activeConnectionsLock.unlock()
    }

    private func unregisterConnection(_ clientSocket: Int32) {
        activeConnectionsLock.lock()
        activeConnections.remove(clientSocket)
        activeConnectionsLock.unlock()
    }

    private func snapshotActiveConnections() -> [Int32] {
        activeConnectionsLock.lock()
        let snapshot = Array(activeConnections)
        activeConnectionsLock.unlock()
        return snapshot
    }

    private func beginProcessShutdown(excluding clientSocket: Int32) {
        stopAcceptingConnections()

        let connections = snapshotActiveConnections().filter { $0 != clientSocket }
        for connection in connections {
            sendStreamMessage(.final(.failure("Session ended by user")), to: connection)
            shutdown(connection, SHUT_RDWR)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.onShutdownRequested?()
        }
    }

    private func stopAcceptingConnections() {
        isRunning = false
        if serverSocket >= 0 {
            shutdown(serverSocket, SHUT_RDWR)
            close(serverSocket)
            serverSocket = -1
        }
        unlink(socketPath)
    }
}

struct CommaComputerUseRequest {
    enum Kind {
        case control(String)
        case action(CommaComputerUseAction)
    }

    let kind: Kind
    let display: Int?
    let thinking: String?

    var isWaitAction: Bool {
        if case let .action(action) = kind {
            return action.name == "wait"
        }
        return false
    }

    var isShutdownControl: Bool {
        if case let .control(control) = kind {
            return control.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "shutdown"
        }
        return false
    }

    init(data: Data, authToken: String) throws {
        guard
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw CommaSocketError("Invalid JSON request")
        }

        guard object["auth_token"] as? String == authToken else {
            throw CommaSocketUnauthorizedError.unauthorized
        }

        display = CommaComputerUseAction.intValue(object["display"])
        thinking = (object["thinking"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let control = object["control"] as? String,
           !control.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            kind = .control(control)
            return
        }

        guard
            let actionObject = object["action"] as? [String: Any],
            let first = actionObject.first
        else {
            throw CommaSocketError("Missing action")
        }
        let args = first.value as? [String: Any] ?? [:]
        kind = .action(CommaComputerUseAction(name: first.key, args: args))
    }
}

struct CommaComputerUseAction {
    let name: String
    let args: [String: Any]

    init(name: String, args: [String: Any]) {
        self.name = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "_")
        self.args = args
    }

    func requiredString(_ key: String) throws -> String {
        if let value = optionalString(key), !value.isEmpty {
            return value
        }
        throw CommaComputerUseRequestError("'\(key)' is required")
    }

    func optionalString(_ key: String) -> String? {
        guard let value = args[key] else { return nil }
        switch value {
        case let text as String:
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    func string(_ key: String) -> String? {
        optionalString(key)
    }

    func stringArray(_ key: String) -> [String] {
        guard let values = args[key] as? [Any] else { return [] }
        return values.compactMap { value in
            (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }

    static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber:
            return number.intValue
        case let text as String:
            return Int(text)
        default:
            return nil
        }
    }
}

struct CommaComputerUsePermissionInfo: Codable {
    var accessibility: Bool
    var screenRecording: Bool
}

struct CommaComputerUseResponse: Codable {
    var ok: Bool
    var error: String?
    var interrupted: Bool?
    var message: String?
    var text: String?
    var imageData: Data?
    var imageContentType: String?
    var imagePath: String?
    var imageWidth: Int?
    var imageHeight: Int?
    var permissions: CommaComputerUsePermissionInfo?
    var active: Bool?
    var state: String?
    var instructions: String?
    var coordinate: [Int]?
    var resumed: Bool?

    init(
        ok: Bool,
        error: String? = nil,
        interrupted: Bool? = nil,
        message: String? = nil,
        text: String? = nil,
        imageData: Data? = nil,
        imageContentType: String? = nil,
        imagePath: String? = nil,
        imageWidth: Int? = nil,
        imageHeight: Int? = nil,
        permissions: CommaComputerUsePermissionInfo? = nil,
        active: Bool? = nil,
        state: String? = nil,
        instructions: String? = nil,
        coordinate: [Int]? = nil,
        resumed: Bool? = nil
    ) {
        self.ok = ok
        self.error = error
        self.interrupted = interrupted
        self.message = message
        self.text = text
        self.imageData = imageData
        self.imageContentType = imageContentType
        self.imagePath = imagePath
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.permissions = permissions
        self.active = active
        self.state = state
        self.instructions = instructions
        self.coordinate = coordinate
        self.resumed = resumed
    }

    static func success(
        message: String? = nil,
        text: String? = nil,
        permissions: CommaComputerUsePermissionInfo? = nil
    ) -> CommaComputerUseResponse {
        CommaComputerUseResponse(
            ok: true,
            message: message,
            text: text,
            permissions: permissions
        )
    }

    static func failure(_ message: String) -> CommaComputerUseResponse {
        CommaComputerUseResponse(ok: false, error: message)
    }

    static func fromDaemonText(_ text: String?) -> CommaComputerUseResponse {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .success()
        }
        if let image = imageResponse(from: text) {
            return image
        }
        return .success(text: text)
    }

    private static func imageResponse(from text: String) -> CommaComputerUseResponse? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            trimmed.hasPrefix("{"),
            let data = trimmed.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let dataURL = object["image_data_url"] as? String
        else {
            return nil
        }

        let parsed = parseDataURL(dataURL)
        guard let imageData = parsed.data else { return nil }

        return CommaComputerUseResponse(
            ok: true,
            message: object["message"] as? String,
            imageData: imageData,
            imageContentType: parsed.contentType,
            imagePath: object["path"] as? String,
            imageWidth: CommaComputerUseAction.intValue(object["image_width"]),
            imageHeight: CommaComputerUseAction.intValue(object["image_height"])
        )
    }

    private static func parseDataURL(_ value: String) -> (contentType: String?, data: Data?) {
        guard let comma = value.firstIndex(of: ",") else {
            return (nil, nil)
        }
        let header = String(value[..<comma])
        let payload = String(value[value.index(after: comma)...])
        let contentType = header
            .replacingOccurrences(of: "data:", with: "")
            .replacingOccurrences(of: ";base64", with: "")
        return (contentType.isEmpty ? nil : contentType, Data(base64Encoded: payload))
    }
}

private struct CommaComputerUseStreamMessage: Codable {
    var kind: String
    var message: String?
    var response: CommaComputerUseResponse?

    static func final(_ response: CommaComputerUseResponse) -> CommaComputerUseStreamMessage {
        CommaComputerUseStreamMessage(kind: "final", response: response)
    }

    func toJSON() -> String? {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

private enum CommaSocketUnauthorizedError: Error {
    case unauthorized
}

struct CommaComputerUseRequestError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

private struct CommaSocketError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
