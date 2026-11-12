import SwiftUI

/// The iOS Simulators and Android devices a computer runs, as its station lists them over the mesh
/// (`devices.listScreens`), each opened on its own page. Read again every 5 s while shown, as the desktop's list is
/// (useScreenListing.ts): a person has few computers, and a read is one request.
struct PhoneScreenDevicesView: View {
    let scope: WorkspaceSettingsScope
    let device: String
    @State private var screens: [NSDictionary] = []
    @State private var read = false
    @State private var error: String?

    var body: some View {
        SettingsPage {
            if let error { InlineError(message: error, dismiss: { self.error = nil }) }
            if !read { ProgressView() }
            SettingsSection(Text("Simulators and devices")) {
                if read, screens.isEmpty { Text("No simulator or device is running.").foregroundStyle(CommaTheme.textTertiary) }
                ForEach(screens.compactMap(Listed.init)) { screen in
                    NavigationLink {
                        PhoneScreenView(scope: scope, device: device, target: screen.id, instance: screen.instance, title: screen.title)
                    } label: { SettingsRow(Text(verbatim: screen.title)) { SettingsChevron() } }.buttonStyle(SurfaceRowButtonStyle())
                }
            }
        }
        .pageTitle("Simulators and devices")
        .task(id: device) { await follow() }
    }

    private struct Listed: Identifiable {
        let id: String
        let instance: String
        let title: String
        init?(_ row: NSDictionary) {
            guard let id = row.string("id"), let instance = row.string("instance") else { return nil }
            self.id = id; self.instance = instance; title = row.string("title") ?? row.string("name") ?? id
        }
    }

    private func follow() async {
        // Holds the workspace's stations meanwhile, which keeps the mesh's link to the computer.
        let held = Task { [core = scope.store.core, workspace = scope.workspace.id] in
            for await _ in core.subscribe(["topic": "stations", "workspace": workspace], read: { _ in true }) {}
        }
        defer { held.cancel() }
        while !Task.isCancelled {
            do {
                let listed = try await scope.call("devices.listScreens", ["device": device])
                screens = listed.object?.objects("screens") ?? []
                error = listed.object?.string("unavailable")
            } catch is CancellationError {
                return
            } catch {
                self.error = error.localizedDescription
            }
            read = true
            try? await Task.sleep(for: .seconds(5))
        }
    }
}
