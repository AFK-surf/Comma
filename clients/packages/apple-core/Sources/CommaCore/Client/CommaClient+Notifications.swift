import Foundation

// Push registration, Task activity, Router unread state and session-bound notification channels.
extension CommaClient {
    public func registerDeviceToken(_ token: String, environment: PushEnvironment, workspace: Workspace,
                                    bundleID: String? = nil, locale: String? = nil) async throws -> NotificationRegistration {
        try await registerPush(kind: "devices", token: token, environment: environment, workspace: workspace, bundleID: bundleID, locale: locale)
    }

    public func registerPushToStartToken(_ token: String, environment: PushEnvironment, workspace: Workspace,
                                    bundleID: String? = nil, locale: String? = nil) async throws -> NotificationRegistration {
        try await registerPush(kind: "push-to-start", token: token, environment: environment, workspace: workspace, bundleID: bundleID, locale: locale,
                               extra: ["activity_schema": .string("tasks_v1")])
    }

    public func registerLiveActivityToken(_ token: String, environment: PushEnvironment, workspace: Workspace,
                                         activityID: String, bundleID: String? = nil, locale: String? = nil) async throws -> NotificationRegistration {
        try await registerPush(kind: "live-activities", token: token, environment: environment, workspace: workspace, bundleID: bundleID, locale: locale,
                               extra: ["activity_id": .string(activityID), "activity_schema": .string("tasks_v1")])
    }

    public func taskActivity(workspace: Workspace) async throws -> TaskActivitySnapshot {
        let result: TaskActivitySnapshot = try await json("GET", ["groups", workspace.groupID, "task-activity"])
        guard result.data.count <= 2, Set(result.data.map(\.id)).count == result.data.count,
              result.data.allSatisfy({ $0.groupID == workspace.groupID && $0.isTask && [.inProgress, .needsReview].contains($0.bucket) }) else {
            throw CommaError.invalidResponse
        }
        return result
    }

    public func routerNotifications(workspace: Workspace) async throws -> RouterNotificationSnapshot {
        let result: RouterNotificationSnapshot = try await json("GET", ["groups", workspace.groupID, "router-notifications"])
        try validate(result)
        return result
    }

    /// A displayed Message is resolved to its canonical position by the server.
    public func readRouterNotifications(workspace: Workspace, messageID: String) async throws -> RouterNotificationSnapshot {
        guard !messageID.isEmpty, messageID.utf8.count <= 256 else { throw CommaError.invalidResponse }
        let result: RouterNotificationSnapshot = try await json("POST", ["groups", workspace.groupID, "router-notifications", "read"],
                                                               body: ["message_id": .string(messageID)])
        try validate(result)
        return result
    }

    private func validate(_ snapshot: RouterNotificationSnapshot) throws {
        guard snapshot.unreadCount >= 0, snapshot.latestSequence >= 0 else { throw CommaError.invalidResponse }
        if let id = snapshot.conversationID {
            guard !id.isEmpty else { throw CommaError.invalidResponse }
        } else {
            guard snapshot.unreadCount == 0, snapshot.latestSequence == 0, snapshot.latestMessageID == nil else {
                throw CommaError.invalidResponse
            }
        }
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

    public func activityNotificationChannel(workspace: Workspace, environment: PushEnvironment,
                                            bundleID: String, locale: String) throws -> any ActivityNotificationTransport {
        guard let captured = credential, !signingOut else { throw CommaError.notSignedIn }
        return SessionActivityNotificationChannel(sessionID: captured.session.id, accountID: captured.session.user.id,
            registerOperation: { [self] token, activityID, registrationID in
                try await self.activityRequest(credential: captured, workspace: workspace, environment: environment,
                                               bundleID: bundleID, locale: locale, token: token, activityID: activityID, registrationID: registrationID)
            }, retireOperation: { [self] id, reason in
                let request = try await self.makeRequest("DELETE", ["notifications", "registrations", id],
                    query: [URLQueryItem(name: "reason", value: reason.rawValue)], body: nil,
                    authenticated: false, token: captured.token)
                let response = try await self.transport.data(for: request)
                try await self.validateHTTP(response, authenticated: false)
                guard response.status == 204 else { throw CommaError.invalidResponse }
            })
    }

    private func activityRequest(credential captured: StoredCredential, workspace: Workspace, environment: PushEnvironment,
                                 bundleID: String, locale: String, token: String, activityID: String?, registrationID: String) async throws -> NotificationRegistration {
        guard !signingOut, credential?.session.id == captured.session.id,
              credential?.session.user.id == captured.session.user.id else { throw CommaError.staleSession }
        guard UUID(uuidString: registrationID) != nil else { throw CommaError.invalidInput("Registration id must be a UUID") }
        var body = ["token": token, "environment": environment.rawValue, "workspace_id": workspace.id,
                    "group_id": workspace.groupID, "bundle_id": bundleID, "locale": locale, "activity_schema": "tasks_v1"]
        body["registration_id"] = registrationID
        if let activityID { body["activity_id"] = activityID }
        let request = try makeRequest("POST", ["notifications", activityID == nil ? "push-to-start" : "live-activities"],
                                      query: [], body: JSONEncoder().encode(body), authenticated: false, token: captured.token)
        let response = try await transport.data(for: request)
        try validateHTTP(response, authenticated: false)
        let result = try decode(NotificationRegistration.self, data: response.data)
        guard result.status == "active", result.id.caseInsensitiveCompare(registrationID) == .orderedSame else { throw CommaError.invalidResponse }
        return result
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

    public func unregisterNotification(id: String, reason: ActivityRetirementReason? = nil) async throws {
        _ = try await request("DELETE", ["notifications", "registrations", id],
                              query: reason.map { [URLQueryItem(name: "reason", value: $0.rawValue)] } ?? [])
    }

    private func registerPush(kind: String, token: String, environment: PushEnvironment, workspace: Workspace,
                              bundleID: String? = nil, locale: String? = nil,
                              extra: [String: JSONValue] = [:]) async throws -> NotificationRegistration {
        var body: [String: JSONValue] = ["token": .string(token), "environment": .string(environment.rawValue), "workspace_id": .string(workspace.id), "group_id": .string(workspace.groupID)]
        if let bundleID { body["bundle_id"] = .string(bundleID) }
        if let locale { body["locale"] = .string(locale) }
        let registration: NotificationRegistration = try await json("POST", ["notifications", kind], body: body.merging(extra) { _, v in v })
        guard registration.status == "active" else { throw CommaError.invalidResponse }; return registration
    }
}
