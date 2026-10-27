import AuthenticationServices
import CommaCore
import Foundation
import os
import UIKit

/// The process's client core and what it keeps for it. One per process; it outlives every scene.
final class CoreRuntime: Sendable {
    let core: CoreClient
    let host: CoreHost
    let custody: SessionCustody
    let apple: AppleSignInSheet

    /// The core's script as the app carries it: Hermes bytecode, compiled by the Comma target's "Bundle the client
    /// core" build phase (packages/core/scripts/mobile-bundle.ts).
    static let script = "core.hbc"

    private init(core: CoreClient, host: CoreHost, custody: SessionCustody, apple: AppleSignInSheet) {
        self.core = core; self.host = host; self.custody = custody; self.apple = apple
    }

    /**
     * Builds the process's client core for the Comma API at `baseURL`: Hermes running the shared TypeScript core, its
     * requests and databases in this app, the bearer in `SessionCustody`. A session an earlier version kept in the
     * Keychain moves into the new credential store first, so an update does not sign the person out.
     */
    static func make(baseURL: URL) throws -> CoreRuntime {
        let audience = try SessionCustody.canonicalAudience(baseURL.absoluteString)
        let custody = try SessionCustody(record: KeychainRecord(service: "surf.comma.ios.credentials", account: audience),
                                         apiOrigin: audience)
        adoptEarlierSession(audience: audience, custody: custody)
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        // The core bounds the downloads itself and keeps an index of them: they are not a cache the system may clear.
        var downloadRoot = support.appendingPathComponent("core-downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadRoot, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? downloadRoot.setResourceValues(values)
        let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return try make(custody: custody, dataDirectory: support.appendingPathComponent("core", isDirectory: true),
                        downloadRoot: downloadRoot,
                        localFilesRoot: caches.appendingPathComponent("core-local-files", isDirectory: true))
    }

    /// The client core with the credential store, directories and URL loading given (the app's, or a test's).
    static func make(custody: SessionCustody, dataDirectory: URL, downloadRoot: URL, localFilesRoot: URL? = nil,
                     configuration: URLSessionConfiguration = .default) throws -> CoreRuntime {
        let apple = AppleSignInSheet()
        // Picked files wait here to upload; by default beside the core's data (a test's own directory).
        let localFiles = HostLocalFiles(root: localFilesRoot ?? dataDirectory.appendingPathComponent("local-files"))
        let host = CoreHost(custody: custody, dataDirectory: dataDirectory, downloads: HostDownloads(root: downloadRoot),
                            localFiles: localFiles, apple: apple, configuration: configuration)
        guard let url = Bundle.main.url(forResource: "core", withExtension: "hbc") else {
            throw HostFailure(message: "The app carries no client core (\(script)).")
        }
        let script = try Data(contentsOf: url, options: .mappedIfSafe)
        let log = Logger(subsystem: "surf.comma.ios", category: "core")
        let core = CoreClient(
            engines: { config, engineHost in HermesCoreEngine(script: script, config: config, host: engineHost) },
            host: host,
            onFault: { reason in log.error("\(reason, privacy: .public)") })
        return CoreRuntime(core: core, host: host, custody: custody, apple: apple)
    }

    /// The session an earlier version kept in its Keychain item becomes the credential store's; that item is deleted
    /// once the store has it (or has a credential of its own).
    private static func adoptEarlierSession(audience: String, custody: SessionCustody) {
        let earlier = KeychainCredentialStore(service: "surf.comma.ios.session")
        guard let stored = try? earlier.load(origin: audience) else { return }
        if stored.session.expiresAt > Date().timeIntervalSince1970 {
            custody.adoptEarlier(StoredBearer(token: stored.token, audience: audience, sessionId: stored.session.id,
                                              userId: stored.session.user.id, email: stored.session.user.email,
                                              expiresAtEpochSeconds: Int64(stored.session.expiresAt)))
        }
        try? earlier.delete(origin: audience)
    }
}

/// The iPhone's Sign in with Apple sheet, which the core's `session.apple` shows. It remembers whose Apple ID signed in
/// last, which the app checks again at launch (`AppleCredentialMonitor`).
final class AppleSignInSheet: NSObject, AppleIdentityTokens, ASAuthorizationControllerDelegate,
    ASAuthorizationControllerPresentationContextProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: CheckedContinuation<String, any Error>?
    private var controller: ASAuthorizationController?
    private var chosen: String?

    /// The Apple ID the last sheet gave a token for.
    var subject: String? { lock.withLock { chosen } }

    func request(clientId: String, nonce: String) async throws -> String {
        // The server's Apple client is this app, or Apple's token would not be accepted for it.
        guard clientId == Bundle.main.bundleIdentifier else { throw HostFailure(message: "Sign in with Apple is not set up for this app.") }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    waiting?.resume(throwing: CancellationError())
                    waiting = continuation
                }
                Task { @MainActor in
                    let request = ASAuthorizationAppleIDProvider().createRequest()
                    request.requestedScopes = [.email, .fullName]
                    request.nonce = nonce
                    let controller = ASAuthorizationController(authorizationRequests: [request])
                    controller.delegate = self
                    controller.presentationContextProvider = self
                    self.lock.withLock { self.controller = controller }
                    controller.performRequests()
                }
            }
        } onCancel: {
            Task { @MainActor in self.lock.withLock { self.controller }?.cancel() }
        }
    }

    private func settle(_ result: Result<String, any Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<String, any Error>? in
            defer { waiting = nil; controller = nil }
            return waiting
        }
        continuation?.resume(with: result)
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let data = credential.identityToken, let token = String(data: data, encoding: .utf8) else {
            settle(.failure(HostFailure(message: "Apple sign-in could not finish.")))
            return
        }
        lock.withLock { chosen = credential.user }
        settle(.success(token))
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: any Error) {
        settle(.failure(error))
    }

    @MainActor
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}
