import Foundation

// Workspaces, the Routines recommendation feed, the skills catalog, the member profile and Auth Session management.
extension CommaClient {
    public func listWorkspaces() async throws -> [Workspace] {
        let page: Page<Workspace> = try await json("GET", ["workspaces"])
        guard page.data.count <= 100 else { throw CommaError.responseTooLarge }
        return page.data
    }

    public func bootstrapWorkspace() async throws -> WorkspaceBootstrap {
        try await json("POST", ["me", "bootstrap"], body: [:])
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

    /// The Workspace's skills, as the composer's / menu lists them. A restricted session gets HTTP 403
    /// `forbidden`; a catalog the server cannot read, 503 `skills_unavailable`.
    public func skills(workspace: Workspace) async throws -> [Skill] {
        let page: Page<Skill> = try await json("GET", ["workspaces", workspace.id, "skills"])
        guard page.data.count <= 1_000 else { throw CommaError.responseTooLarge }
        return page.data
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
}
