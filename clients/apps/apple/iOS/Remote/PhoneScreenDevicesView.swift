import SwiftUI

/// The iOS Simulators and Android devices a computer runs, as its station lists them over the mesh
/// (`devices.listScreens`), each opened full screen on a page of its own (`PhoneDeviceScreenView`), and the simulators
/// shut down that could boot. Read again every 5 s while shown, as the desktop's list is (useScreenListing.ts): a person
/// has few computers, and a read is one request.
struct PhoneScreenDevicesView: View {
    let scope: WorkspaceSettingsScope
    let device: String
    /// The computer's station: how this phone reaches it shows on each device's page.
    var station: String? = nil
    @State private var screens: [ListedDeviceScreen] = []
    @State private var simulators: [(udid: String, title: String)] = []
    @State private var read = false
    @State private var error: String?
    @State private var starting: String?
    /// The device whose live view covers the page.
    @State private var opened: ListedDeviceScreen?

    // A boot is read for until the device is listed, at most this many times, a second apart.
    private static let bootReads = 20

    var body: some View {
        SettingsPage {
            if let error { InlineError(message: error, dismiss: { self.error = nil }) }
            if !read { ProgressView() }
            SettingsSection(Text("Simulators and devices")) {
                if read, screens.isEmpty { Text("No simulator or device is running.").foregroundStyle(CommaTheme.textTertiary) }
                ForEach(screens) { screen in
                    Button { opened = screen } label: {
                        SettingsRow(Text(verbatim: screen.title)) { SettingsChevron() }
                    }.buttonStyle(SurfaceRowButtonStyle())
                }
            }
            if !simulators.isEmpty {
                SettingsSection(Text("Start a simulator")) {
                    ForEach(simulators, id: \.udid) { simulator in
                        Button { start(simulator.udid) } label: {
                            SettingsRow(Text(verbatim: simulator.title)) {
                                if starting == simulator.udid { ProgressView() }
                            }
                        }.buttonStyle(SurfaceRowButtonStyle()).disabled(starting != nil)
                    }
                }
            }
        }
        .pageTitle("Simulators and devices")
        .fullScreenCover(item: $opened) { screen in
            NavigationStack { PhoneDeviceScreenView(scope: scope, device: device, station: station, screen: screen) }
        }
        .task(id: device) { await follow() }
        .disabled(!scope.current)
    }

    private func follow() async {
        // Holds the workspace's stations meanwhile, which keeps the mesh's link to the computer.
        let held = Task { [core = scope.store.core, workspace = scope.workspace.id] in
            for await _ in core.subscribe(["topic": "stations", "workspace": workspace], read: { _ in true }) {}
        }
        defer { held.cancel() }
        while !Task.isCancelled {
            await list()
            try? await Task.sleep(for: .seconds(5))
        }
    }

    /// Reads the list once; the ids it lists.
    @discardableResult
    private func list() async -> Set<String> {
        defer { read = true }
        do {
            let listed = try await scope.call("devices.listScreens", ["device": device])
            let object = listed.object
            screens = object?.objects("screens").compactMap(ListedDeviceScreen.init) ?? []
            simulators = object?.objects("simulators").compactMap { row in
                row.string("udid").map { ($0, row.string("title") ?? row.string("model") ?? $0) }
            } ?? []
            error = object?.string("unavailable")
            return Set(screens.map(\.id))
        } catch is CancellationError {
            return []
        } catch {
            self.error = error.localizedDescription
            return []
        }
    }

    private func start(_ udid: String) {
        starting = udid
        Task {
            defer { starting = nil }
            do {
                let answer = try await scope.call("devices.startScreenDevice", ["device": device, "simulator": udid])
                guard let id = answer.object?.string("id") else { await list(); return }
                for _ in 0 ..< Self.bootReads {
                    if await list().contains(id) { return }
                    try await Task.sleep(for: .seconds(1))
                }
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
