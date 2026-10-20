import AuthenticationServices
import Foundation
import CommaCore

@MainActor
enum AppleCredentialMonitor {
    static var pendingSubject: String?
    private static let subjectKey = "comma.apple-login.subject"
    private static let sessionKey = "comma.apple-login.session"

    static func save(subject: String, sessionID: String) {
        UserDefaults.standard.set(subject, forKey: subjectKey)
        UserDefaults.standard.set(sessionID, forKey: sessionKey)
        pendingSubject = nil
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: subjectKey)
        UserDefaults.standard.removeObject(forKey: sessionKey)
        pendingSubject = nil
    }

    static func validate(_ session: CommaSession) async throws -> Bool {
        guard UserDefaults.standard.string(forKey: sessionKey) == session.id,
              let subject = UserDefaults.standard.string(forKey: subjectKey) else { return true }
        let state = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ASAuthorizationAppleIDProvider.CredentialState, any Error>) in
            ASAuthorizationAppleIDProvider().getCredentialState(forUserID: subject) { state, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: state) }
            }
        }
        return state == .authorized
    }
}
