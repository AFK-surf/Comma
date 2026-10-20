import Foundation
import Testing
@testable import CommaCore

@Suite("Comma native client boundaries")
struct CommaClientTests {
    @Test func loginAndRetryKeepOneRequestIdentity() async throws {
        let store = MemoryCredentials()
        let transport = FixtureTransport([response("{\"challenge_id\":\"ch1\"}"), response(issuedJSON), response(conversationJSON), response(conversationJSON)])
        let client = try CommaClient(baseURL: URL(string: origin)!, credentialStore: store, transport: transport)
        let challenge = try await client.requestEmailLogin(email: "u@example.com")
        let session = try await client.verifyEmailLogin(challengeID: challenge.challengeID, code: "123456")
        #expect(session.user.id == "u1")
        _ = try await client.send(target: target, text: "Hello", requestID: "one-intent")
        _ = try await client.send(target: target, text: "Hello", requestID: "one-intent")
        let requests = await transport.requests()
        let metadata = try JSONDecoder().decode([String: JSONValue].self, from: requests[1].httpBody!)
        #expect(metadata["client_kind"] == .string("ios"))
        #expect(metadata["client_platform"] == .string("ios"))
        #expect(requests.prefix(2).allSatisfy { $0.value(forHTTPHeaderField: "x-comma-session-transport") == "bearer" })
        for request in requests.suffix(2) {
            let body = try JSONDecoder().decode([String: JSONValue].self, from: request.httpBody!)
            #expect(body["client_request_id"] == .string("one-intent"))
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-bearer")
            #expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains(URLQueryItem(name: "message_limit", value: "24")) == true)
        }
        #expect(try store.load(origin: "https://another.comma.test") == nil)
    }

    @Test func logoutFencesResponseEvenWhenTransportIgnoresCancellation() async throws {
        let store = MemoryCredentials(); try storedSession(store)
        let transport = FixtureTransport([response(sessionJSON), response("{\"signed_out\":true}")])
        await transport.delay(path: "/v1/comma/workspaces")
        let client = try CommaClient(baseURL: URL(string: origin)!, credentialStore: store, transport: transport)
        _ = try await client.restoreSession()
        let pending = Task { try await client.listWorkspaces() }
        await transport.waitForRequests(2)
        try await client.logout()
        await transport.resume(response("{\"data\":[{\"id\":\"private\",\"group_id\":\"g1\",\"name\":\"Old account\"}]}"))
        do { _ = try await pending.value; Issue.record("Old account data escaped logout") }
        catch { #expect(error as? CommaError == .staleSession) }
        #expect(await client.session == nil)
        #expect(try store.load(origin: origin) == nil)
    }

    @Test func startingAnotherLoginInvalidatesTheOldChallengeBeforeTheNewResponseArrives() async throws {
        let store = MemoryCredentials()
        let transport = FixtureTransport([response("{\"challenge_id\":\"old-challenge\"}"), response(issuedJSON)])
        let client = try CommaClient(baseURL: URL(string: origin)!, credentialStore: store, transport: transport)
        _ = try await client.requestEmailLogin(email: "old@example.com")
        await transport.delay(path: "/v1/comma/auth/email/login")
        let next = Task { try await client.requestEmailLogin(email: "u@example.com") }
        await transport.waitForRequests(2)
        do { _ = try await client.verifyEmailLogin(challengeID: "old-challenge", code: "123456"); Issue.record("Old login intent remained active") }
        catch { #expect(error as? CommaError == .staleSession) }
        #expect(await transport.requests().count == 2)
        await transport.resume(response("{\"challenge_id\":\"new-challenge\"}"))
        let challenge = try await next.value
        _ = try await client.verifyEmailLogin(challengeID: challenge.challengeID, code: "123456")
        #expect(await client.session?.id == "s1")
    }

    @Test func unauthorizedRetainsTypedErrorAndClearsSession() async throws {
        let store = MemoryCredentials(); try storedSession(store)
        let transport = FixtureTransport([response(sessionJSON), response("{\"error\":\"session_revoked\"}", status: 401)])
        let client = try CommaClient(baseURL: URL(string: origin)!, credentialStore: store, transport: transport)
        _ = try await client.restoreSession()
        do { _ = try await client.listWorkspaces(); Issue.record("Expected session rejection") }
        catch { #expect(error as? CommaError == .http(status: 401, code: "session_revoked", retryAfter: nil)) }
        #expect(await client.session == nil)
        #expect(try store.load(origin: origin) == nil)
    }

    @Test func failedSignoutRetainsCredentialForExplicitRevocationRetry() async throws {
        let store = MemoryCredentials(); try storedSession(store)
        let transport = FixtureTransport([response(sessionJSON), response("{\"error\":\"auth_unavailable\"}", status: 503), response("{\"signed_out\":true}")])
        let client = try CommaClient(baseURL: URL(string: origin)!, credentialStore: store, transport: transport)
        _ = try await client.restoreSession()
        do { try await client.logout(); Issue.record("Expected a failed remote signout") }
        catch { #expect(error as? CommaError == .http(status: 503, code: "auth_unavailable", retryAfter: nil)) }
        #expect(await client.session?.id == "s1")
        #expect(try store.load(origin: origin)?.session.id == "s1")
        try await client.logout()
        #expect(await client.session == nil)
        #expect(try store.load(origin: origin) == nil)
        let requests = await transport.requests()
        #expect(requests.suffix(2).allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer secret-bearer" })
    }

    @Test func externalRevocationClearsLocalAuthorityAndFencesOldWorkWithoutClaimingRemoteLogout() async throws {
        let store = MemoryCredentials(); try storedSession(store)
        let transport = FixtureTransport([response(sessionJSON)])
        await transport.delay(path: "/v1/comma/workspaces")
        let client = try CommaClient(baseURL: URL(string: origin)!, credentialStore: store, transport: transport)
        _ = try await client.restoreSession()
        let pending = Task { try await client.listWorkspaces() }
        await transport.waitForRequests(2)
        try await client.clearLocalSession()
        await transport.resume(response("{\"data\":[]}"))
        do { _ = try await pending.value; Issue.record("Revoked local authority accepted old work") }
        catch { #expect(error as? CommaError == .staleSession) }
        #expect(await client.session == nil)
        #expect(try store.load(origin: origin) == nil)
        let requests = await transport.requests()
        #expect(requests.count == 2)
        #expect(requests[0].value(forHTTPHeaderField: "x-comma-session-transport") == "bearer")
    }

    @Test func signoutOfAnAlreadyInvalidBearerDoesNotTrapTheUserInRetry() async throws {
        let store = MemoryCredentials(); try storedSession(store)
        let transport = FixtureTransport([response(sessionJSON), response("{\"error\":\"unauthorized\"}", status: 401)])
        let client = try CommaClient(baseURL: URL(string: origin)!, credentialStore: store, transport: transport)
        _ = try await client.restoreSession()
        try await client.logout()
        #expect(await client.session == nil)
        #expect(try store.load(origin: origin) == nil)
    }

    @Test func originAndCanonicalOwnerCannotChangeDuringResponse() async throws {
        let store = MemoryCredentials(); try storedSession(store)
        let transport = FixtureTransport([response(sessionJSON), response(conversationJSON, url: URL(string: "https://evil.example"))])
        let client = try CommaClient(baseURL: URL(string: origin)!, credentialStore: store, transport: transport)
        _ = try await client.restoreSession()
        do { _ = try await client.conversation(target: target); Issue.record("Expected audience rejection") }
        catch { #expect(error as? CommaError == .originMismatch) }
        #expect(throws: CommaError.invalidOrigin) { try CommaClient(baseURL: URL(string: "http://public.example")!) }
    }

    @Test func watchPairingExchangesOnlyShortGrantForItsOwnSession() async throws {
        let phoneStore = MemoryCredentials(); try storedSession(phoneStore)
        let phoneTransport = FixtureTransport([response(sessionJSON), response("{\"pairing_id\":\"p1\",\"pairing_secret\":\"short-pairing-grant\",\"expires_at\":9999999999}")])
        let phone = try CommaClient(baseURL: URL(string: origin)!, credentialStore: phoneStore, transport: phoneTransport)
        _ = try await phone.restoreSession()
        let pairing = try await phone.createWatchPairing()
        let watchStore = MemoryCredentials()
        let watchTransport = FixtureTransport([response("{\"session_id\":\"watch-session\",\"token\":\"watch-bearer\",\"expires_at\":9999999999,\"user\":{\"id\":\"u1\",\"email\":\"u@example.com\"}}")])
        let watch = try CommaClient(baseURL: URL(string: origin)!, platform: .watchos, credentialStore: watchStore, transport: watchTransport)
        let own = try await watch.exchangeWatchPairing(pairing)
        #expect(own.id == "watch-session")
        let request = await watchTransport.requests().first!
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        let body = try JSONDecoder().decode([String: JSONValue].self, from: request.httpBody!)
        #expect(body == ["pairing_id": .string("p1"), "pairing_secret": .string("short-pairing-grant")])
        #expect(try watchStore.load(origin: origin)?.token == "watch-bearer")
        #expect(try phoneStore.load(origin: origin)?.token == "secret-bearer")
    }

    @Test func appleAttemptNonceAndOTPLinkUseTheBoundChallenge() async throws {
        let store = MemoryCredentials()
        let transport = FixtureTransport([
            response("{\"attempt_id\":\"a1\",\"nonce\":\"server-nonce\",\"client_id\":\"surf.comma.ios\",\"expires_at\":9999999999}"),
            response("{\"status\":\"otp_required\",\"challenge_id\":\"apple-link\",\"email\":\"u@example.com\"}"), response(issuedJSON)
        ])
        let client = try CommaClient(baseURL: URL(string: origin)!, credentialStore: store, transport: transport)
        let attempt = try await client.beginAppleLogin()
        #expect(attempt.nonce == "server-nonce")
        let result = try await client.completeAppleLogin(attemptID: attempt.attemptID, identityToken: "apple-identity-token")
        guard case .otpRequired(let challenge, let email) = result else { Issue.record("Expected existing-email confirmation"); return }
        #expect(challenge == "apple-link" && email == "u@example.com")
        #expect(await client.session == nil)
        let signedIn = try await client.verifyAppleLink(challengeID: challenge, code: "123456")
        #expect(signedIn.id == "s1")
        let requests = await transport.requests()
        let body = try JSONDecoder().decode([String: JSONValue].self, from: requests[1].httpBody!)
        #expect(body["attempt_id"] == .string("a1"))
        #expect(body["identity_token"] == .string("apple-identity-token"))
        #expect(requests[2].url?.path == "/v1/comma/auth/apple/link/verify")
    }
}
