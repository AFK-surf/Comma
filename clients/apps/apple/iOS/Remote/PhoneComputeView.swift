import SwiftUI
import CommaCore

struct PhoneComputeView: View {
    @State var feed: WorkspaceTopic
    @State private var name = ""
    @State private var environment = ""
    @State private var deleting: CoreJSON?
    @State private var renameID: String?
    @State private var rename = ""
    var body: some View {
        SettingsPage {
            if !feed.loaded { ProgressView().frame(maxWidth: .infinity) }
            if let projection = feed.value.object?.object("projection") {
                if projection.bool("can_manage") {
                    SettingsSection(Text("New shell")) {
                        Picker("Environment", selection: $environment) {
                            Text("Choose environment").tag("")
                            ForEach(projection.objects("environments").filter { $0.bool("can_create") }, id: \.self) { item in Text(verbatim: item.string("id") ?? "").tag(item.string("id") ?? "") }
                        }.surfaceRowFrame()
                        TextField("Name (optional)", text: $name).surfaceRowFrame()
                        Button("Create shell") { Task { _ = await feed.scope.perform("compute.create", ["environment": environment, "name": name]) } }.surfaceRowFrame().disabled(environment.isEmpty)
                    }
                }
                SettingsSection(Text("Compute resources")) {
                    ForEach(projection.objects("workloads"), id: \.self) { workload in
                        VStack(alignment: .leading, spacing: GroupedSurface.groupSpacing) {
                            Text(verbatim: workload.string("name") ?? workload.string("id") ?? "").font(.headline)
                            Text(verbatim: workload.string("phase") ?? workload.string("observed_state") ?? "").font(.subheadline).foregroundStyle(CommaTheme.textTertiary)
                            ForEach(workload.objects("uses"), id: \.self) { use in Text(verbatim: use.string("label") ?? use.string("kind") ?? "").font(.footnote) }
                            if let problem = workload.object("problem") { Text(verbatim: problem.string("code") ?? "").font(.footnote).foregroundStyle(CommaTheme.errorPrimary) }
                            if let id = workload.string("id") {
                                HStack {
                                    if workload.object("actions")?.bool("rename") == true { Button("Rename") { renameID = id; rename = workload.string("name") ?? "" } }
                                    if workload.object("actions")?.bool("retry") == true, let generation = workload.int("generation") {
                                        Button("Retry") { Task { _ = await feed.scope.perform("compute.retry", ["id": id, "generation": generation]) } }
                                    }
                                    Spacer()
                                    if workload.object("actions")?.bool("delete") == true, workload.int("generation") != nil { Button("Delete", role: .destructive) { deleting = CoreJSON(value: workload) } }
                                }
                            }
                        }.surfaceRowFrame()
                    }
                    if projection.objects("workloads").isEmpty { SettingsRow(Text("No compute resources")) }
                }
            }
            if let error = feed.scope.error { InlineError(message: error, retry: { Task { _ = await feed.scope.perform("compute.refresh", workspaceParameter: false) } }) }
        }.pageTitle("Compute resources").task { await feed.follow() }.refreshable { _ = await feed.scope.perform("compute.refresh", workspaceParameter: false) }
            .disabled(feed.scope.busy || !feed.scope.current)
            .alert("Rename resource", isPresented: Binding(get: { renameID != nil }, set: { if !$0 { renameID = nil } })) {
                TextField("Name", text: $rename)
                Button("Save") { if let id = renameID { Task { _ = await feed.scope.perform("compute.rename", ["id": id, "name": rename]) } }; renameID = nil }
                Button("Cancel", role: .cancel) { renameID = nil }
            }
            .confirmationDialog("Delete this compute resource?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                if let row = deleting?.object, let id = row.string("id"), let generation = row.int("generation") {
                    Button("Delete resource", role: .destructive) { Task { _ = await feed.scope.perform("compute.delete", ["id": id, "generation": generation]) }; deleting = nil }
                }
            } message: { Text("The resource will stop and its local files will be removed.") }
    }
}
