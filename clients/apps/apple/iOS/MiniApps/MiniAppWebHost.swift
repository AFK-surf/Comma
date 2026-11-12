import WebKit
import SwiftUI

/// WebKit's official message API carries the existing Mini App protocol. The bridge exists only in an isolated world.
/// iOS 18.4 adds the delegate that lets this host refuse HTML file pickers.
@available(iOS 18.4, *)
@MainActor
final class MiniAppWebHost: NSObject, WKNavigationDelegate, WKUIDelegate, MiniAppRuntimeHandle {
    static let world = WKContentWorld.world(name: "CommaMiniAppHost")
    let webView: WKWebView
    private weak var session: MiniAppSession?
    private var dark: Bool
    private let bridge = MiniAppScriptBridge()
    private var loading: Task<Void, Never>?
    private var calls: [UUID: Task<Void, Never>] = [:]
    private var stopped = false
    private var mediaSuspended = false
    private var initialNavigation = true

    init(session: MiniAppSession, dark: Bool) throws {
        self.session = session
        self.dark = dark
        guard let url = Bundle.main.url(forResource: "mini-app-host", withExtension: "js") else {
            throw CoreError(code: "unavailable", message: "The app runtime is missing.")
        }
        let source = try String(contentsOf: url, encoding: .utf8)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.allowsInlineMediaPlayback = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentEnd,
                                                                       forMainFrameOnly: true, in: Self.world))
        configuration.userContentController.addScriptMessageHandler(bridge, contentWorld: Self.world, name: "miniApp")
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        bridge.owner = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsLinkPreview = false
        webView.isInspectable = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
    }

    func load() {
        webView.loadHTMLString("<!doctype html><html><head><meta name=viewport content='width=device-width,initial-scale=1,viewport-fit=cover'></head><body></body></html>", baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard loading == nil, !stopped else { return }
        loading = Task { [weak self] in
            guard let self, let session = self.session else { return }
            do {
                _ = try await javascript("globalThis.commaMiniAppHost = commaMiniAppIOS.install(); return null;")
                _ = try await javascript("await commaMiniAppHost.start(init); return null;", ["init": session.initialization(dark: dark, tokens: NativeWebTokens.values(dark: dark))])
                let bundle = try await session.bundle()
                for file in bundle.objects("files") {
                    try Task.checkCancellation()
                    guard let path = file.string("path"), let mime = file.string("mime"),
                          let encoded = file.object("data")?.string("$bytes"), let bytes = Data(base64Encoded: encoded) else {
                        throw CoreError(code: "invalid", message: "The app bundle is invalid.")
                    }
                    _ = try await javascript("commaMiniAppHost.begin(path, mime);", ["path": path, "mime": mime])
                    for offset in stride(from: 0, to: bytes.count, by: 48 * 1024) {
                        try Task.checkCancellation()
                        let chunk = bytes.subdata(in: offset ..< min(offset + 48 * 1024, bytes.count))
                        _ = try await javascript("commaMiniAppHost.append(encoded);", ["encoded": chunk.base64EncodedString()])
                    }
                    _ = try await javascript("commaMiniAppHost.end();")
                }
                _ = try await javascript("await commaMiniAppHost.finish(); return null;")
                if !stopped { session.started() }
            } catch {
                if !stopped, !Task.isCancelled { session.failed(error); stop() }
            }
        }
    }

    func javascript(_ source: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
        guard !stopped else { throw CancellationError() }
        return try await webView.callAsyncJavaScript(source, arguments: arguments, in: nil, contentWorld: Self.world)
    }

    func updateTheme(dark: Bool) async {
        self.dark = dark
        _ = try? await javascript("commaMiniAppHost.theme(theme, tokens);", ["theme": dark ? "dark" : "light", "tokens": NativeWebTokens.values(dark: dark)])
    }


    fileprivate func receive(_ message: WKScriptMessage, reply: @escaping @MainActor (Any?, String?) -> Void) {
        guard !stopped, let session, message.frameInfo.isMainFrame, message.frameInfo.request.url?.absoluteString == "about:blank",
              calls.count < 8, let body = message.body as? NSDictionary, body.string("kind") == "invoke",
              let wire = body.string("wire"), wire.utf8.count <= 2 * 1024 * 1024,
              let bytes = wire.data(using: .utf8), let request = (try? JSONSerialization.jsonObject(with: bytes)) as? NSDictionary else {
            reply(nil, "The app call was refused.")
            return
        }
        let id = UUID()
        calls[id] = Task { [weak self] in
            guard let self else { reply(nil, "The app closed."); return }
            let answer = await session.invoke(request)
            calls.removeValue(forKey: id)
            if stopped || Task.isCancelled { reply(nil, "The app closed.") }
            else { reply(answer, nil) }
        }
    }

    func suspend() {
        webView.endEditing(true)
        guard !stopped, !mediaSuspended else { return }
        mediaSuspended = true
        // WebKit also blocks the retained document from restarting playback while it is suspended.
        webView.setAllMediaPlaybackSuspended(true, completionHandler: nil)
    }

    func resume() {
        guard !stopped, mediaSuspended else { return }
        mediaSuspended = false
        webView.setAllMediaPlaybackSuspended(false, completionHandler: nil)
    }

    func stop() {
        guard !stopped else { return }
        suspend()
        stopped = true
        loading?.cancel()
        loading = nil
        for call in calls.values { call.cancel() }
        calls.removeAll()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "miniApp", contentWorld: Self.world)
        webView.configuration.userContentController.removeAllUserScripts()
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
        session?.stop()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        session?.failed(CoreError(code: "unavailable", message: "The app stopped. Close it and open it again."))
        stop()
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        if stopped {
            return action.targetFrame?.isMainFrame == true && action.request.url?.absoluteString == "about:blank" ? .allow : .cancel
        }
        if initialNavigation, action.targetFrame?.isMainFrame == true, action.request.url?.absoluteString == "about:blank" {
            initialNavigation = false
            return .allow
        }
        // Only the trusted host may create the runtime frame. No navigation leaves the container.
        if action.targetFrame?.isMainFrame == false, action.request.url?.scheme == "blob" { return .allow }
        return .cancel
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard !stopped else { return }
        session?.failed(error)
        stop()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.webView(webView, didFail: navigation, withError: error)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void) { completionHandler(nil) }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) { decisionHandler(.deny) }

    func webView(_ webView: WKWebView, requestDeviceOrientationAndMotionPermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
}

@available(iOS 18.4, *)
@MainActor
private final class MiniAppScriptBridge: NSObject, WKScriptMessageHandlerWithReply {
    weak var owner: MiniAppWebHost?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard let owner else { replyHandler(nil, "The app closed."); return }
        owner.receive(message, reply: replyHandler)
    }
}

@MainActor enum NativeWebTokens {
    static func values(dark: Bool) -> [String: String] {
        let colors: [String: Color] = [
            "background": CommaTheme.bgPrimary, "surface": CommaTheme.bgSecondary, "surface-strong": CommaTheme.bgTertiary,
            "foreground": CommaTheme.textPrimary, "muted": CommaTheme.textSecondary, "subtle": CommaTheme.textTertiary,
            "faint": CommaTheme.textQuaternary, "border": CommaTheme.borderPrimary, "border-subtle": CommaTheme.borderSecondary,
            "primary": CommaTheme.brandSolid, "primary-foreground": .white, "accent": CommaTheme.brandSolid,
            "danger": CommaTheme.errorPrimary, "success": CommaTheme.successPrimary, "warning": CommaTheme.attention,
        ]
        let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
        return Dictionary(uniqueKeysWithValues: colors.map { name, color in
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            UIColor(color).resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            return ("--comma-" + name, "rgba(\(red * 255),\(green * 255),\(blue * 255),\(alpha))")
        })
    }

}
