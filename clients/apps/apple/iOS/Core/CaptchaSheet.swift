import Foundation
import UIKit
import WebKit

struct CaptchaSheet: Sendable {
    func request(url: String, challengeId: String, audience: String) async throws -> String? {
        let owner = await CaptchaPresentation.shared
        let operationID = UUID()
        return try await withTaskCancellationHandler {
            try await owner.request(operationID: operationID, url: url, challengeId: challengeId, audience: audience)
        } onCancel: {
            Task { @MainActor in owner.cancel(operationID) }
        }
    }
}

/// Owns each CAPTCHA from installation through UIKit's actual dismissal completion.
@MainActor
final class CaptchaPresentation: NSObject, WKScriptMessageHandler, WKNavigationDelegate, UIAdaptivePresentationControllerDelegate {
    static let shared = CaptchaPresentation()

    private enum Phase { case uninstalled, presenting, presented, dismissing }
    private enum Outcome {
        case token(String), cancelled
        var token: String? { if case .token(let token) = self { return token }; return nil }
    }
    private final class Operation {
        let id: UUID
        let url: URL
        let challengeId: String
        let browser: WKWebView
        let controller: UINavigationController
        var phase = Phase.uninstalled
        var outcome: Outcome?
        var completion: Task<String?, Never>!
        var continuation: CheckedContinuation<String?, Never>?

        init(id: UUID, url: URL, challengeId: String, browser: WKWebView, controller: UINavigationController) {
            self.id = id
            self.url = url
            self.challengeId = challengeId
            self.browser = browser
            self.controller = controller
        }
    }
    private var active: Operation?
    private override init() { super.init() }

    static func sameOrigin(_ left: URL, _ right: URL) -> Bool {
        left.scheme == right.scheme && left.host == right.host && (left.port ?? (left.scheme == "https" ? 443 : 80)) ==
            (right.port ?? (right.scheme == "https" ? 443 : 80))
    }

    func request(operationID: UUID, url: String, challengeId: String, audience: String) async throws -> String? {
        // A successor waits on the active operation's result. Terminal callbacks cannot replace this completion.
        while let previous = active {
            _ = await previous.completion.value
            try Task.checkCancellation()
        }
        try Task.checkCancellation()
        guard let url = URL(string: url), let origin = URL(string: audience),
              Self.sameOrigin(url, origin), ["https", "http"].contains(url.scheme), url.user == nil, url.password == nil,
              url.path == "/v1/comma/auth/captcha", url.fragment == nil, !challengeId.isEmpty,
              let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems, query.count == 2,
              query.first(where: { $0.name == "challenge_id" })?.value == challengeId,
              ["email_login", "registration"].contains(query.first(where: { $0.name == "action" })?.value ?? "") else {
            throw HostFailure(message: "The CAPTCHA address is invalid.")
        }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let window = scenes.filter({ $0.activationState == .foregroundActive }).flatMap(\.windows).first(where: \.isKeyWindow),
              var presenter = window.rootViewController else { throw HostFailure(message: "CAPTCHA needs an active window.") }
        while let presented = presenter.presentedViewController { presenter = presented }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let content = configuration.userContentController
        content.add(self, name: "commaCaptcha")
        // parent.postMessage on the hosted top-level page becomes this one bounded native callback.
        content.addUserScript(WKUserScript(source: "window.addEventListener('message',function(e){if(e.source===window&&e.origin===location.origin)window.webkit.messageHandlers.commaCaptcha.postMessage(e.data)});", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let browser = WKWebView(frame: .zero, configuration: configuration)
        browser.navigationDelegate = self
        let page = UIViewController()
        page.view = browser
        page.navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
            self?.cancel(operationID)
        })
        let controller = UINavigationController(rootViewController: page)
        let operation = Operation(id: operationID, url: url, challengeId: challengeId, browser: browser, controller: controller)
        active = operation
        operation.completion = Task { @MainActor [self, operation] in
            await withCheckedContinuation { continuation in
                operation.continuation = continuation
                if operation.outcome != nil {
                    // Cancellation arrived before the presentation call. Nothing was installed.
                    self.resolve(operation)
                    return
                }
                operation.phase = .presenting
                presenter.present(controller, animated: true) { [weak self, weak operation] in
                    guard let operation else { return }
                    self?.presentationCompleted(operation)
                }
                controller.presentationController?.delegate = self
                browser.load(URLRequest(url: url))
            }
        }
        return await operation.completion.value
    }

    func cancel(_ operationID: UUID) { finish(nil, operationID: operationID) }

    private func finish(_ token: String?, operationID: UUID) {
        guard let operation = active, operation.id == operationID, operation.outcome == nil else { return }
        operation.outcome = token.map(Outcome.token) ?? .cancelled
        detachBrowser(operation)
        // Presentation completion owns the next step when cancellation arrives during presentation.
        if operation.phase == .presented { dismiss(operation) }
    }

    private func presentationCompleted(_ operation: Operation) {
        guard active === operation, operation.phase == .presenting else { return }
        operation.phase = .presented
        if operation.outcome != nil { dismiss(operation) }
    }

    private func dismiss(_ operation: Operation) {
        guard active === operation, operation.phase == .presented else { return }
        operation.phase = .dismissing
        operation.controller.dismiss(animated: true) { [weak self, weak operation] in
            guard let operation else { return }
            self?.resolve(operation)
        }
    }

    private func detachBrowser(_ operation: Operation) {
        operation.browser.navigationDelegate = nil
        operation.browser.stopLoading()
        operation.browser.configuration.userContentController.removeScriptMessageHandler(forName: "commaCaptcha")
    }

    private func resolve(_ operation: Operation) {
        guard active === operation, let outcome = operation.outcome, let continuation = operation.continuation else { return }
        detachBrowser(operation)
        operation.controller.presentationController?.delegate = nil
        operation.continuation = nil
        active = nil
        continuation.resume(returning: outcome.token)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let operation = active, operation.outcome == nil, message.webView === operation.browser,
              message.frameInfo.isMainFrame, let source = message.frameInfo.request.url, Self.sameOrigin(source, operation.url),
              let body = message.body as? [String: Any], body["type"] as? String == "comma.captcha",
              body["challengeId"] as? String == operation.challengeId,
              let token = body["token"] as? String, !token.isEmpty, token.utf8.count <= 4096 else { return }
        finish(token, operationID: operation.id)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let operation = active, webView === operation.browser, operation.outcome == nil,
              let url = action.request.url else { return .cancel }
        if action.targetFrame?.isMainFrame == true { return url == operation.url ? .allow : .cancel }
        // Turnstile owns its child frames and requires these blank documents as well as its HTTPS origin.
        if url.absoluteString == "about:blank" || url.absoluteString == "about:srcdoc" { return .allow }
        return url.scheme == "https" && url.host == "challenges.cloudflare.com" ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        if let operation = active, webView === operation.browser { cancel(operation.id) }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        if let operation = active, webView === operation.browser { cancel(operation.id) }
    }
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        guard let operation = active, presentationController.presentedViewController === operation.controller else { return }
        if operation.outcome == nil { operation.outcome = .cancelled }
        // UIKit has completed an interactive dismissal of this exact owned controller.
        resolve(operation)
    }
}
