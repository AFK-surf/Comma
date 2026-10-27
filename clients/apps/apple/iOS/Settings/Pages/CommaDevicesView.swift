import SwiftUI
import CommaCore

func deviceText(_ key: String, _ name: String = "") -> String {
    let text = Bundle.main.localizedString(forKey: key, value: key, table: nil)
    return text.contains("%@") ? String(format: text, name) : text
}

struct CommaDeviceRow: Identifiable, Sendable {
    let id: String
    let name: String
    let online: Bool
    let comma: Bool
    let allowsOperations: Bool
    init?(_ row: NSDictionary) {
        guard let id = row.string("device_id") else { return nil }
        self.id = id; name = row.string("name") ?? id
        online = row.string("status") == "connected"; comma = row.bool("isCommaDevice")
        allowsOperations = row.bool("allows_operations")
    }
}

struct CommaDevicesView: View {
    let store: CommaStore
    @State private var devices: [CommaDeviceRow] = []
    @State private var loading = true
    @State private var failed = false
    @State private var more = false
    @State private var adding = false
    @State private var removing: CommaDeviceRow?
    @State private var action = PageAction()
    @State private var notice: String?

    var body: some View {
        SettingsPage {
            if let error = action.error { InlineError(message: error, dismiss: { action.error = nil }) }
            if let notice { Text(notice).foregroundStyle(CommaTheme.textTertiary) }
            SettingsSection {
                Button { adding = true } label: { SettingsRow(Text(deviceText("devices_add")), icon: "central-circle-dashed") { SettingsChevron() } }
                    .buttonStyle(SurfaceRowButtonStyle()).disabled(store.workspace == nil)
            }
            if loading { ProgressView() }
            if failed { InlineError(message: deviceText("devices_failed"), retry: { refresh() }) }
            SettingsSection(Text(deviceText("devices_section"))) {
                ForEach(devices) { device in
                    VStack(alignment: .leading) {
                        SettingsRow(Text(device.name), icon: device.comma ? "central-circle-dashed" : "icon-devices",
                                    value: Text(deviceText(device.online ? "devices_online" : "devices_offline")))
                        if device.comma {
                            SettingsToggle(title: Text(deviceText("devices_access")), isOn: Binding(get: { device.allowsOperations }, set: { changeAccess(device, $0) }))
                                .disabled(action.busy || !device.online)
                        }
                        Button(role: .destructive) { removing = device } label: {
                            SettingsRow(Text(deviceText("devices_remove")), icon: "central-trash-can", role: .destructive)
                        }.buttonStyle(SurfaceRowButtonStyle()).disabled(action.busy)
                            .confirmationDialog(Text(deviceText("devices_remove_title", device.name)), isPresented: Binding(
                                get: { removing?.id == device.id },
                                set: { if !$0, removing?.id == device.id { removing = nil } }
                            ), titleVisibility: .visible) {
                                Button(deviceText("devices_remove"), role: .destructive) { remove(device) }
                            } message: { Text(deviceText("devices_remove_message", device.name)) }
                    }
                }
                if more { Button("Load more") { Task { _ = try? await store.core.call("devices.more") } }.surfaceRowFrame() }
            }
        }
        .pageTitle("My devices")
        .task(id: store.workspace?.id) { await follow() }
        .refreshable { _ = try? await store.core.call("devices.refresh") }
        .sheet(isPresented: $adding) {
            if let workspace = store.workspace?.id {
                NavigationStack { AddCommaDeviceView(core: store.core, workspace: workspace) }.commaSheet([.large])
            }
        }
    }
    private func follow() async {
        guard let workspace = store.workspace?.id else { loading = false; return }
        devices = []; loading = true
        for await value in store.core.subscribe(["topic": "devices", "prefer": workspace], read: { CoreJSON(value: $0) }) {
            guard case .value(let next) = value, let json = next.value as? NSDictionary else { loading = false; failed = true; continue }
            devices = json.objects("devices").compactMap(CommaDeviceRow.init)
            loading = json.bool("loading"); failed = json.bool("failed"); more = json.bool("hasMore")
        }
    }
    private func refresh() { Task { _ = try? await store.core.call("devices.refresh") } }
    private func changeAccess(_ device: CommaDeviceRow, _ enabled: Bool) {
        guard let workspace = store.workspace?.id else { return }
        action.run({ _ = try await store.core.call("devices.setAccess", ["workspace": workspace, "device": device.id, "access": enabled ? "full" : "read"]) }) {}
    }
    private func remove(_ device: CommaDeviceRow) {
        guard let workspace = store.workspace?.id else { return }
        action.run({
            _ = try await store.core.call(device.comma ? "deviceSetup.remove" : "devices.remove", ["workspace": workspace, "device": device.id])
            notice = device.comma ? deviceText("devices_removed") : nil
            _ = try await store.core.call("devices.refresh")
        }) {}
        removing = nil
    }
}

@MainActor @Observable
final class AppleDeviceSetupModel {
    let core: any CoreAPI
    let workspace: String
    var state: NSDictionary = [:]
    var bluetooth = "pending"
    var error: String?
    init(core: any CoreAPI, workspace: String) { self.core = core; self.workspace = workspace }
    var step: String { state.string("step") ?? "idle" }
    var name: String { state.string("name") ?? (state["device"] as? NSDictionary)?.string("name") ?? "" }
    func follow() async {
        do { _ = try await core.call("deviceSetup.start", ["workspace": workspace]) }
        catch { self.error = deviceText("devices_problem_network"); return }
        for await value in core.subscribe(["topic": "deviceSetup"], read: { CoreJSON(value: $0) }) {
            guard case .value(let next) = value, let json = next.value as? NSDictionary else { continue }
            state = json["state"] as? NSDictionary ?? [:]; bluetooth = json.string("bluetooth") ?? "pending"
        }
    }
    func send(_ type: String, _ fields: [String: Any] = [:]) {
        var params = fields; params["type"] = type
        Task { do { _ = try await core.call("deviceSetup.event", params) } catch { self.error = deviceText("devices_problem_network") } }
    }
    func cancel() { send("cancel"); Task { _ = try? await core.call("devices.refresh") } }
}

/// Adds a Comma device in the steps Android shows: find it, pair, choose Wi-Fi, set it up, done. The sheet keeps
/// one title; each step leads with its own heading, puts its rows on the grouped surface, and ends with the step's
/// one action. Closing the sheet cancels the setup.
struct AddCommaDeviceView: View {
    @State private var model: AppleDeviceSetupModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    /// The secured network whose password is being asked for, and the network last sent to the device.
    @State private var asking: String?
    @State private var password = ""
    @State private var joined = ""
    @State private var renaming = false
    @State private var draftName = ""
    init(core: any CoreAPI, workspace: String) { _model = State(initialValue: AppleDeviceSetupModel(core: core, workspace: workspace)) }

    var body: some View {
        SettingsPage(background: CommaTheme.cardPrimary) {
            if let error = model.error { InlineError(message: error, dismiss: { model.error = nil }) }
            if waitingForBluetooth { bluetooth } else {
                switch model.step {
                case "pairing": pairing
                case "wifi": wifi
                case "setup": setup
                case "done": done
                case "failed":
                    header(deviceText("devices_add_failed_title"), deviceText(Self.problems[model.state.string("problem") ?? ""] ?? "devices_problem_server"))
                    Button(deviceText("devices_add_try_again")) { model.send("retry") }.buttonStyle(CommaButtonStyle())
                default: scanning
                }
            }
        }
        .pageTitle("devices_add")
        .sheetCloseButton { model.cancel(); dismiss() }
        // A swipe must not cancel a device halfway through receiving its credentials.
        .interactiveDismissDisabled(model.step == "setup")
        .alert(asking ?? "", isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } })) {
            SecureField(deviceText("devices_add_wifi_password_description"), text: $password).textContentType(.password)
            Button(deviceText("devices_add_wifi_join")) { if let ssid = asking { join(ssid, password) } }
                .disabled(!(8...64).contains(password.count))
            Button("Cancel", role: .cancel) { password = "" }
        }
        .alert(deviceText("devices_add_name"), isPresented: $renaming) {
            TextField(deviceText("devices_add_name"), text: $draftName).textInputAutocapitalization(.words)
            Button("Save") { model.send("rename", ["name": draftName]) }
                .disabled(draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: { Text(deviceText("devices_add_name_description")) }
        .task { await model.follow() }
        .onDisappear { password = ""; model.cancel() }
    }

    /// Bluetooth that is off or not allowed stops the search before it finds anything.
    private var waitingForBluetooth: Bool {
        ["idle", "scanning"].contains(model.step) && ["off", "denied"].contains(model.bluetooth)
    }

    private func header(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title3.weight(.semibold)).foregroundStyle(CommaTheme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(body).font(.subheadline).foregroundStyle(CommaTheme.textTertiary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 4)
    }

    @ViewBuilder private var bluetooth: some View {
        if model.bluetooth == "off" {
            header(deviceText("devices_add_bluetooth_title"), deviceText("devices_add_bluetooth_off"))
        } else {
            header(deviceText("devices_add_permission_title"), deviceText("devices_add_bluetooth_permission"))
            Button(deviceText("devices_add_allow_bluetooth")) {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }.buttonStyle(CommaButtonStyle())
        }
    }

    @ViewBuilder private var scanning: some View {
        let devices = model.state.objects("devices")
        let searching = Text(deviceText(model.state.bool("quiet") ? "devices_add_scan_quiet" : "devices_add_scanning"))
        header(deviceText("devices_add_scan_title"), deviceText("devices_add_scan_body"))
        if devices.isEmpty {
            SettingsSection {
                SettingsNote { ProgressView().controlSize(.small) } message: { searching }
                    .foregroundStyle(CommaTheme.textTertiary)
            }
        } else {
            SettingsSection(Text(deviceText("devices_add_found")), footer: searching) {
                ForEach(devices, id: \.self) { device in
                    Button { model.send("pick", ["id": device.string("id") ?? ""]) } label: {
                        SettingsRow(Text(device.string("name") ?? ""), icon: "central-circle-dashed") { SettingsChevron() }
                    }.buttonStyle(SurfaceRowButtonStyle())
                }
            }
        }
    }

    @ViewBuilder private var pairing: some View {
        let connected = model.state.bool("connected")
        header(deviceText(connected ? "devices_add_code_title" : "devices_add_connecting_title", model.name),
               deviceText(connected ? "devices_add_code_body" : "devices_add_connecting_body", model.name))
        SettingsSection { SettingsRow(Text(model.name), icon: "central-circle-dashed") { ProgressView() } }
    }

    @ViewBuilder private var wifi: some View {
        let scanning = model.state.bool("scanning")
        header(deviceText("devices_add_wifi_title"), deviceText("devices_add_wifi_body", model.name))
        if let failure = model.state.string("failure") {
            InlineError(message: deviceText(Self.wifiFailures[failure] ?? "devices_add_wifi_failed", joined))
        }
        SettingsSection {
            Button { draftName = model.name; renaming = true } label: {
                SettingsRow(Text(deviceText("devices_add_name")), icon: "central-edit-big", value: Text(model.name)) { SettingsChevron() }
            }.buttonStyle(SurfaceRowButtonStyle())
        }
        SettingsSection(Text(deviceText("devices_add_wifi_networks")), footer: Text(deviceText("devices_add_wifi_band"))) {
            ForEach(model.state.objects("networks"), id: \.self) { network in networkRow(network) }
            Button { model.send("rescan") } label: {
                SettingsRow(Text(deviceText(scanning ? "devices_add_wifi_scanning" : "devices_add_wifi_rescan")),
                            icon: "central-arrow-rotate-clockwise", role: .action) { if scanning { ProgressView() } }
            }.buttonStyle(SurfaceRowButtonStyle()).disabled(scanning)
        }
    }

    private func networkRow(_ network: NSDictionary) -> some View {
        let ssid = network.string("ssid") ?? ""
        let secure = network.bool("secure")
        let rssi = network.int("rssi") ?? -100
        let signal = deviceText(rssi >= -60 ? "devices_add_wifi_strong" : rssi >= -72 ? "devices_add_wifi_good" : "devices_add_wifi_weak")
        let security = deviceText(secure ? "devices_add_wifi_secured" : "devices_add_wifi_open")
        return Button { if secure { password = ""; asking = ssid } else { join(ssid, "") } } label: {
            SettingsRow(Text(ssid), value: Text(verbatim: "\(security) · \(signal)"))
        }.buttonStyle(SurfaceRowButtonStyle())
    }

    @ViewBuilder private var setup: some View {
        let ssid = model.state.string("ssid") ?? ""
        let current = Self.phases.firstIndex { $0.phase == model.state.string("phase") } ?? 0
        header(deviceText("devices_add_setup_title", model.name), deviceText("devices_add_setup_body"))
        SettingsSection {
            ForEach(Array(Self.phases.enumerated()), id: \.offset) { index, phase in
                SetupPhaseRow(title: deviceText(phase.label, ssid),
                              progress: index < current ? .done : index == current ? .working : .waiting)
            }
        }
    }

    @ViewBuilder private var done: some View {
        let online = model.state.bool("online")
        header(deviceText(online ? "devices_add_done_title" : "devices_add_almost_title"),
               deviceText(online ? "devices_add_done_body" : "devices_add_almost_body", model.name))
        SettingsSection {
            SettingsRow(Text(model.name), icon: "central-circle-dashed", value: Text(deviceText(online ? "devices_online" : "devices_offline")))
        }
        Button(deviceText("devices_add_finish")) { dismiss() }.buttonStyle(CommaButtonStyle())
    }

    private func join(_ ssid: String, _ password: String) {
        joined = ssid
        model.send("join", ["ssid": ssid, "password": password])
        self.password = ""
    }

    private static let phases = [("joining", "devices_add_setup_wifi"), ("minting", "devices_add_setup_credentials"),
                                 ("saving", "devices_add_setup_save"), ("online", "devices_add_setup_online")]
        .map { (phase: $0.0, label: $0.1) }
    private static let wifiFailures = ["wrong_password": "devices_add_wifi_wrong_password", "not_found": "devices_add_wifi_not_found",
                                       "timeout": "devices_add_wifi_timeout", "scan_failed": "devices_add_wifi_scan_failed"]
    private static let problems = [
        "bluetooth": "devices_problem_bluetooth", "connect_failed": "devices_problem_connect", "pairing_failed": "devices_problem_pairing",
        "disconnected": "devices_problem_disconnected", "timeout": "devices_problem_timeout",
        "rejected": "devices_problem_rejected", "save_failed": "devices_problem_save",
        "not_online": "devices_problem_not_online", "storage": "devices_problem_storage",
        "connector_rejected": "devices_problem_connector_rejected", "network": "devices_problem_network",
        "forbidden": "devices_problem_forbidden", "limit": "devices_problem_limit",
    ]
}

/// One step of setting the device up: done, under way (the task list's turning glyph) or still to come.
private struct SetupPhaseRow: View {
    enum Progress { case done, working, waiting }
    let title: String
    let progress: Progress
    @ScaledMetric(relativeTo: .body) private var slot: CGFloat = 20

    var body: some View {
        HStack(spacing: 8) {
            Group {
                switch progress {
                case .done: CentralIcon("icon-check", size: 20, relativeTo: .body).foregroundStyle(CommaTheme.textSecondary)
                case .working: TaskStatusIcon(bucket: .inProgress, size: slot)
                case .waiting:
                    Image(decorative: TaskBucket.inProgress.iconName).renderingMode(.template).resizable()
                        .foregroundStyle(CommaTheme.textPlaceholder)
                }
            }
            .frame(width: slot, height: slot)
            Text(title).font(.body).foregroundStyle(progress == .waiting ? CommaTheme.textPlaceholder : CommaTheme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(deviceText(progress == .done ? "devices_add_setup_done" : progress == .working ? "devices_add_setup_working" : "devices_add_setup_waiting"))
                .font(.body).foregroundStyle(CommaTheme.textTertiary).lineLimit(1)
        }
        .surfaceRowFrame()
        .accessibilityElement(children: .combine)
    }
}
