import SwiftUI
import CommaCore

/// A computer's screen, or one of its devices, viewed over the mesh (`PhoneMeshScreenView`).
struct PhoneScreenView: View {
    let scope: WorkspaceSettingsScope
    let device: String
    /// `display`, or a device the station lists.
    var target = "display"
    var instance: String? = nil
    var title: String? = nil
    /// Starts viewing as it shows (a measured run's entry, `MeasuredScreenEntry`).
    var startsAtOnce = false
    @State private var control = false
    @State private var running = false
    @State private var mesh: PhoneMeshScreenModel?
    @Environment(\.scenePhase) private var scenePhase
    @State private var phase = ""
    @State private var error: String?
    private var isDevice: Bool { target != "display" }
    /// The picture's width over its height, once it came; else a computer's or a phone's usual one.
    private var pictureRatio: CGFloat {
        if let size = mesh?.size, size.width > 0, size.height > 0 { return size.width / size.height }
        return isDevice ? 9.0 / 19.5 : 16.0 / 10.0
    }
    var body: some View {
        SettingsPage {
            SettingsSection(Text(verbatim: title ?? String(localized: "Remote screen"))) {
                if !isDevice {
                    SettingsToggle(title: Text("Allow pointer and keyboard control"), isOn: $control).disabled(running)
                } else if let mesh, mesh.agent {
                    SettingsToggle(title: Text("Allow pointer and keyboard control"), isOn: Binding(get: { mesh.control }, set: { mesh.setControl($0) }))
                }
                Button(running ? "Stop viewing" : "Start viewing") { running.toggle() }.surfaceRowFrame()
                if !phase.isEmpty { SettingsRow(Text("Connection"), value: Text(verbatim: phase)) }
                if running, target.hasPrefix("simulator:"), let mesh {
                    Button("Go to Home Screen") { mesh.home() }.surfaceRowFrame().disabled(!mesh.control)
                }
            }
            if running {
                Group {
                    if let mesh { PhoneMeshScreenView(model: mesh) }
                }
                // The page's whole width, as tall as the picture's shape asks (a computer's wide, a phone's tall), so it
                // is read at the largest size the page has; before the first picture, a computer's usual shape.
                .frame(maxWidth: .infinity)
                .aspectRatio(pictureRatio, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: GroupedSurface.radius))
            }
            if let error { InlineError(message: error, retry: { running = false }) }
        }
        .pageTitle("Remote screen")
        .onChange(of: running) { _, on in on ? begin() : end() }
        .onChange(of: mesh?.phase) { _, next in meshChanged(next) }
        .onDisappear { running = false; end() }
        .onAppear { if startsAtOnce { running = true } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { running = false } }
        .disabled(!scope.current)
        // Holds the workspace's stations while the page is open: the mesh's link to the computer lasts as long.
        .task(id: scope.workspace.id) {
            for await _ in scope.store.core.subscribe(["topic": "stations", "workspace": scope.workspace.id], read: { _ in true }) {}
        }
    }

    private func begin() {
        error = nil; phase = String(localized: "Connecting")
        let model = PhoneMeshScreenModel(core: scope.store.core, workspace: scope.workspace.id, device: device, target: target,
                                         instance: instance, control: isDevice || control)
        mesh = model
        model.start()
    }

    private func end() {
        mesh?.stop(); mesh = nil; phase = ""
    }

    private func meshChanged(_ next: PhoneMeshScreenModel.Phase?) {
        switch next {
        case .live: phase = String(localized: "Connected"); error = nil
        // (the view tries again by itself meanwhile)
        case .unavailable: phase = String(localized: "Failed"); error = String(localized: "This computer cannot be reached now.")
        case .failed(let message): phase = String(localized: "Failed"); error = message
        case .connecting: phase = String(localized: "Connecting")
        case nil: break
        }
    }
}

#if DEBUG
/// A debug build's way straight to one screen for a measured run, with the account already signed in: started with
/// `-CommaOpenScreenDevice <device id>` (and `-CommaOpenScreenTarget <display|simulator:…|android:…>`), the app
/// opens that view at once, as Settings › My devices would. It asks nothing the page would not.
struct MeasuredScreenEntry: ViewModifier {
    let store: CommaStore
    @State private var shown: MeasuredScreen?

    struct MeasuredScreen: Identifiable {
        let id = UUID()
        let workspace: Workspace
        let device: String
        let target: String
        let instance: String?
    }

    func body(content: Content) -> some View {
        content
            .task(id: store.workspace?.id) { await open() }
            .fullScreenCover(item: $shown) { screen in
                NavigationStack {
                    PhoneScreenView(scope: WorkspaceSettingsScope(store: store, workspace: screen.workspace), device: screen.device,
                                    target: screen.target, instance: screen.instance, startsAtOnce: true)
                }
            }
    }

    private func open() async {
        let defaults = UserDefaults.standard
        guard shown == nil, let workspace = store.workspace,
              let device = defaults.string(forKey: "CommaOpenScreenDevice") else { return }
        let target = defaults.string(forKey: "CommaOpenScreenTarget") ?? "display"
        var instance: String?
        if target != "display" {
            let listed = try? await store.core.call("devices.listScreens", ["workspace": workspace.id, "device": device])
            instance = listed?.object?.objects("screens").first { $0.string("id") == target }?.string("instance")
        }
        shown = MeasuredScreen(workspace: workspace, device: device, target: target, instance: instance)
    }
}
#endif
