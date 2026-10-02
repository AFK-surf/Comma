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
    private let transport: any CommaTransport
    private var credential: StoredCredential?
    private var generation = 0
    private var cancellation: [UUID: @Sendable () -> Void] = [:]
    private var eventConnections: [String: UUID] = [:]
    private var challengeID: String?
    private var appleAttemptID: String?
    private var signingOut = false

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

    public func listWorkspaces() async throws -> [Workspace] {
        let page: Page<Workspace> = try await json("GET", ["workspaces"])
        guard page.data.count <= 100 else { throw CommaError.responseTooLarge }
        return page.data
    }

    public func bootstrapWorkspace() async throws -> WorkspaceBootstrap {
        try await json("POST", ["me", "bootstrap"], body: [:])
    }

    public func openHome(workspace: Workspace) async throws -> Conversation {
        var result: Conversation = try await json("POST", ["groups", workspace.groupID, "assistant-chat"],
            query: [URLQueryItem(name: "message_limit", value: "24")], body: [:])
        guard result.groupID == workspace.groupID && result.kind == "user_chat" else { throw CommaError.invalidResponse }
        result = result.keepingMessageTail(24)
        return result
    }

    /// `archived` lists only archived Tasks instead of the active ones.
    public func listTasks(workspace: Workspace, cursor: String? = nil, archived: Bool = false) async throws -> Page<Conversation> {
        var query = [URLQueryItem(name: "limit", value: "50"), URLQueryItem(name: "kind", value: "agent_task"),
                     URLQueryItem(name: "archive", value: archived ? "only" : "exclude")]
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        let page: Page<Conversation> = try await json("GET", ["groups", workspace.groupID, "conversations"], query: query)
        guard page.data.count <= 50, page.data.allSatisfy({ $0.groupID == workspace.groupID && $0.kind == "agent_task" }) else { throw CommaError.invalidResponse }
        return page
    }

    public func searchTasks(workspace: Workspace, query: String, limit: Int = 20) async throws -> [Conversation] {
        guard (1...50).contains(limit), !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CommaError.invalidInput("Enter a search query with a limit between 1 and 50.")
        }
        struct Hit: Codable, Sendable { let conversation_id: String }
        let matches: Page<Hit> = try await json("GET", ["groups", workspace.groupID, "conversations", "search"],
            query: [URLQueryItem(name: "q", value: query), URLQueryItem(name: "limit", value: String(limit))])
        guard matches.data.count <= limit else { throw CommaError.responseTooLarge }
        let ids = matches.data.map(\.conversation_id)
        if ids.isEmpty { return [] }
        let summaries: Page<Conversation> = try await json("GET", ["groups", workspace.groupID, "task-summaries"],
            query: [URLQueryItem(name: "ids", value: ids.joined(separator: ","))])
        guard summaries.data.count <= limit, summaries.data.allSatisfy({ $0.groupID == workspace.groupID && $0.isTask && ids.contains($0.id) }) else { throw CommaError.invalidResponse }
        let byID = Dictionary(summaries.data.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        return ids.compactMap { byID[$0] }
    }

    public func conversation(target: ConversationTarget, messageLimit: Int = 24) async throws -> Conversation {
        guard (1...100).contains(messageLimit) else { throw CommaError.invalidInput("Message limit must be between 1 and 100.") }
        var result: Conversation = try await json("GET", path(target), query: [URLQueryItem(name: "message_limit", value: String(messageLimit))])
        result = result.keepingMessageTail(messageLimit)
        try validate(result, target: target); return result
    }

    public func messageHistory(target: ConversationTarget, before: Int? = nil, limit: Int = 100) async throws -> MessagePage {
        guard (1...100).contains(limit), before == nil || before! > 0 else { throw CommaError.invalidInput("Message history bounds are invalid.") }
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let before { query.append(URLQueryItem(name: "before", value: String(before))) }
        let page: MessagePage = try await json("GET", path(target) + ["messages"], query: query)
        guard page.data.count <= limit else { throw CommaError.responseTooLarge }; return page
    }

    /// Allocate requestID when the pending bubble is created and retain it on retries.
    public func send(target: ConversationTarget, text: String, requestID: String,
                     attachments: [ContentBlock] = [], replyToMessageID: String? = nil) async throws -> Conversation {
        guard !requestID.isEmpty && requestID.utf8.count <= 256, attachments.count <= 8 else { throw CommaError.invalidInput("Message request or attachment count is invalid.") }
        var messageText = text
        if !attachments.isEmpty {
            let lines = try attachments.map { attachment -> String in
                guard attachment.type == "workspace_file", let name = attachment.fields["name"]?.string,
                      let path = attachment.fields["path"]?.string, path.hasPrefix("/"),
                      !name.contains("\n"), !name.contains("\r"), !path.contains("\n"), !path.contains("\r") else {
                    throw CommaError.invalidInput("The uploaded file reference is invalid.")
                }
                return "- \(name) (workspace file: \(path))"
            }
            messageText = (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "I've attached some files:" : text) +
                "\n\nAttached files in your workspace:\n" + lines.joined(separator: "\n")
        }
        guard !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CommaError.invalidInput("Write a message or attach a file.") }
        var body: [String: JSONValue] = ["client_request_id": .string(requestID), "message": .object(["type": .string("text"), "text": .string(messageText)])]
        if let replyToMessageID { body["reply_to_message_id"] = .string(replyToMessageID) }
        var result: Conversation = try await json("POST", path(target) + ["messages"],
            query: [URLQueryItem(name: "message_limit", value: "24")], body: body)
        result = result.keepingMessageTail(24)
        try validate(result, target: target); return result
    }

    public func acceptTask(target: ConversationTarget, reviewVersion: Int) async throws -> Conversation {
        guard reviewVersion > 0 else { throw CommaError.invalidInput("Refresh this task before accepting its review.") }
        var result: Conversation = try await json("POST", path(target) + ["accept"],
            query: [URLQueryItem(name: "message_limit", value: "24")], body: ["review_version": .number(Double(reviewVersion))])
        result = result.keepingMessageTail(24)
        try validate(result, target: target); return result
    }

    public func cancelTask(target: ConversationTarget) async throws -> Conversation {
        let result: Conversation = try await json("POST", path(target) + ["cancel"], body: [:])
        try validate(result, target: target); return result
    }

    /// Replaces the Task's labels with ids from the Group catalog.
    public func setTaskLabels(target: ConversationTarget, labelIDs: [String]) async throws -> Conversation {
        var result: Conversation = try await json("PATCH", path(target), body: ["labels": .array(labelIDs.map(JSONValue.string))])
        result = result.keepingMessageTail(24)
        try validate(result, target: target); return result
    }

    public func taskLabels(groupID: String) async throws -> TaskLabelCatalog {
        try await json("GET", ["groups", groupID, "task-labels"])
    }

    public func renameTask(target: ConversationTarget, title: String) async throws -> Conversation {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 200 else { throw CommaError.invalidInput("Enter a task title of at most 200 characters.") }
        var result: Conversation = try await json("PATCH", path(target), body: ["title": .string(trimmed)])
        result = result.keepingMessageTail(24)
        try validate(result, target: target); return result
    }

    /// `version` is the Task's `updated_at`; the server refuses the change when the Task moved on since.
    public func setTaskArchived(target: ConversationTarget, archived: Bool, version: Int) async throws -> Conversation {
        guard version > 0 else { throw CommaError.invalidInput("Refresh this task before archiving it.") }
        var result: Conversation = try await json("POST", path(target) + [archived ? "archive" : "unarchive"],
                                                  body: ["expected_updated_at": .number(Double(version))])
        result = result.keepingMessageTail(24)
        try validate(result, target: target); return result
    }

    public func pinnedTasks(workspace: Workspace) async throws -> [PinnedTask] {
        let page: Page<PinnedTask> = try await json("GET", ["groups", workspace.groupID, "conversation-pins"])
        guard page.data.count <= 100, page.data.allSatisfy({ $0.conversation.groupID == workspace.groupID }) else { throw CommaError.invalidResponse }
        return page.data
    }

    public func setTaskPinned(target: ConversationTarget, pinned: Bool) async throws {
        if pinned {
            let pin: PinnedTask = try await json("PUT", path(target) + ["pin"], body: [:])
            guard pin.conversation.id == target.conversationID else { throw CommaError.invalidResponse }
        } else {
            _ = try await request("DELETE", path(target) + ["pin"])
        }
    }

    /// The Task's active share link, or nil when it is not shared.
    public func taskShare(target: ConversationTarget) async throws -> TaskShare? {
        do { return try await json("GET", path(target) + ["share"]) }
        catch CommaError.http(let status, _, _) where status == 404 { return nil }
    }

    /// Shares the Task, or moves its existing link's cutoff to the latest message.
    public func publishTaskShare(target: ConversationTarget) async throws -> TaskShare {
        try await json("PUT", path(target) + ["share"], body: [:])
    }

    /// Replaces the link; the previous URL stops working.
    public func resetTaskShare(target: ConversationTarget) async throws -> TaskShare {
        try await json("POST", path(target) + ["share", "reset"], body: [:])
    }

    public func revokeTaskShare(target: ConversationTarget) async throws {
        _ = try await request("DELETE", path(target) + ["share"])
    }

    /// One page of a Worker's session ledger, newest first page when `before` is nil.
    public func workerHistory(target: ConversationTarget, participantID: String, before: String? = nil, limit: Int = 50) async throws -> WorkerHistoryPage {
        guard (1...50).contains(limit), !participantID.isEmpty else { throw CommaError.invalidInput("Worker history bounds are invalid.") }
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let before { query.append(URLQueryItem(name: "before", value: before)) }
        let page: WorkerHistoryPage = try await json("GET", path(target) + ["participants", participantID, "history"], query: query)
        guard page.conversationID == target.conversationID, page.participantID == participantID, page.records.count <= limit,
              !page.hasMore || (page.nextBefore != nil && page.nextBefore != before && !page.records.isEmpty) else {
            throw CommaError.invalidResponse
        }
        return page
    }

    public func createTaskLabel(groupID: String, name: String, color: String, description: String? = nil) async throws -> TaskLabelCatalog {
        var body: [String: JSONValue] = ["name": .string(name), "color": .string(color)]
        if let description { body["description"] = .string(description) }
        return try await json("POST", ["groups", groupID, "task-labels"], body: body)
    }

    public func updateTaskLabel(groupID: String, labelID: String, name: String, color: String, description: String? = nil) async throws -> TaskLabelCatalog {
        var body: [String: JSONValue] = ["name": .string(name), "color": .string(color)]
        if let description { body["description"] = .string(description) }
        return try await json("PATCH", ["groups", groupID, "task-labels", labelID], body: body)
    }

    public func deleteTaskLabel(groupID: String, labelID: String) async throws -> TaskLabelCatalog {
        try await json("DELETE", ["groups", groupID, "task-labels", labelID])
    }

    public func resolveTaskLabelProposal(groupID: String, proposalID: String, approve: Bool) async throws -> TaskLabelCatalog {
        try await json("POST", ["groups", groupID, "task-labels", "proposals", proposalID, "resolve"],
                       body: ["decision": .string(approve ? "approve" : "reject")])
    }

    /// `ask` or `auto`.
    public func setTaskLabelApprovalPolicy(groupID: String, policy: String) async throws -> TaskLabelCatalog {
        guard ["ask", "auto"].contains(policy) else { throw CommaError.invalidInput("Unknown label approval policy.") }
        return try await json("PATCH", ["groups", groupID, "task-labels", "policy"], body: ["approval_policy": .string(policy)])
    }

    public func recommendations(workspace: Workspace, timeZone: TimeZone = .current) async throws -> RecommendationFeed {
        let envelope: JSONValue = try await json("GET", ["workspaces", workspace.id, "recommendations"],
                                                 query: [URLQueryItem(name: "timezone", value: timeZone.identifier)])
        return try RecommendationFeed(envelope: envelope)
    }

    /// Asks the server to generate a new snapshot and returns the envelope it reports, normally `refreshing`.
    /// A refresh past the hourly budget fails with HTTP 429.
    public func refreshRecommendations(workspace: Workspace) async throws -> RecommendationFeed {
        let result: [String: JSONValue] = try await json("POST", ["workspaces", workspace.id, "recommendations", "refresh"], body: [:])
        guard let envelope = result["envelope"] else { throw CommaError.invalidResponse }
        return try RecommendationFeed(envelope: envelope)
    }

    public func profile() async throws -> UserProfile {
        try await json("GET", ["me", "profile"])
    }

    public func updateProfile(name: String) async throws -> UserProfile {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= UserProfile.maxNameLength else {
            throw CommaError.invalidInput("Enter a name of at most \(UserProfile.maxNameLength) characters.")
        }
        return try await json("PATCH", ["me", "profile"], body: ["name": .string(trimmed)])
    }

    /// JPEG, PNG or WebP of at most 2 MB; the server checks the bytes, not the declared type.
    public func uploadAvatar(data: Data, contentType: String) async throws -> UserProfile {
        guard !data.isEmpty, data.count <= UserProfile.maxAvatarBytes, ["image/jpeg", "image/png", "image/webp"].contains(contentType) else {
            throw CommaError.invalidInput("Choose a JPEG, PNG or WebP image of at most 2 MB.")
        }
        let boundary = "Comma-" + UUID().uuidString
        let filename = "avatar." + (contentType == "image/png" ? "png" : contentType == "image/webp" ? "webp" : "jpg")
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"avatar\"; filename=\"\(filename)\"\r\nContent-Type: \(contentType)\r\n\r\n".utf8)
        body.append(data); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        let response = try await request("PUT", ["me", "avatar"], body: body, contentType: "multipart/form-data; boundary=\(boundary)")
        return try decode(UserProfile.self, data: response.data)
    }

    public func deleteAvatar() async throws -> UserProfile {
        try await json("DELETE", ["me", "avatar"])
    }

    public func avatar(id: String) async throws -> Data {
        let response = try await request("GET", ["me", "avatar", id])
        guard response.data.count <= UserProfile.maxAvatarBytes else { throw CommaError.responseTooLarge }
        return response.data
    }

    public func authSessions(cursor: String? = nil) async throws -> Page<AuthSessionRecord> {
        var query = [URLQueryItem(name: "limit", value: "50")]
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        let page: Page<AuthSessionRecord> = try await json("GET", ["auth", "sessions"], query: query)
        guard page.data.count <= 50 else { throw CommaError.responseTooLarge }
        return page
    }

    /// Revokes another Auth Session and the Watch sessions paired from it. Use `logout()` for this one.
    public func revokeAuthSession(id: String) async throws {
        guard id != session?.id else { throw CommaError.invalidInput("Sign out to end this device's session.") }
        _ = try await request("DELETE", ["auth", "sessions", id])
    }

    /// Revokes every other Auth Session and returns how many were revoked.
    public func revokeOtherAuthSessions() async throws -> Int {
        let result: [String: JSONValue] = try await json("POST", ["auth", "sessions", "revoke-all"], body: ["keep_current": .bool(true)])
        guard let count = result["revoked_count"]?.number else { throw CommaError.invalidResponse }
        return Int(count)
    }

    public func uploadFile(workspace: Workspace, filename: String, contentType: String, data: Data) async throws -> ContentBlock {
        guard data.count <= 10_000_000, !filename.isEmpty, filename.utf8.count <= 1_024,
              !filename.contains("\n"), !filename.contains("\r"), !contentType.contains("\n"), !contentType.contains("\r") else {
            throw CommaError.invalidInput("Files must be at most 10 MB with a valid name.")
        }
        let boundary = "Comma-" + UUID().uuidString
        let safeName = filename.replacingOccurrences(of: "\\", with: "_").replacingOccurrences(of: "\"", with: "_")
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\nContent-Type: \(contentType)\r\n\r\n".utf8)
        body.append(data); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        let response = try await request("POST", ["groups", workspace.groupID, "files"], body: body, contentType: "multipart/form-data; boundary=\(boundary)")
        let raw = try decode([String: JSONValue].self, data: response.data)
        guard let path = raw["path"]?.string, path.hasPrefix("/"), let name = raw["name"]?.string, let size = raw["size"] else { throw CommaError.invalidResponse }
        return ContentBlock(type: "workspace_file", fields: ["path": .string(path), "name": .string(name), "size": size])
    }

    public func download(target: ConversationTarget, messageID: String, index: Int) async throws -> DownloadedAttachment {
        guard index >= 0 && index < 8 else { throw CommaError.invalidInput("Attachment index is invalid.") }
        let response = try await request("GET", path(target) + ["messages", messageID, "attachments", String(index)])
        guard response.data.count <= 10_000_000 else { throw CommaError.responseTooLarge }
        return DownloadedAttachment(data: response.data, contentType: response.headers["content-type"] ?? "application/octet-stream")
    }

    public func registerDeviceToken(_ token: String, environment: PushEnvironment, workspace: Workspace,
                                    bundleID: String? = nil, locale: String? = nil) async throws -> NotificationRegistration {
        try await registerPush(kind: "devices", token: token, environment: environment, workspace: workspace, bundleID: bundleID, locale: locale)
    }

    public func registerPushToStartToken(_ token: String, environment: PushEnvironment, workspace: Workspace,
                                    bundleID: String? = nil, locale: String? = nil) async throws -> NotificationRegistration {
        try await registerPush(kind: "push-to-start", token: token, environment: environment, workspace: workspace, bundleID: bundleID, locale: locale)
    }

    public func registerLiveActivityToken(_ token: String, environment: PushEnvironment, workspace: Workspace,
                                         activityID: String, taskID: String, bundleID: String? = nil, locale: String? = nil) async throws -> NotificationRegistration {
        try await registerPush(kind: "live-activities", token: token, environment: environment, workspace: workspace, bundleID: bundleID, locale: locale,
                               extra: ["activity_id": .string(activityID), "task_id": .string(taskID)])
    }

    /// Idempotently retires only the authenticated session's ordinary device slot.
    /// A 204, not a guessed registration ID, is the proof used for legacy reconciliation.
    public func unregisterDeviceNotifications() async throws {
        let response = try await request("DELETE", ["notifications", "devices"])
        guard response.status == 204 else { throw CommaError.invalidResponse }
    }

    /// Keeps the bearer private while binding compensating deletion to its original session.
    public func deviceNotificationChannel() throws -> any DeviceNotificationTransport {
        guard let credential, !signingOut else { throw CommaError.notSignedIn }
        return SessionDeviceNotificationChannel(sessionID: credential.session.id, accountID: credential.session.user.id,
            registerOperation: { [self] token, environment, workspace, bundleID, locale in
                guard let result = try await self.deviceRequest(credential: credential, token: token, environment: environment,
                                             workspace: workspace, bundleID: bundleID, locale: locale) else { throw CommaError.invalidResponse }
                return result
            }, retireOperation: { [self] in
                _ = try await self.deviceRequest(credential: credential)
            })
    }

    private func deviceRequest(credential captured: StoredCredential, token: String? = nil,
                               environment: PushEnvironment? = nil, workspace: Workspace? = nil,
                               bundleID: String? = nil, locale: String? = nil) async throws -> NotificationRegistration? {
        let registering = token != nil
        // An old channel can DELETE its own slot, but must never initiate a new old-session POST.
        if registering {
            guard !signingOut, credential?.session.id == captured.session.id,
                  credential?.session.user.id == captured.session.user.id else { throw CommaError.staleSession }
        }
        var body: Data?
        if let token, let environment, let workspace, let bundleID, let locale {
            body = try JSONEncoder().encode(["token": token, "environment": environment.rawValue,
                "workspace_id": workspace.id, "group_id": workspace.groupID, "bundle_id": bundleID, "locale": locale])
        }
        let request = try makeRequest(registering ? "POST" : "DELETE", ["notifications", "devices"],
                                      query: [], body: body, authenticated: false, token: captured.token)
        // Do not generation-cancel this mutation: observe it settle before compensating
        // for an identity change. URLSession bounds inactivity to 15 seconds and
        // the existing transport bounds the entire resource transfer to 60 seconds.
        let response = try await transport.data(for: request)
        try validateHTTP(response, authenticated: false)
        if !registering {
            guard response.status == 204 else { throw CommaError.invalidResponse }
            return nil
        }
        let result = try decode(NotificationRegistration.self, data: response.data)
        guard result.status == "active" else { throw CommaError.invalidResponse }
        return result
    }

    public func unregisterNotification(id: String) async throws {
        _ = try await request("DELETE", ["notifications", "registrations", id])
    }

    public func conversationEvents(target: ConversationTarget) -> ConversationEventConnection {
        events(path(target) + ["events"], query: [URLQueryItem(name: "wait", value: "30000"), URLQueryItem(name: "message_limit", value: "24")], target: target)
    }

    public func taskEvents(workspace: Workspace, conversationID: String? = nil) -> ConversationEventConnection {
        var query = [URLQueryItem(name: "wait", value: "30000")]
        if let conversationID { query.append(URLQueryItem(name: "conversation_id", value: conversationID)) }
        return events(["groups", workspace.groupID, "conversations", "events"], query: query,
                      target: conversationID.map { ConversationTarget(workspaceID: workspace.id, groupID: workspace.groupID, conversationID: $0) })
    }

    /// A consumer that exits iteration early must cancel explicitly; `break` alone does not terminate AsyncStream.
    public func cancelConversationEvents(target: ConversationTarget) { cancelEvents(path(target) + ["events"]) }
    public func cancelTaskEvents(workspace: Workspace) { cancelEvents(["groups", workspace.groupID, "conversations", "events"]) }

    /// Cancels foreground streams/requests without revoking an independently running server task.
    public func suspend() { advanceGeneration() }

    private func registerPush(kind: String, token: String, environment: PushEnvironment, workspace: Workspace,
                              bundleID: String? = nil, locale: String? = nil,
                              extra: [String: JSONValue] = [:]) async throws -> NotificationRegistration {
        var body: [String: JSONValue] = ["token": .string(token), "environment": .string(environment.rawValue), "workspace_id": .string(workspace.id), "group_id": .string(workspace.groupID)]
        if let bundleID { body["bundle_id"] = .string(bundleID) }
        if let locale { body["locale"] = .string(locale) }
        let registration: NotificationRegistration = try await json("POST", ["notifications", kind], body: body.merging(extra) { _, v in v })
        guard registration.status == "active" else { throw CommaError.invalidResponse }; return registration
    }

    private var clientMetadata: [String: JSONValue] { ["client_kind": .string(platform == .watchos ? "watch" : "ios"), "client_platform": .string(platform.rawValue)] }
    private func path(_ target: ConversationTarget) -> [String] { ["groups", target.groupID, "conversations", target.conversationID] }
    private func validate(_ conversation: Conversation, target: ConversationTarget) throws {
        guard conversation.id == target.conversationID && conversation.groupID == target.groupID else { throw CommaError.invalidResponse }
    }

    private func json<T: Decodable>(_ method: String, _ path: [String], query: [URLQueryItem] = [], body: [String: JSONValue]? = nil,
                                     authenticated: Bool = true) async throws -> T {
        let response = try await request(method, path, query: query, body: try body.map { try JSONEncoder().encode($0) }, authenticated: authenticated)
        return try decode(T.self, data: response.data)
    }
    private func decode<T: Decodable>(_ type: T.Type, data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) } catch { throw CommaError.invalidResponse }
    }

    private func request(_ method: String, _ path: [String], query: [URLQueryItem] = [], body: Data? = nil,
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

    private func makeRequest(_ method: String, _ path: [String], query: [URLQueryItem], body: Data? = nil,
                             contentType: String = "application/json", authenticated: Bool = true, token: String? = nil) throws -> URLRequest {
        var url = baseURL.appendingPathComponent("v1").appendingPathComponent("comma")
        for segment in path {
            guard !segment.isEmpty && !segment.contains("/") && segment != "." && segment != ".." else { throw CommaError.invalidInput("Resource identity is invalid.") }
            url.appendPathComponent(segment)
        }
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        parts.queryItems = query.isEmpty ? nil : query
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

    private func validateHTTP(_ response: HTTPResponse, authenticated: Bool) throws {
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
    private func assertCurrent(_ expected: Int) throws { guard generation == expected else { throw CommaError.staleSession } }
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

    private func events(_ path: [String], query: [URLQueryItem], target: ConversationTarget?) -> ConversationEventConnection {
        // Replace a finite stream before reconnecting, including when the previous consumer only broke its loop.
        cancelEvents(path)
        let expected = generation
        let id = UUID()
        let key = path.joined(separator: "/")
        let (events, continuation) = AsyncThrowingStream<ConversationEvent, any Error>.makeStream(bufferingPolicy: .bufferingOldest(128))
        let task = Task {
            defer {
                self.cancellation.removeValue(forKey: id)
                if self.eventConnections[key] == id { self.eventConnections.removeValue(forKey: key) }
            }
            do {
                var request = try self.makeRequest("GET", path, query: query)
                request.timeoutInterval = 40; request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                let stream = try await self.transport.stream(for: request)
                defer { stream.cancel() }
                try Task.checkCancellation()
                try self.assertCurrent(expected)
                try self.validateHTTP(HTTPResponse(data: Data(), status: stream.status, url: stream.url, headers: stream.headers), authenticated: true)
                guard stream.headers["content-type"]?.lowercased().hasPrefix("text/event-stream") == true else { throw CommaError.invalidResponse }
                try await withTaskCancellationHandler {
                    var parser = SSEParser()
                    for try await chunk in stream.chunks {
                        try Task.checkCancellation(); try self.assertCurrent(expected)
                        for frame in try parser.append(chunk) {
                            var event = try self.decode(ConversationEvent.self, data: frame.data)
                            // Servers before message_limit support send the whole transcript; the tail is enough.
                            if let messages = event.messages, messages.count > 24 { event.messages = Array(messages.suffix(24)) }
                            let groupID = path.count > 1 && path[0] == "groups" ? path[1] : nil
                            guard event.groupID == nil || event.groupID == groupID else { throw CommaError.invalidResponse }
                            if let target {
                                guard event.groupID == nil || event.groupID == target.groupID,
                                      event.conversationID == nil || event.conversationID == target.conversationID else { throw CommaError.invalidResponse }
                            }
                            switch continuation.yield(event) {
                            case .dropped: throw CommaError.responseTooLarge
                            case .terminated: return
                            case .enqueued: break
                            @unknown default: return
                            }
                        }
                    }
                    _ = try parser.finish(); try self.assertCurrent(expected)
                } onCancel: { stream.cancel() }
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
        cancellation[id] = { task.cancel() }
        eventConnections[key] = id
        continuation.onTermination = { @Sendable _ in task.cancel() }
        return ConversationEventConnection(events: events, cancel: { task.cancel() })
    }

    private func cancelEvents(_ path: [String]) {
        guard let id = eventConnections.removeValue(forKey: path.joined(separator: "/")),
              let cancel = cancellation.removeValue(forKey: id) else { return }
        cancel()
    }
}
