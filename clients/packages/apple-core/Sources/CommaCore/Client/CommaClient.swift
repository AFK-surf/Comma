import Foundation

private struct IssuedSession: Decodable {
    let token: String
    let sessionID: String
    let expiresAt: Double
    let user: CommaUser
    enum CodingKeys: String, CodingKey { case token, sessionID = "session_id", expiresAt = "expires_at", user }
    var publicSession: CommaSession { CommaSession(id: sessionID, expiresAt: expiresAt, user: user) }
}

/// One bearer authority per application process. Neither a SwiftUI view nor an extension owns the token.
public actor CommaClient {
    public nonisolated let baseURL: URL
    public nonisolated let platform: ApplePlatform
    public private(set) var session: CommaSession?
    private let origin: String
    private let credentials: any CredentialStore
    let transport: any CommaTransport
    private(set) var credential: StoredCredential?
    private(set) var generation = 0
    var cancellation: [UUID: @Sendable () -> Void] = [:]
    var eventConnections: [String: UUID] = [:]
    private var challengeID: String?
    private var appleAttemptID: String?
    private(set) var signingOut = false

    public init(baseURL: URL, platform: ApplePlatform = .ios,
                keychainService: String = "surf.comma.ios.session",
                credentialStore: (any CredentialStore)? = nil, transport: (any CommaTransport)? = nil) throws {
        let origin = try Self.canonicalOrigin(baseURL)
        self.origin = origin; self.baseURL = URL(string: origin)!
        self.platform = platform
        self.credentials = credentialStore ?? KeychainCredentialStore(service: keychainService)
        self.transport = transport ?? URLSessionTransport()
    }

    public func requestEmailLogin(email: String) async throws -> EmailChallenge {
        advanceGeneration()
        challengeID = nil; appleAttemptID = nil
        let expected = generation
        let result: EmailChallenge = try await json("POST", ["auth", "email", "login"], body: ["email": .string(email)], authenticated: false)
        try assertCurrent(expected)
        challengeID = result.challengeID
        return result
    }

    public func verifyEmailLogin(challengeID: String, code: String) async throws -> CommaSession {
        guard self.challengeID == challengeID else { throw CommaError.staleSession }
        let expected = generation
        let issued: IssuedSession = try await json("POST", ["auth", "email", "verify"],
            body: clientMetadata.merging(["challenge_id": .string(challengeID), "code": .string(code)]) { _, v in v }, authenticated: false)
        return try commit(issued, expected: expected)
    }

    /// The Keychain session for this origin, unverified and without a request; nil when absent or expired.
    public func storedSession() throws -> CommaSession? {
        guard let stored = try credentials.load(origin: origin), stored.origin == origin,
              stored.session.expiresAt > Date().timeIntervalSince1970 else { return nil }
        return stored.session
    }

    public func restoreSession() async throws -> CommaSession? {
        advanceGeneration()
        let expected = generation
        guard let stored = try credentials.load(origin: origin) else { credential = nil; session = nil; return nil }
        guard stored.origin == origin else { throw CommaError.originMismatch }
        guard stored.session.expiresAt > Date().timeIntervalSince1970 else {
            try credentials.delete(origin: origin); credential = nil; session = nil; return nil
        }
        credential = stored
        let current: CommaSession = try await json("GET", ["auth", "session"])
        try assertCurrent(expected)
        guard current.id == stored.session.id && current.user.id == stored.session.user.id else {
            try clearSession(); throw CommaError.invalidResponse
        }
        let refreshed = StoredCredential(origin: origin, token: stored.token, session: current)
        try credentials.save(refreshed); credential = refreshed; session = current
        return current
    }

    public func logout() async throws {
        let previous = credential
        advanceGeneration()
        let expected = generation
        signingOut = true
        defer { signingOut = false }
        if let previous {
            do {
                _ = try await request("POST", ["auth", "logout"], body: Data("{}".utf8), authenticated: false, token: previous.token)
            } catch CommaError.http(let status, _, _) where status == 401 {
                // This endpoint only authenticates the bearer; 401 confirms it is already invalid.
            }
        }
        try assertCurrent(expected)
        // Revocation also closes linked Watch sessions. A failed remote signout retains one credential for explicit retry.
        credential = nil; session = nil; challengeID = nil; appleAttemptID = nil
        try credentials.delete(origin: origin)
    }

    /// Clears local authority after an external revocation. This does not claim remote signout succeeded.
    public func clearLocalSession() throws { try clearSession() }

    public func beginAppleLogin() async throws -> AppleLoginAttempt {
        advanceGeneration()
        challengeID = nil; appleAttemptID = nil
        let attempt: AppleLoginAttempt = try await json("POST", ["auth", "apple", "attempt"], body: [:], authenticated: false)
        appleAttemptID = attempt.attemptID
        return attempt
    }

    public func completeAppleLogin(attemptID: String, identityToken: String) async throws -> AppleLoginResult {
        guard appleAttemptID == attemptID else { throw CommaError.staleSession }
        let expected = generation
        let response = try await request("POST", ["auth", "apple"], body: try JSONEncoder().encode(
            clientMetadata.merging(["attempt_id": .string(attemptID), "identity_token": .string(identityToken)]) { _, v in v }), authenticated: false)
        let raw = try JSONDecoder().decode([String: JSONValue].self, from: response.data)
        if raw["status"]?.string == "otp_required", let id = raw["challenge_id"]?.string, let email = raw["email"]?.string {
            try assertCurrent(expected); challengeID = id; return .otpRequired(challengeID: id, email: email)
        }
        let issued = try decode(IssuedSession.self, data: response.data)
        return .signedIn(try commit(issued, expected: expected))
    }

    public func verifyAppleLink(challengeID: String, code: String) async throws -> CommaSession {
        guard self.challengeID == challengeID else { throw CommaError.staleSession }
        let expected = generation
        let issued: IssuedSession = try await json("POST", ["auth", "apple", "link", "verify"], body:
            clientMetadata.merging(["challenge_id": .string(challengeID), "code": .string(code)]) { _, v in v }, authenticated: false)
        return try commit(issued, expected: expected)
    }

    /// Only this short-lived pairing value may cross WatchConnectivity; the phone bearer never does.
    public func createWatchPairing() async throws -> WatchPairing {
        try await json("POST", ["auth", "watch", "pairing"], body: [:])
    }

    public func exchangeWatchPairing(_ pairing: WatchPairing) async throws -> CommaSession {
        advanceGeneration()
        challengeID = nil; appleAttemptID = nil
        let expected = generation
        let issued: IssuedSession = try await json("POST", ["auth", "watch", "exchange"],
            body: ["pairing_id": .string(pairing.pairingID), "pairing_secret": .string(pairing.pairingSecret)], authenticated: false)
        return try commit(issued, expected: expected)
    }

    /// Cancels foreground streams/requests without revoking an independently running server task.
    public func suspend() { advanceGeneration() }

    private var clientMetadata: [String: JSONValue] { ["client_kind": .string(platform == .watchos ? "watch" : "ios"), "client_platform": .string(platform.rawValue)] }

    func json<T: Decodable>(_ method: String, _ path: [String], query: [URLQueryItem] = [], body: [String: JSONValue]? = nil,
                             authenticated: Bool = true) async throws -> T {
        let response = try await request(method, path, query: query, body: try body.map { try JSONEncoder().encode($0) }, authenticated: authenticated)
        return try decode(T.self, data: response.data)
    }
    func decode<T: Decodable>(_ type: T.Type, data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) } catch { throw CommaError.invalidResponse }
    }

    func request(_ method: String, _ path: [String], query: [URLQueryItem] = [], body: Data? = nil,
                 contentType: String = "application/json", authenticated: Bool = true, token: String? = nil) async throws -> HTTPResponse {
        let expected = generation
        let request = try makeRequest(method, path, query: query, body: body, contentType: contentType, authenticated: authenticated, token: token)
        let id = UUID(), transport = self.transport
        let operation = Task { try await transport.data(for: request) }
        cancellation[id] = { operation.cancel() }
        defer { cancellation.removeValue(forKey: id) }
        let response: HTTPResponse
        do {
            response = try await withTaskCancellationHandler { try await operation.value } onCancel: { operation.cancel() }
        } catch {
            try assertCurrent(expected)
            if error is CancellationError || Task.isCancelled { throw CommaError.cancelled }
            if let typed = error as? CommaError { throw typed }
            throw CommaError.transport
        }
        try assertCurrent(expected)
        try validateHTTP(response, authenticated: authenticated)
        return response
    }

    func makeRequest(_ method: String, _ path: [String], query: [URLQueryItem], body: Data? = nil,
                     contentType: String = "application/json", authenticated: Bool = true, token: String? = nil) throws -> URLRequest {
        var url = baseURL.appendingPathComponent("v1").appendingPathComponent("comma")
        for segment in path {
            guard !segment.isEmpty && !segment.contains("/") && segment != "." && segment != ".." else { throw CommaError.invalidInput("Resource identity is invalid.") }
            url.appendPathComponent(segment)
        }
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        parts.queryItems = query.isEmpty ? nil : query
        // queryItems leaves '+' as is, and the server reads a bare '+' as a space ("C++" would arrive as "C  ").
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let endpoint = parts.url, try Self.canonicalOrigin(endpoint) == origin else { throw CommaError.originMismatch }
        let bearer = token ?? (authenticated ? credential?.token : nil)
        if authenticated && signingOut { throw CommaError.invalidInput("Sign out is in progress.") }
        if authenticated && bearer == nil { throw CommaError.notSignedIn }
        var request = URLRequest(url: endpoint)
        request.httpMethod = method; request.httpBody = body; request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if path.first == "auth" { request.setValue("bearer", forHTTPHeaderField: "x-comma-session-transport") }
        if let bearer { request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization") }
        return request
    }

    func validateHTTP(_ response: HTTPResponse, authenticated: Bool) throws {
        if let url = response.url, try Self.canonicalOrigin(url) != origin { throw CommaError.originMismatch }
        guard response.data.count <= 12_000_000 else { throw CommaError.responseTooLarge }
        if !(200..<300).contains(response.status) {
            let body = try? JSONDecoder().decode([String: JSONValue].self, from: response.data)
            let code = body?["error"]?.string ?? body?["error"]?.object?["code"]?.string ?? "http_error"
            if authenticated && response.status == 401 { try clearSession() }
            throw CommaError.http(status: response.status, code: code, retryAfter: response.headers["retry-after"].flatMap(Double.init))
        }
    }

    private func commit(_ issued: IssuedSession, expected: Int) throws -> CommaSession {
        try assertCurrent(expected)
        guard !issued.token.isEmpty, !issued.sessionID.isEmpty, !issued.user.id.isEmpty else { throw CommaError.invalidResponse }
        let stored = StoredCredential(origin: origin, token: issued.token, session: issued.publicSession)
        try credentials.save(stored)
        credential = stored; session = stored.session; challengeID = nil; appleAttemptID = nil
        return stored.session
    }
    private func clearSession() throws {
        advanceGeneration(); credential = nil; session = nil; challengeID = nil; appleAttemptID = nil
        try credentials.delete(origin: origin)
    }
    private func advanceGeneration() {
        generation += 1; let callbacks = Array(cancellation.values); cancellation.removeAll(); eventConnections.removeAll()
        for cancel in callbacks { cancel() }
    }
    func assertCurrent(_ expected: Int) throws { guard generation == expected else { throw CommaError.staleSession } }
    private static func canonicalOrigin(_ url: URL) throws -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = components.host?.lowercased(),
              components.user == nil, components.password == nil,
              components.scheme == "https" || (components.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)) else {
            throw CommaError.invalidOrigin
        }
        components.host = host; components.path = ""; components.query = nil; components.fragment = nil
        if components.port == (components.scheme == "https" ? 443 : 80) { components.port = nil }
        guard let result = components.string else { throw CommaError.invalidOrigin }; return result
    }
}
