import CommaCore
import Foundation

/// The core's `session` topic, as much of it as the app reads (Android's `AuthRepository` reads the same).
struct SessionSnapshot: Sendable, Equatable {
    /// The lifecycle's phase: `initializing`, `signed_out`, `authenticating`, `signed_in`, `indeterminate`, …
    let phase: String
    let authority: String
    let generation: Int
    let user: CommaUser?
    let sessionID: String?
    let audience: String?
    let expiresAt: Double
    /// The account whose kept data the core shows: the confirmed one, or the stored credential's while it is checked.
    let shownUserID: String?
    let problem: String?
    let attempt: SignInAttempt?
    /// Seconds the server asked to wait before another code for this address.
    let cooldown: Int?

    init(_ value: Any?) {
        let json = value as? NSDictionary ?? [:]
        let lifecycle = json.object("lifecycle")
        let principal = lifecycle?.object("principal")
        let descriptor = lifecycle?.object("session")
        phase = lifecycle?.string("phase") ?? "initializing"
        authority = lifecycle?.object("authority")?.text("authorityInstanceId") ?? ""
        generation = lifecycle?.int("generation") ?? 0
        user = principal.flatMap { principal in
            principal.string("userId").map { CommaUser(id: $0, email: principal.text("email") ?? "", name: principal.string("displayName")) }
        }
        sessionID = descriptor?.string("sessionId")
        audience = descriptor?.string("audience")
        expiresAt = descriptor?.double("expiresAtEpochSeconds") ?? 0
        shownUserID = json.string("phase") == "signed_in" ? json.string("userId") : nil
        problem = lifecycle?.object("problem")?.string("code")
        let attempt = json.object("attempt")
        let challenge = attempt?.object("challenge")
        self.attempt = attempt?.object("ref").flatMap { ref in
            guard let data = try? JSONSerialization.data(withJSONObject: ref) else { return nil }
            return SignInAttempt(ref: String(decoding: data, as: UTF8.self), challengeID: challenge?.string("challengeId"),
                                 linkingApple: challenge?.string("purpose") == "apple_link", email: challenge?.string("email"),
                                 expired: challenge?.bool("expired") == true)
        }
        cooldown = json.object("emailCooldown")?.int("seconds")
    }
}

/// Why a sign-in step did not work, as the login screen says it.
enum SignInProblem: Equatable {
    case invalidCode, rateLimited, unavailable, network, accountDisabled, storage, appleLinked, server

    /// `apple`: the step was a Sign in with Apple one, where a conflict means the Apple ID belongs to another account.
    /// Elsewhere a conflict means the session changed meanwhile, and trying again is the answer.
    init(code: String, apple: Bool = false) {
        switch code {
        case "invalid_challenge", "challenge_expired": self = .invalidCode
        case "rate_limited": self = .rateLimited
        case "provider_unavailable": self = .unavailable
        case "network_unavailable", "session_probe_unavailable": self = .network
        case "account_disabled": self = .accountDisabled
        case "credential_store_unavailable", "credential_store_unreadable", "credential_mutation_uncertain": self = .storage
        case "conflict": self = apple ? .appleLinked : .server
        default: self = .server
        }
    }

    var message: String {
        switch self {
        case .invalidCode: String(localized: "That code didn’t work. Check it and try again.")
        case .rateLimited: String(localized: "Too many attempts. Try again in a minute.")
        case .unavailable: String(localized: "Sign-in is unavailable right now. Try again later.")
        case .network: String(localized: "You’re offline. Check your connection and try again.")
        case .accountDisabled: String(localized: "This account is disabled.")
        case .storage: String(localized: "Comma could not keep your sign-in on this iPhone.")
        case .appleLinked: String(localized: "This Apple ID is already linked to another account.")
        case .server: String(localized: "Something went wrong. Try again.")
        }
    }
}

/// Sign-in, sign-out and the session the core shows.
extension CommaStore {
    func observe(_ next: SessionSnapshot) {
        let previous = lifecycle
        lifecycle = next
        signIn = next.attempt.flatMap { $0.challengeID == nil || $0.expired ? nil : $0 }
        sessionProblem = next.phase == "indeterminate" ? SignInProblem(code: next.problem ?? "") : nil
        if let cooldown = next.cooldown, cooldown > 0, cooldown != previous?.cooldown {
            resendAt = max(resendAt ?? .distantPast, Date().addingTimeInterval(TimeInterval(cooldown)))
        }
        let shown: CommaSession? = {
            if next.phase == "signed_in", let user = next.user, let id = next.sessionID {
                return CommaSession(id: id, expiresAt: next.expiresAt, user: user)
            }
            // The kept account shows while the core checks its session, offline too.
            guard next.phase == "initializing", let kept = next.shownUserID, let identity = custody.identity(),
                  identity.userId == kept else { return nil }
            return CommaSession(id: identity.sessionId, expiresAt: Double(identity.expiresAtEpochSeconds),
                                user: CommaUser(id: identity.userId, email: identity.email))
        }()
        if next.phase == "initializing" && shown == nil && !initialized { return }
        if shown?.id != session?.id || shown?.user.id != session?.user.id {
            let accountChanged = shown?.user.id != session?.user.id || shown == nil
            if session != nil && accountChanged {
                boundary += 1
                onAuthBoundaryChanged?()
                clearProduct()
            }
            session = shown
            onSessionChanged?(shown)
            if let shown { validateApple(shown) }
        } else if let shown, shown != session {
            session = shown
        }
        // The Workspace is found once the server confirmed the session (a kept account only shows meanwhile).
        if next.phase == "signed_in", let shown, connected != shown.user.id + "\n" + shown.id {
            connected = shown.user.id + "\n" + shown.id
            connect(shown)
        } else if shown == nil {
            connected = nil
        }
        initialized = true
    }

    /// An Apple ID that signed this session in and was revoked since ends the session.
    private func validateApple(_ shown: CommaSession) {
        guard let validateSession else { return }
        let current = boundary
        Task { [weak self] in
            guard let valid = try? await validateSession(shown), !valid, let self, self.boundary == current else { return }
            await self.logout()
        }
    }

    // MARK: What the person does

    /// Emails a sign-in code: nil once it is sent, else why not.
    func requestEmailCode(email: String) async -> SignInProblem? {
        guard let expected = absence() else { return .server }
        if let resendAt, resendAt > Date() { return .rateLimited }
        loading = true
        defer { loading = false }
        let result = await SessionOperation.run(core, "session.email.request", ["email": email, "expected": expected])
        if let code = result.code {
            if code == "rate_limited" || code == "provider_unavailable" {
                resendAt = Date().addingTimeInterval(TimeInterval(result.retryAfterSeconds ?? 60))
            }
            return SignInProblem(code: code)
        }
        let after = result.value?.object?.int("resendAfterSeconds") ?? 60
        resendAt = Date().addingTimeInterval(TimeInterval(after))
        return nil
    }

    /// Signs in with the emailed code (or links the Apple ID with it): nil once signed in, else why not.
    func verify(code: String) async -> SignInProblem? {
        guard let attempt = signIn, let challenge = attempt.challengeID,
              let ref = try? JSONSerialization.jsonObject(with: Data(attempt.ref.utf8)) else { return .invalidCode }
        loading = true
        defer { loading = false }
        let result = await SessionOperation.run(core, attempt.linkingApple ? "session.apple.linkVerify" : "session.email.verify",
                                                ["attempt": ref, "challengeId": challenge, "code": code])
        if let failure = result.code {
            if failure == "rate_limited" { resendAt = Date().addingTimeInterval(TimeInterval(result.retryAfterSeconds ?? 60)) }
            return SignInProblem(code: failure, apple: attempt.linkingApple)
        }
        return nil
    }

    /**
     * Signs in with Apple: the core starts a one-time attempt, asks the app's Sign in with Apple sheet for a token bound
     * to its nonce, and exchanges it. An existing account that has not linked its Apple ID yet gets an email code first
     * (`signIn.linkingApple`). Nil once signed in or a code is on its way; closing the sheet is no problem.
     */
    func signInWithApple() async -> SignInProblem? {
        guard let expected = absence() else { return .server }
        loading = true
        defer { loading = false }
        let result = await SessionOperation.run(core, "session.apple", ["expected": expected])
        guard let code = result.code else {
            if let subject = apple.subject {
                if result.value?.object?.string("status") == "signed_in",
                   let id = result.value?.object?.object("snapshot")?.object("session")?.string("sessionId") {
                    AppleCredentialMonitor.save(subject: subject, sessionID: id)
                } else {
                    AppleCredentialMonitor.pendingSubject = subject
                }
            }
            return nil
        }
        switch code {
        case "cancelled": return nil
        case "unsupported": return .unavailable
        default: return SignInProblem(code: code, apple: true)
        }
    }

    /// The core finds out again what the session is, as Try Again asks.
    func retrySession() async { _ = try? await core.call("session.recover") }

    /// Gives up the code under way: back to the email.
    func changeEmail() async {
        AppleCredentialMonitor.pendingSubject = nil
        guard let attempt = signIn, let ref = try? JSONSerialization.jsonObject(with: Data(attempt.ref.utf8)) else { return }
        _ = await SessionOperation.run(core, "session.cancelAuth", ["attempt": ref])
    }

    func logout() async {
        guard let current = lifecycle else { return }
        var expected: [String: Any] = ["authorityInstanceId": current.authority, "generation": current.generation]
        if current.phase == "signed_in" {
            expected["expectedAudience"] = current.audience ?? ""
            expected["expectedSessionId"] = current.sessionID ?? ""
        } else {
            expected["expectedSessionId"] = NSNull()
        }
        loading = true
        defer { loading = false }
        await beforeLogout?()
        // This device's push slot goes with the session that made it, while that session can still delete it.
        _ = try? await core.call("notifications.unregisterDevice")
        let result = await SessionOperation.run(core, "session.signOut", ["expected": expected])
        if let code = result.code { error = SignInProblem(code: code).message }
        else { AppleCredentialMonitor.clear() }
    }

    /// What a sign-in expects of the session: nobody signed in, at this authority's generation.
    private func absence() -> [String: Any]? {
        guard let current = lifecycle, !current.authority.isEmpty else { return nil }
        return ["authorityInstanceId": current.authority, "generation": current.generation, "expectedSessionId": NSNull()]
    }

    /// Seconds until another code may be asked for; 0 when it may now.
    var resendSeconds: Int { max(0, Int(ceil((resendAt ?? .distantPast).timeIntervalSinceNow))) }
}
