import SwiftUI
import WebKit
import Observation
import CommaCore

@MainActor @Observable final class PhoneDynamicUIModel {
    let scope: WorkspaceSettingsScope
    let ui: PhoneDynamicUI
    let feed: WorkspaceTopic
    private(set) var saved = CoreJSON(value: nil)
    var proposal: String?
    var link: URL?
    var failure: String?
    private(set) var runtimeReady = false
    private var pending: [String: String] = [:]
    private var saving = false
    init(store: CommaStore, workspace: Workspace, ui: PhoneDynamicUI) {
        scope = WorkspaceSettingsScope(store: store, workspace: workspace); self.ui = ui
        feed = WorkspaceTopic(store: store, workspace: workspace, topic: "dynamicUi", parameters: ["group": workspace.groupID, "conversation": ui.conversation, "message": ui.message, "index": String(ui.index)])
    }
    var stateKey: String {
        let parts = ["comma-ui:1", scope.store.configuration.baseURL.absoluteString, scope.store.session?.user.id ?? "", scope.workspace.id, ui.id]
        let data = try? JSONSerialization.data(withJSONObject: parts, options: [.withoutEscapingSlashes])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
    func loadState() async {
        guard scope.current else { return }
        let key = stateKey
        let value = await scope.store.core.first(["topic": "dynamicUiState", "key": key], read: { CoreJSON(value: $0) })
        if scope.current, !Task.isCancelled { saved = value ?? CoreJSON(value: nil) }
    }
    func receive(_ json: NSDictionary) {
        guard scope.current else { return }
        switch json.string("type") {
        case "ready": runtimeReady = true
        case "request": if let text = json.string("value"), text.count <= 4000 { proposal = text }
        case "open-link":
            if let text = json.string("url"), text.count <= 4000, let url = URL(string: text), url.scheme == "https", url.user == nil, url.password == nil { link = url }
        case "error": failure = String((json.string("reason") ?? String(localized: "Interactive content failed")).prefix(200))
        case "save", "card-state":
            guard let value = json["value"], JSONSerialization.isValidJSONObject([value]), let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), data.count <= 32768,
                  let text = String(data: data, encoding: .utf8) else { return }
            let kind = json.string("type") == "save" ? "state" : "cards"
            pending[kind] = text
            if !saving { Task { await flush() } }
        default: break
        }
    }
    private func flush() async {
        guard !saving else { return }; saving = true; defer { saving = false }
        while scope.current, let (kind, text) = pending.first {
            pending[kind] = nil
            do { _ = try await scope.call("dynamicUiState.save", ["key": stateKey, "kind": kind, "text": text], workspaceParameter: false) }
            catch is CancellationError { return }
            catch { failure = error.localizedDescription; return }
        }
    }
    func addProposal(to pane: ConversationPane) { guard scope.current, !pane.closed, let proposal else { return }; pane.fillDraft(proposal); self.proposal = nil }
}

struct PhoneDynamicUIView: View {
    @State var model: PhoneDynamicUIModel
    let pane: ConversationPane
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme
    @State private var stateLoaded = false
    var body: some View {
        VStack(spacing: GroupedSurface.groupSpacing) {
            if let payload = model.feed.value.object?["ui"], model.feed.value.object?.string("status") == "ready", stateLoaded {
                PhoneDynamicUIHost(model: model, payload: CoreJSON(value: payload), dark: colorScheme == .dark)
            } else if model.feed.value.object?.string("status") == "failed" {
                InlineError(message: model.feed.value.object?.string("reason") ?? String(localized: "Couldn’t load interactive content"), dismiss: { dismiss() })
            } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            if let proposal = model.proposal {
                VStack(alignment: .leading, spacing: GroupedSurface.groupSpacing) {
                    Text(verbatim: proposal).lineLimit(6)
                    Button("Add to draft") { model.addProposal(to: pane); dismiss() }
                    Button("Cancel", role: .cancel) { model.proposal = nil }
                }.padding(GroupedSurface.margin).background(CommaTheme.bgSecondary, in: RoundedRectangle(cornerRadius: GroupedSurface.radius))
            }
            if let failure = model.failure { InlineError(message: failure, dismiss: { dismiss() }) }
        }.padding(.horizontal, GroupedSurface.margin).background(CommaTheme.cardPrimary)
            .pageTitle("Interactive content").sheetCloseButton { dismiss() }
            .task { await model.feed.follow() }
            .task { await model.loadState(); stateLoaded = true }
            .confirmationDialog("Open this link?", isPresented: Binding(get: { model.link != nil }, set: { if !$0 { model.link = nil } }), titleVisibility: .visible) {
                if let link = model.link { Button("Open link") { openURL(link); model.link = nil } }
            } message: { Text(verbatim: model.link?.absoluteString ?? "") }
            .disabled(!model.scope.current)
    }
}

private struct PhoneDynamicUIHost: UIViewRepresentable {
    let model: PhoneDynamicUIModel
    let payload: CoreJSON
    let dark: Bool
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.userContentController.add(context.coordinator, contentWorld: Coordinator.world, name: "dynamicUI")
        if let url = Bundle.main.url(forResource: "dynamic-ui-host", withExtension: "js"), let source = try? String(contentsOf: url, encoding: .utf8) {
            configuration.userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Coordinator.world))
        } else { model.failure = String(localized: "The interactive runtime is missing.") }
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false; view.backgroundColor = .clear; view.navigationDelegate = context.coordinator
        context.coordinator.webView = view
        view.loadHTMLString("<!doctype html><html><head><meta name='viewport' content='width=device-width, initial-scale=1'><meta http-equiv='Content-Security-Policy' content=\"default-src 'none'; script-src 'unsafe-inline' https:; worker-src blob:; style-src 'unsafe-inline' https:; img-src https:; font-src https:; frame-src blob:; connect-src 'none'; form-action 'none'; base-uri 'none'\"></head><body></body></html>", baseURL: nil)
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) { }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) { coordinator.stop(); view.configuration.userContentController.removeScriptMessageHandler(forName: "dynamicUI", contentWorld: Coordinator.world) }
    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        static let world = WKContentWorld.world(name: "CommaDynamicUIHost")
        let owner: PhoneDynamicUIHost
        weak var webView: WKWebView?
        var closed = false
        var started = false
        var initialNavigation = true
        init(_ owner: PhoneDynamicUIHost) { self.owner = owner }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !started, !closed else { return }; started = true
            Task {
                do {
                    let saved = owner.model.saved.object
                    func decode(_ key: String) -> Any { saved?.text(key).flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) } ?? NSNull() }
                    var theme: [String: String] = ["scheme": owner.dark ? "dark" : "light"]
                    for (key, value) in NativeWebTokens.values(dark: owner.dark) { theme[String(key.dropFirst("--comma-".count))] = value }
                    theme["space"] = "\(GroupedSurface.margin)px"; theme["radius"] = "\(GroupedSurface.radius)px"
                    let copy = ["recommended": String(localized: "Recommended"), "alternatives": String(localized: "Other options"), "high": String(localized: "High"), "low": String(localized: "Low"), "feelsLike": String(localized: "Feels like"), "humidity": String(localized: "Humidity"), "ongoing": String(localized: "Now"), "directions": String(localized: "Directions"), "range": String(localized: "Range"), "days": String(localized: "days"), "attribute": String(localized: "Attribute"), "option": String(localized: "Option"), "versus": "VS", "checklistProgress": String(localized: "{done} of {total} done"), "focus": String(localized: "Focus"), "rest": String(localized: "Break"), "paused": String(localized: "Paused"), "timeUp": String(localized: "Time’s up"), "timerCycle": String(localized: "Session {current} of {total}"), "arrivesBy": String(localized: "Arrives by {time}"), "orderHeadline": String(localized: "{status}, {arrival}"), "offline": String(localized: "Offline"), "upNext": String(localized: "Up next"), "partFailed": String(localized: "This part couldn’t be shown")]
                    let initValue: [String: Any] = ["payload": owner.payload.value ?? NSNull(), "state": decode("state"), "cardState": decode("cards"), "seed": owner.model.ui.id,
                                                   "theme": theme, "tokens": [:], "icons": [:], "copy": copy, "locale": Locale.preferredLanguages.first ?? "en", "timeZone": TimeZone.current.identifier]
                    _ = try await webView.callAsyncJavaScript("globalThis.host = commaDynamicUIIOS.install(); await host.start(init); return null;", arguments: ["init": initValue], in: nil, contentWorld: Self.world)
                } catch { if !closed { owner.model.failure = error.localizedDescription } }
            }
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard !closed, message.frameInfo.isMainFrame, let wire = message.body as? String, wire.utf8.count <= 40_000, let data = wire.data(using: .utf8), let json = (try? JSONSerialization.jsonObject(with: data)) as? NSDictionary else { return }
            owner.model.receive(json)
        }
        func stop() { closed = true; webView?.callAsyncJavaScript("globalThis.host?.stop(); return null;", arguments: [:], in: nil, in: Self.world, completionHandler: nil); webView?.stopLoading() }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            if initialNavigation, action.targetFrame?.isMainFrame == true, action.request.url?.absoluteString == "about:blank" {
                initialNavigation = false; return .allow
            }
            if !closed, action.targetFrame?.isMainFrame == false, action.request.url?.scheme == "blob" { return .allow }
            return .cancel
        }
    }
}
