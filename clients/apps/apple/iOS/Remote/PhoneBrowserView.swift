import SwiftUI
import Observation
import CommaCore

@MainActor @Observable final class PhoneBrowserModel {
    let scope: WorkspaceSettingsScope
    let conversation: String
    private(set) var participant: String
    let viewer = UUID().uuidString
    private(set) var binding = CoreJSON(value: nil)
    private(set) var value = CoreJSON(value: nil)
    private(set) var loaded = false
    private(set) var image: UIImage?
    private var seq = -1
    var text = ""
    private var inputBusy = false
    init(store: CommaStore, workspace: Workspace, conversation: String, participant: String) {
        scope = WorkspaceSettingsScope(store: store, workspace: workspace); self.conversation = conversation; self.participant = participant
    }
    var browserID: String { (binding.object?.string("agent_id") ?? "") + "/" + (binding.object?.string("session_id") ?? "") }
    var ref: [String: Any]? {
        guard let agent = binding.object?.string("agent_id"), let session = binding.object?.string("session_id") else { return nil }
        return ["workspace": scope.workspace.id, "agent": agent, "session": session, "viewer": viewer]
    }
    var source: [String: Any] { ["workspace": scope.workspace.id, "conversation": conversation, "participant": participant] }
    func setParticipant(_ next: String) {
        guard participant != next else { return }
        participant = next
        binding = CoreJSON(value: nil); value = CoreJSON(value: nil)
        image = nil; seq = -1; loaded = false; scope.error = nil
    }
    func follow() async {
        guard !participant.isEmpty else { loaded = true; return }
        let participant = participant
        var query = source; query["topic"] = "sessionBrowser"
        for await update in scope.store.core.subscribe(query, read: { CoreJSON(value: $0) }) {
            guard scope.current, !Task.isCancelled, self.participant == participant else { return }
            switch update {
            case .value(let next):
                loaded = next.object != nil; binding = CoreJSON(value: next.object?.object("browser"))
            case .failed(let error): loaded = true; scope.error = error.localizedDescription
            }
        }
    }
    func watchFrames() async {
        value = CoreJSON(value: nil); image = nil; seq = -1
        guard var query = ref else { return }; query["topic"] = "browserView"
        let browserID = browserID
        for await update in scope.store.core.subscribe(query, read: { CoreJSON(value: $0) }) {
            guard scope.current, !Task.isCancelled, self.browserID == browserID else { return }
            switch update {
            case .value(let next):
                value = next
                if next.object?.object("frame") == nil { image = nil; seq = -1 }
                if let frame = next.object?.object("frame"), let seq = frame.int("seq"), self.seq != seq {
                    self.seq = seq
                    if let text = frame.string("data"), text.utf8.count <= 12 * 1024 * 1024, let bytes = Data(base64Encoded: text) { image = UIImage(data: bytes) }
                }
            case .failed(let error): scope.error = error.localizedDescription
            }
        }
    }
    func command(_ operation: String) async { guard var params = ref else { return }; params["operation"] = operation; _ = await scope.perform("browserView.command", params, workspaceParameter: false) }
    func select(_ tab: String) async { guard var params = ref else { return }; params["tab"] = tab; _ = await scope.perform("browserView.selectTab", params, workspaceParameter: false) }
    func reconnect() async { guard let ref else { return }; _ = await scope.perform("browserView.reconnect", ref, workspaceParameter: false) }
    func input(_ events: [[String: Any]]) async {
        guard value.object?.bool("controlling") == true, !inputBusy, let ref else { return }
        inputBusy = true; defer { inputBusy = false }
        do { for event in events.prefix(2) { var params = ref; params["input"] = event; _ = try await scope.call("browserView.input", params, workspaceParameter: false) } }
        catch is CancellationError { }
        catch { if scope.current { scope.error = error.localizedDescription } }
    }
    func tap(x: Double, y: Double) async {
        guard let frame = value.object?.object("frame"), let width = frame.double("width"), let height = frame.double("height") else { return }
        let point: [String: Any] = ["x": max(0, min(1, x)) * width, "y": max(0, min(1, y)) * height, "button": "left", "clickCount": 1, "modifiers": 0]
        await input([point.merging(["type": "mousePressed"], uniquingKeysWith: { _, next in next }), point.merging(["type": "mouseReleased"], uniquingKeysWith: { _, next in next })])
    }
    func key(_ name: String, code: String, keyCode: Int) async {
        let event: [String: Any] = ["key": name, "code": code, "keyCode": keyCode, "modifiers": 0]
        await input([event.merging(["type": "keyDown"], uniquingKeysWith: { _, next in next }), event.merging(["type": "keyUp"], uniquingKeysWith: { _, next in next })])
    }
}

struct PhoneBrowserView: View {
    @State var model: PhoneBrowserModel
    @State private var clearing = false
    var body: some View {
        SettingsPage {
            if !model.loaded { ProgressView().frame(maxWidth: .infinity) }
            else if model.ref == nil { SettingsSection { SettingsNote(icon: "icon-info") { Text("This conversation has no running browser.") } } }
            else {
                SettingsSection {
                    Picker("Tab", selection: Binding(get: { model.value.object?.string("tab") ?? "" }, set: { tab in Task { await model.select(tab) } })) {
                        ForEach(model.value.object?.objects("tabs") ?? [], id: \.self) { tab in Text(verbatim: tab.string("title") ?? tab.string("url") ?? "").tag(tab.string("tab_id") ?? "") }
                    }.surfaceRowFrame()
                    SettingsRow(Text("Control"), value: Text(model.value.object?.bool("controlling") == true ? "You" : "Agent"))
                    Button(model.value.object?.bool("controlling") == true ? "Return control" : "Take control") {
                        Task { await model.command(model.value.object?.bool("controlling") == true ? "return_control" : "take_control") }
                    }.surfaceRowFrame()
                }
                if let image = model.image {
                    Image(uiImage: image).resizable().scaledToFit().overlay {
                        GeometryReader { geometry in
                            Color.clear.contentShape(Rectangle()).onTapGesture { point in
                                Task { await model.tap(x: point.x / geometry.size.width, y: point.y / geometry.size.height) }
                            }
                        }
                    }.clipShape(RoundedRectangle(cornerRadius: GroupedSurface.radius))
                        .accessibilityLabel("Remote browser viewport")
                } else { ProgressView().frame(maxWidth: .infinity).padding() }
                if model.value.object?.bool("controlling") == true {
                    SettingsSection(Text("Keyboard")) {
                        TextField("Text to type", text: $model.text).surfaceRowFrame()
                        Button("Type text") { Task { await model.input([["type": "text", "text": model.text]]); model.text = "" } }.surfaceRowFrame().disabled(model.text.isEmpty)
                        HStack {
                            Button("Tab") { Task { await model.key("Tab", code: "Tab", keyCode: 9) } }
                            Spacer(); Button("Enter") { Task { await model.key("Enter", code: "Enter", keyCode: 13) } }
                            Spacer(); Button("Escape") { Task { await model.key("Escape", code: "Escape", keyCode: 27) } }
                        }.surfaceRowFrame()
                        HStack {
                            Button("Page up") { Task { await model.key("PageUp", code: "PageUp", keyCode: 33) } }
                            Spacer(); Button("Page down") { Task { await model.key("PageDown", code: "PageDown", keyCode: 34) } }
                        }.surfaceRowFrame()
                    }
                }
                SettingsSection {
                    Button("Reconnect") { Task { await model.reconnect() } }.surfaceRowFrame()
                    Button("Clear browser storage", role: .destructive) { clearing = true }.surfaceRowFrame()
                }
                if model.value.object?.string("error") != nil { InlineError(message: String(localized: "The browser connection failed."), retry: { Task { await model.reconnect() } }) }
            }
            if let error = model.scope.error { InlineError(message: error, retry: { Task { await model.reconnect() } }) }
        }.pageTitle("Remote browser").task(id: model.participant) { await model.follow() }.task(id: model.browserID) { await model.watchFrames() }
            .disabled(model.scope.busy || !model.scope.current)
            .confirmationDialog("Clear browser storage?", isPresented: $clearing, titleVisibility: .visible) {
                Button("Clear storage", role: .destructive) { Task { await model.command("clear_storage") } }
            } message: { Text("Saved website sessions in this browser will be removed.") }
    }
}
