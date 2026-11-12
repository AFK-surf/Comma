@preconcurrency import AppAuth
import AuthenticationServices
import Foundation
import UIKit

/// AppAuth owns OAuth and PKCE. Comma's existing Google attempt owns the nonce and session exchange.
struct GoogleSignInSheet: GoogleIdentityTokens {
    func request(clientId: String, nonce: String) async throws -> String {
        let authorization = await GoogleAuthorization()
        return try await withTaskCancellationHandler {
            try await authorization.request(clientId: clientId, nonce: nonce)
        } onCancel: {
            Task { @MainActor in authorization.cancel() }
        }
    }
}

@MainActor
private final class GoogleAuthorization {
    private var flow: (any OIDExternalUserAgentSession)?
    private var waiting: CheckedContinuation<String, any Error>?
    private var cancelled = false

    func request(clientId: String, nonce: String) async throws -> String {
        try Task.checkCancellation()
        guard !cancelled else { throw CancellationError() }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let window = scenes.filter({ $0.activationState == .foregroundActive }).flatMap(\.windows).first(where: \.isKeyWindow) else {
            throw HostFailure(message: "Google sign-in needs an active window.")
        }
        let request = try Self.authorizationRequest(clientId: clientId, nonce: nonce)
        // Use only the system authentication session. Its callback stays inside this operation, without an app-wide URL handler.
        let browser = GoogleAuthenticationBrowser(window: window)
        return try await withCheckedThrowingContinuation { continuation in
            waiting = continuation
            flow = OIDAuthState.authState(byPresenting: request, externalUserAgent: browser) { [weak self] state, error in
                // AppAuth delivers its completion on the main queue.
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let token = state?.lastTokenResponse?.idToken, !token.isEmpty {
                        self.settle(.success(token))
                    } else if let error {
                        let error = error as NSError
                        if error.domain == OIDGeneralErrorDomain && error.code == OIDErrorCode.userCanceledAuthorizationFlow.rawValue {
                            self.settle(.failure(CancellationError()))
                        } else {
                            self.settle(.failure(HostFailure(message: "Google sign-in could not finish.")))
                        }
                    } else {
                        self.settle(.failure(HostFailure(message: "Google sign-in returned no identity token.")))
                    }
                }
            }
        }
    }

    static func authorizationRequest(clientId: String, nonce: String) throws -> OIDAuthorizationRequest {
        guard clientId.hasSuffix(".apps.googleusercontent.com"), !nonce.isEmpty,
              let redirect = URL(string: clientId.split(separator: ".").reversed().joined(separator: ".") + ":/oauthredirect") else {
            throw HostFailure(message: "Google sign-in is not configured for this app.")
        }
        let service = OIDServiceConfiguration(authorizationEndpoint: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
                                              tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!)
        return OIDAuthorizationRequest(configuration: service, clientId: clientId,
                                       scopes: [OIDScopeOpenID, OIDScopeEmail, OIDScopeProfile], redirectURL: redirect,
                                       responseType: OIDResponseTypeCode, nonce: nonce,
                                       additionalParameters: ["prompt": "select_account"])
    }

    func cancel() {
        cancelled = true
        let current = flow
        settle(.failure(CancellationError()))
        current?.cancel()
    }

    private func settle(_ result: Result<String, any Error>) {
        let continuation = waiting
        waiting = nil
        flow = nil
        continuation?.resume(with: result)
    }
}

/// AppAuth validates callback state and exchanges the code. The system browser handles presentation and cancellation.
@MainActor
private final class GoogleAuthenticationBrowser: NSObject, @preconcurrency OIDExternalUserAgent, ASWebAuthenticationPresentationContextProviding {
    private let window: UIWindow
    private var browser: ASWebAuthenticationSession?

    init(window: UIWindow) { self.window = window }

    func present(_ request: any OIDExternalUserAgentRequest, session: any OIDExternalUserAgentSession) -> Bool {
        let browser = ASWebAuthenticationSession(url: request.externalUserAgentRequestURL(), callbackURLScheme: request.redirectScheme()) { url, error in
            if let url { _ = session.resumeExternalUserAgentFlow(with: url) }
            else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                session.failExternalUserAgentFlowWithError(NSError(domain: OIDGeneralErrorDomain,
                    code: OIDErrorCode.userCanceledAuthorizationFlow.rawValue, userInfo: nil))
            } else {
                session.failExternalUserAgentFlowWithError(error ?? NSError(domain: OIDGeneralErrorDomain,
                    code: OIDErrorCode.browserOpenError.rawValue, userInfo: nil))
            }
        }
        browser.presentationContextProvider = self
        self.browser = browser
        return browser.start()
    }

    func dismiss(animated: Bool, completion: @escaping () -> Void) {
        browser?.cancel()
        browser = nil
        completion()
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { window }
}
