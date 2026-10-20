import Foundation
import CommaCore

/// Sign-in, sign-out and session restore, and the member's profile and avatar.
extension CommaStore {
    // MARK: Session

    func start(loadProduct: Bool = true, preferredWorkspaceID: String? = nil) async {
        let current = boundary
        loading = true
        defer { if boundary == current { loading = false; initialized = true } }
        do {
            // The Apple credential check is its own round trip to Apple; run it beside the session check,
            // keyed by the Keychain session. Both must pass before the session is used, as before.
            let stored = try? await client.storedSession()
            let appleCheck = Task { @MainActor [weak self] () throws -> Bool in
                guard let stored, let validate = self?.validateSession else { return true }
                return try await validate(stored)
            }
            let restored = try await client.restoreSession()
            var authorized = try await appleCheck.value
            guard boundary == current else { return }
            // restoreSession refuses a different session, so this only covers an absent Keychain entry.
            if let restored, restored.id != stored?.id, let validateSession {
                authorized = try await validateSession(restored)
            }
            if restored != nil, !authorized {
                try await client.clearLocalSession()
                throw CommaError.invalidInput("Apple authorization was revoked. Sign in again.")
            }
            guard boundary == current else { return }
            session = restored
            onSessionChanged?(restored)
            // The shell shows now; the router chat and the task list load inside it with their own indicators.
            initialized = true
            if restored != nil {
                if loadProduct { try await self.loadProduct(boundary: current) }
                else { try await restoreBackgroundWorkspace(boundary: current, preferredWorkspaceID: preferredWorkspaceID) }
            }
        } catch { present(error, boundary: current) }
    }

    func requestEmailCode(email: String) async throws -> EmailChallenge {
        try await client.requestEmailLogin(email: email)
    }

    /// Returns false when the code was rejected, so the login screen can show its error feedback.
    @discardableResult
    func verifyEmail(challengeID: String, code: String, appleLink: Bool = false) async -> Bool {
        let current = resetBoundary()
        loading = true
        defer { if boundary == current { loading = false } }
        let result: CommaSession
        do {
            result = appleLink
                ? try await client.verifyAppleLink(challengeID: challengeID, code: code)
                : try await client.verifyEmailLogin(challengeID: challengeID, code: code)
        } catch {
            present(error, boundary: current)
            return false
        }
        guard boundary == current else { return true }
        session = result
        onSessionChanged?(result)
        do { try await loadProduct(boundary: current) } catch { present(error, boundary: current) }
        return true
    }

    func signedIn(_ result: CommaSession) async {
        guard await client.session?.id == result.id else { return }
        let current = resetBoundary()
        session = result
        onSessionChanged?(result)
        loading = true
        defer { if boundary == current { loading = false } }
        do { try await loadProduct(boundary: current) }
        catch { present(error, boundary: current) }
    }

    func logout() async {
        boundary += 1
        onAuthBoundaryChanged?()
        for pane in panes { pane.invalidateSends() }
        let current = boundary
        stopStreams()
        loading = true
        defer { if boundary == current { loading = false } }
        do {
            await beforeLogout?()
            try await client.logout()
            guard boundary == current else { return }
            clearProduct()
            session = nil
            onSessionChanged?(nil)
        } catch {
            present(error, boundary: current)
            if boundary == current { onSessionChanged?(session); startStreams() }
        }
    }

    func invalidateLocalSession() async {
        let current = resetBoundary()
        do { try await client.clearLocalSession() } catch { present(error, boundary: current) }
        guard boundary == current else { return }
        session = nil
        onSessionChanged?(nil)
    }

    // MARK: Profile

    /// The member's name as the profile, else the session, has it; nil while neither has one.
    var memberName: String? {
        [profile?.name, session?.user.name]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    /// The member's email as the profile, else the session, has it.
    var memberEmail: String { profile?.email ?? session?.user.email ?? "" }

    /// Reads the profile and avatar once per session; later calls reuse them.
    func loadProfile() async {
        guard session != nil else { return }
        if let profileLoad { return await profileLoad.value }
        let current = boundary
        let load = Task { [weak self] in
            guard let self else { return }
            do {
                let value = try await self.client.profile()
                guard self.boundary == current else { return }
                await self.install(profile: value, boundary: current)
            } catch {
                // The avatar is decoration: without it the initials show.
                guard self.boundary == current else { return }
                self.profileLoad = nil
            }
        }
        profileLoad = load
        await load.value
    }

    /// Reads the profile again, as a pull to refresh asks.
    func reloadProfile() async {
        profileLoad = nil
        await loadProfile()
    }

    func updateProfile(name: String) async throws {
        let current = boundary
        let value = try await client.updateProfile(name: name)
        guard boundary == current else { return }
        await install(profile: value, boundary: current)
    }

    /// Shows the new photo everywhere at once while it uploads; a failed upload puts the old one back.
    func uploadAvatar(_ data: Data, contentType: String) async throws {
        try await changeAvatar(to: data) { try await self.client.uploadAvatar(data: data, contentType: contentType) }
    }

    /// Takes the photo down at once while the server removes it; a failure puts it back.
    func removeAvatar() async throws {
        try await changeAvatar(to: nil) { try await self.client.deleteAvatar() }
    }

    private func changeAvatar(to data: Data?, _ request: () async throws -> UserProfile) async throws {
        let current = boundary
        let previous = avatarData
        avatarData = data
        do {
            let value = try await request()
            guard boundary == current else { return }
            profile = value
            // The server kept no photo after all.
            if data != nil, value.avatarID == nil { avatarData = previous }
        } catch {
            if boundary == current { avatarData = previous }
            throw error
        }
    }

    private func install(profile value: UserProfile, boundary current: Int) async {
        let changedAvatar = value.avatarID != profile?.avatarID
        profile = value
        guard changedAvatar else { return }
        avatarData = nil
        guard let id = value.avatarID, let data = try? await client.avatar(id: id), boundary == current, profile?.avatarID == id else { return }
        avatarData = data
    }
}
