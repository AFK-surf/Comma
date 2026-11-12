import SwiftUI

struct PhoneNewTaskView: View {
    @State var model: PhoneNewTaskModel
    @State private var repositoryPicker: PhoneRepositoryPickerModel?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.usesVerticalToolbar) private var verticalToolbar
    @ScaledMetric(relativeTo: .subheadline) private var controlHeight: CGFloat = 44
    private let headerTopPadding: CGFloat = 24

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                header.padding(headerOcclusionInsets(in: geometry))
                editor
            }
        }
        .background(CommaTheme.cardPrimary)
        .tint(CommaTheme.brandSolid)
        .toolbar(.hidden, for: .navigationBar)
        // The modal header covers the presenting page’s Duo rail.
        .ignoresSafeArea(.container, edges: verticalToolbar ? .trailing : [])
        .task { await model.models.follow() }
        .task { await model.followEnvironments() }
        .task(id: model.environmentID) {
            await model.loadEnvironment()
            if model.inCoding, !model.reposLoaded { await model.loadRepos() }
        }
        .task(id: model.repoID) { await model.loadBranches() }
        .disabled(model.starting || model.scope.busy || !model.scope.current)
        .accessibilityIdentifier("newTaskSheet")
    }

    private var header: some View {
        HStack(spacing: 12) {
            closeButton.frame(width: controlHeight, height: controlHeight)
            Spacer(minLength: 0)
            environmentMenu.frame(maxWidth: 240)
            Spacer(minLength: 0)
            createButton.frame(width: controlHeight, height: controlHeight)
        }
        .padding(.horizontal, GroupedSurface.margin)
        .padding(.top, headerTopPadding).padding(.bottom, 12)
        .accessibilityIdentifier("newTaskHeader")
    }

    private func headerOcclusionInsets(in geometry: GeometryProxy) -> EdgeInsets {
        #if canImport(SwiftUI, _version: 8.0.85)
        if #available(iOS 27.1, *) {
            // Reserved frames include the hardware's interaction margins. Keep the glass controls'
            // visual overhang clear too, and query in the sheet's coordinates as it resizes.
            let width = geometry.size.width
            let band = CGRect(x: 0, y: 0, width: width,
                              height: headerTopPadding + controlHeight + GroupedSurface.groupSpacing)
            let regions = geometry.reservedRegions(kind: .occlusion).filter { $0.isActive && $0.frame.intersects(band) }
            // Rotation moves the camera to either side of the header.
            let leading = regions.filter { $0.frame.midX < width / 2 }.map { $0.frame.maxX }.max() ?? 0
            let trailing = regions.filter { $0.frame.midX >= width / 2 }.map { width - $0.frame.minX }.max() ?? 0
            let clearance = GroupedSurface.margin - GroupedSurface.groupSpacing
            return EdgeInsets(top: 0, leading: max(0, leading - clearance), bottom: 0, trailing: max(0, trailing - clearance))
        }
        #endif
        return EdgeInsets()
    }

    @ViewBuilder private var closeButton: some View {
        if #available(iOS 26.0, *) {
            closeAction.buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.large)
        } else {
            closeAction.buttonStyle(.bordered).buttonBorderShape(.circle).controlSize(.large)
        }
    }

    private var closeAction: some View {
        Button { dismiss() } label: { CentralIcon("icon-close", size: 20).frame(width: 20, height: 20) }
            .tint(CommaTheme.textPrimary)
            .accessibilityLabel("Close").accessibilityIdentifier("closeNewTask")
    }

    private var editor: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                if model.text.isEmpty {
                    Text("What would you like it to do?")
                        .font(.body).foregroundStyle(CommaTheme.textPlaceholder)
                        .padding(.horizontal, GroupedSurface.margin + 5).padding(.top, 12)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $model.text)
                    .font(.body).scrollContentBackground(.hidden)
                    .padding(.horizontal, GroupedSurface.margin).padding(.vertical, 4)
                    .accessibilityLabel("Task instructions")
                    .accessibilityIdentifier("newTaskInstructions")
            }
            .frame(minHeight: 0, maxHeight: .infinity)
            if let error = model.scope.error ?? model.models.scope.error ?? model.profilesError {
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: error).font(.footnote).foregroundStyle(CommaTheme.errorPrimary)
                    Spacer(minLength: 8)
                    Button("Retry") { Task { await reload() } }.font(.footnote.weight(.medium))
                }.padding(.horizontal, GroupedSurface.margin).padding(.bottom, 8)
            }
            properties
        }
    }

    private var environmentName: String {
        model.environments.first { $0.id == model.environmentID }?.name ?? String(localized: "Run in")
    }

    private var environmentMenu: some View {
        Menu {
            Picker("Run in", selection: $model.environmentID) {
                ForEach(model.environments) { environment in
                    Text(environment.online ? environment.name : environment.name + " · " + String(localized: "Offline"))
                        .tag(environment.id).disabled(!environment.online)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(verbatim: environmentName).font(.subheadline.weight(.medium)).lineLimit(1).truncationMode(.middle)
                CentralIcon("central-chevron-down-small", size: 12)
            }
            .foregroundStyle(CommaTheme.textPrimary)
            .padding(.horizontal, 14).frame(minHeight: controlHeight)
            .commaGlass(in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Run in").accessibilityValue(environmentName)
        .accessibilityIdentifier("newTaskEnvironmentMenu")
    }

    private var properties: some View {
        FlowLayout(spacing: 8) {
            if model.inCoding { repository; branch }
            modelMenu
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .commaGlassGroup(spacing: 8)
        .padding(.horizontal, GroupedSurface.margin).padding(.vertical, 12)
        .accessibilityIdentifier("newTaskProperties")
    }

    @ViewBuilder private var createButton: some View {
        if #available(iOS 26.0, *) {
            createAction.buttonStyle(.glassProminent).buttonBorderShape(.circle).controlSize(.large)
        } else {
            createAction.buttonStyle(.borderedProminent).buttonBorderShape(.circle).controlSize(.large)
        }
    }

    private var createAction: some View {
        Button {
            Task {
                if let task = await model.start() {
                    dismiss()
                    await model.scope.store.openTask(id: task)
                }
            }
        } label: {
            Group {
                if model.starting { ProgressView().controlSize(.small) }
                else { CentralIcon("central-arrow-up", size: 20) }
            }
            .frame(width: 20, height: 20)
        }
        .disabled(!model.canStart)
        .accessibilityLabel("Create task")
        .accessibilityIdentifier("createTask")
    }

    private var repository: some View {
        Button { repositoryPicker = PhoneRepositoryPickerModel(scope: model.scope, selected: model.repo) } label: {
            chip(model.repo?.id ?? String(localized: "Repository"), icon: "provider-github")
        }
        .buttonStyle(.plain).accessibilityLabel("Repository")
        .accessibilityValue(model.repo?.id ?? String(localized: "Choose a repository"))
        .accessibilityIdentifier("newTaskRepository")
        .sheet(item: $repositoryPicker) { picker in
            PhoneRepositoryPickerView(model: picker) { model.selectRepository($0) }
                .commaSheet([.large])
        }
    }

    private var branch: some View {
        Menu {
            Picker("Base branch", selection: $model.branch) {
                Text("Default branch").tag("")
                ForEach(model.branches, id: \.self) { Text(verbatim: $0).tag($0) }
            }
            if model.moreBranches { Button("Load more branches") { Task { await model.loadBranches(more: true) } } }
        } label: {
            chip(model.branch.isEmpty ? model.repo?.base ?? String(localized: "Default branch") : model.branch,
                 icon: "central-chain-link-4")
        }
        .disabled(model.repo == nil).accessibilityLabel("Base branch")
        .accessibilityValue(model.branch.isEmpty ? model.repo?.base ?? String(localized: "Default branch") : model.branch)
        .accessibilityIdentifier("newTaskBranch")
    }

    private var modelMenu: some View {
        Menu {
            if model.inCloud {
                Picker("Model", selection: Binding(get: { model.cloudModel?.id ?? "" }, set: { model.cloudModelID = $0 })) {
                    ForEach(model.cloudModels) { option in Text(verbatim: option.name).tag(option.id) }
                }
            } else {
                Picker("Run with", selection: Binding(get: { model.run?.id ?? "" }, set: { model.runID = $0 })) {
                    ForEach(model.runs) { run in Text(verbatim: run.label).tag(run.id) }
                }
            }
        } label: {
            chip(model.inCloud ? model.cloudModel?.name ?? String(localized: "Model") : model.run?.label ?? String(localized: "Model"),
                 icon: "central-brain", loading: !model.models.loaded || (!model.inCloud && !model.inSandbox && !model.profilesLoaded))
        }
        .disabled(model.inCloud ? model.cloudModels.isEmpty : model.runs.isEmpty)
        .accessibilityLabel("Model and account")
        .accessibilityIdentifier("newTaskModel")
    }

    private func chip(_ title: String, icon: String, loading: Bool = false) -> some View {
        HStack(spacing: 6) {
            if loading { ProgressView().controlSize(.mini) }
            else if icon == "provider-github" { Image(icon).resizable().scaledToFit().frame(width: 16, height: 16) }
            else { CentralIcon(icon, size: 16) }
            Text(verbatim: title).font(.subheadline.weight(.medium)).lineLimit(1).truncationMode(.middle)
            CentralIcon("central-chevron-down-small", size: 12)
        }
        .foregroundStyle(CommaTheme.textPrimary)
        .padding(.horizontal, 12).frame(minHeight: controlHeight).frame(maxWidth: 220)
        .commaGlass(in: Capsule())
    }

    private func reload() async {
        _ = await model.models.scope.perform("models.refresh", workspaceParameter: false)
        if model.inCoding { await model.loadRepos() } else { await model.loadEnvironment() }
    }
}

struct PhoneRepositoryPickerView: View {
    @State var model: PhoneRepositoryPickerModel
    var confirm: (PhoneCodingRepo) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.usesVerticalToolbar) private var verticalToolbar

    var body: some View {
        VStack(spacing: 0) {
            header
            FilterSearchField(prompt: model.owner.map { LocalizedStringKey("Search in \($0.login)") } ?? "Search organizations",
                              text: $model.query, icon: "icon-search", accessibilityID: "repositorySearch")
                .padding(.horizontal, GroupedSurface.margin).padding(.bottom, GroupedSurface.inset)
            ScrollView {
                LazyVStack(spacing: 0) {
                    if let owner = model.owner {
                        Button { model.owner = nil } label: {
                            HStack(spacing: GroupedSurface.groupSpacing) {
                                CentralIcon("central-chevron-right-small", size: 16).rotationEffect(.degrees(180))
                                Text("Organizations").font(.subheadline.weight(.medium))
                                Spacer()
                                Text(verbatim: owner.login).font(.subheadline).foregroundStyle(CommaTheme.textTertiary)
                            }.surfaceRowFrame()
                        }.buttonStyle(SurfaceRowButtonStyle()).accessibilityIdentifier("repositoryOrganizations")
                        ForEach(model.repos) { repo in repository(repo) }
                        if model.moreRepos, model.error == nil {
                            ProgressView().frame(maxWidth: .infinity).padding(GroupedSurface.margin)
                                .id(model.searchKey + "-" + String(model.repos.count))
                                .onAppear { Task { await model.loadRepos(more: true) } }
                        }
                        if model.limited { Text("Refine your search to see more results.").font(.footnote).foregroundStyle(CommaTheme.textTertiary).padding(GroupedSurface.margin) }
                        if model.loaded, model.repos.isEmpty, model.error == nil { empty }
                    } else {
                        ForEach(model.visibleOwners) { owner in
                            Button { model.owner = owner } label: {
                                HStack(spacing: GroupedSurface.inset) {
                                    ownerAvatar(owner)
                                    Text(verbatim: owner.login).font(.body).foregroundStyle(CommaTheme.textPrimary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    SettingsChevron()
                                }.surfaceRowFrame()
                            }.buttonStyle(SurfaceRowButtonStyle()).accessibilityIdentifier("repositoryOwner-" + owner.login)
                        }
                        if model.moreOwners, model.error == nil {
                            ProgressView().frame(maxWidth: .infinity).padding(GroupedSurface.margin)
                                .id(model.owners.count).onAppear { Task { await model.loadOwners(more: true) } }
                        }
                        if model.ownersLoaded, model.visibleOwners.isEmpty, model.error == nil { empty }
                    }
                    if let error = model.error {
                        InlineError(message: error, retry: { Task { if model.owner == nil { await model.loadOwners(more: model.moreOwners) } else { await model.loadRepos(more: model.moreRepos) } } })
                            .padding(GroupedSurface.margin)
                    } else if model.loading || model.ownersLoading {
                        ProgressView().frame(maxWidth: .infinity).padding(GroupedSurface.margin)
                    }
                }.padding(.horizontal, GroupedSurface.margin).padding(.bottom, GroupedSurface.margin)
            }
            .scrollDismissesKeyboard(.interactively)
            .id(model.owner?.id ?? "organizations")
        }
        .background(CommaTheme.cardPrimary).tint(CommaTheme.brandSolid)
        .toolbar(.hidden, for: .navigationBar)
        .ignoresSafeArea(.container, edges: verticalToolbar ? .trailing : [])
        .task { await model.loadOwners() }
        .task(id: model.searchKey) { if model.owner != nil { await model.search() } }
        .disabled(!model.scope.current)
        .accessibilityIdentifier("repositoryPicker")
    }

    private var header: some View {
        HStack(spacing: GroupedSurface.inset) {
            closeButton
            Spacer(minLength: 0)
            Text("Repository").font(.headline).lineLimit(1)
            Spacer(minLength: 0)
            confirmButton
        }
        .padding(.horizontal, GroupedSurface.margin).padding(.vertical, GroupedSurface.margin)
    }

    @ViewBuilder private var closeButton: some View {
        if #available(iOS 26.0, *) { closeAction.buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.large) }
        else { closeAction.buttonStyle(.bordered).buttonBorderShape(.circle).controlSize(.large) }
    }

    private var closeAction: some View {
        Button { dismiss() } label: { CentralIcon("icon-close", size: 20).frame(width: 20, height: 20) }
            .tint(CommaTheme.textPrimary).accessibilityLabel("Close").accessibilityIdentifier("closeRepositoryPicker")
    }

    @ViewBuilder private var confirmButton: some View {
        if #available(iOS 26.0, *) { confirmAction.buttonStyle(.glassProminent).buttonBorderShape(.circle).controlSize(.large) }
        else { confirmAction.buttonStyle(.borderedProminent).buttonBorderShape(.circle).controlSize(.large) }
    }

    private var confirmAction: some View {
        Button {
            if let selected = model.selected { confirm(selected); dismiss() }
        } label: { CentralIcon("central-checkmark-1", size: 20).frame(width: 20, height: 20) }
            .disabled(model.selected == nil).accessibilityLabel("Confirm").accessibilityIdentifier("confirmRepository")
    }

    private func ownerAvatar(_ owner: PhoneRepositoryOwner) -> some View {
        AsyncImage(url: owner.avatarURL) { phase in
            if let image = phase.image { image.resizable().scaledToFill() }
            else {
                CentralIcon(owner.kind == "user" ? "central-people-circle" : "central-buildings", size: 20)
                    .foregroundStyle(CommaTheme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(GroupedSurface.surface)
            }
        }
        .frame(width: CommaTheme.avatarGutter, height: CommaTheme.avatarGutter)
        .clipShape(RoundedRectangle(cornerRadius: owner.kind == "user" ? CommaTheme.avatarGutter / 2 : GroupedSurface.groupSpacing))
        .accessibilityHidden(true)
    }

    private func repository(_ repo: PhoneCodingRepo) -> some View {
        Button { model.selected = repo } label: {
            HStack(spacing: GroupedSurface.inset) {
                Image("provider-github").resizable().scaledToFit().frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: GroupedSurface.groupSpacing / 2) {
                    Text(verbatim: repo.name).font(.body).foregroundStyle(CommaTheme.textPrimary)
                    Text(verbatim: repo.owner).font(.footnote).foregroundStyle(CommaTheme.textTertiary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                if model.selected?.id == repo.id { CentralIcon("icon-check", size: 20).foregroundStyle(CommaTheme.brandSolid) }
            }.surfaceRowFrame()
        }
        .buttonStyle(SurfaceRowButtonStyle())
        .accessibilityAddTraits(model.selected?.id == repo.id ? .isSelected : [])
        .accessibilityIdentifier("repository-" + repo.id)
    }

    private var empty: some View {
        Text("No results").font(.body).foregroundStyle(CommaTheme.textTertiary)
            .frame(maxWidth: .infinity).padding(.vertical, GroupedSurface.rowHeight)
    }
}

struct PhoneCodingView: View {
    @State var model: PhoneCodingModel
    @State private var prEditor = false
    @State private var merging: MergeTarget?
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SettingsPage {
            if !model.loaded { ProgressView().frame(maxWidth: .infinity) }
            if let session = model.session.object {
                SettingsSection(Text("Environment")) {
                    if let repo = session.object("repo") {
                        SettingsRow(Text("Repository"), value: Text(verbatim: [repo.string("owner"), repo.string("name")].compactMap { $0 }.joined(separator: "/")))
                        SettingsRow(Text("Branch"), value: Text(verbatim: repo.string("branch") ?? "—"))
                        SettingsRow(Text("Base branch"), value: Text(verbatim: repo.string("baseRef") ?? "—"))
                    }
                    SettingsRow(Text("Sandbox"), value: Text(status(session.string("state"))))
                    if let reason = session.string("reason") { Text(verbatim: reason).surfaceRowFrame() }
                    if session.string("state") == "ready" {
                        Button { Task { if let url = await model.terminal() { openURL(url) } } } label: {
                            SettingsRow(Text("Open terminal"), role: .action)
                        }.buttonStyle(SurfaceRowButtonStyle())
                    }
                    NavigationLink { PhoneCodingHistoryView(model: model) } label: {
                        SettingsRow(Text("Execution history")) { SettingsChevron() }
                    }.buttonStyle(SurfaceRowButtonStyle())
                }
            }
            if model.changes.object != nil {
                SettingsSection(Text("Changes")) {
                    Picker("Compare", selection: $model.selection) {
                        Text("All changes").tag("")
                        if model.hasUncommitted || model.selection == "uncommitted" { Text("Uncommitted").tag("uncommitted") }
                        ForEach(model.commits, id: \.self) { commit in
                            Text(verbatim: commit.string("title") ?? "").tag(commit.string("sha") ?? "")
                        }
                    }.surfaceRowFrame()
                    if model.files.isEmpty { SettingsRow(Text("No changes")) }
                    ForEach(model.files, id: \.self) { file in
                        NavigationLink { PhoneCodePatchView(file: file) } label: {
                            VStack(alignment: .leading, spacing: GroupedSurface.groupSpacing) {
                                Text(verbatim: file.string("path") ?? "").font(.body).foregroundStyle(CommaTheme.textPrimary)
                                Text(verbatim: "+\(file.int("additions") ?? 0)  −\(file.int("deletions") ?? 0)")
                                    .font(.caption.monospaced()).foregroundStyle(CommaTheme.textTertiary)
                            }.frame(maxWidth: .infinity, alignment: .leading).surfaceRowFrame()
                        }.buttonStyle(SurfaceRowButtonStyle())
                    }
                    if model.changes.object?.bool("truncated") == true {
                        SettingsNote(icon: "icon-info") { Text("Some changes are too large to display. Review the complete branch on GitHub.") }
                    }
                }
                pullRequest
            }
            if let error = model.scope.error { InlineError(message: error, retry: { Task { await model.load() } }) }
        }
        .pageTitle("Code review")
        .task { await model.load() }
        .task(id: model.selection) { if model.loaded { await model.loadChanges() } }
        .refreshable { await model.load() }
        .sheet(isPresented: $prEditor) { NavigationStack { prForm }.commaSheet([.large]) }
        .confirmationDialog("Merge pull request?", isPresented: Binding(get: { merging != nil }, set: { if !$0 { merging = nil } }), titleVisibility: .visible, presenting: merging) { target in
            Button("Merge pull request") { Task { await model.merge(number: target.number, head: target.head) }; merging = nil }
        } message: { target in Text(verbatim: "#\(target.number) · \(target.head.prefix(12))") }
        .disabled(model.scope.busy || !model.scope.current)
    }

    @ViewBuilder private var pullRequest: some View {
        SettingsSection(Text("Pull request")) {
            if let pr = model.pr {
                SettingsRow(Text(verbatim: pr.string("title") ?? String(localized: "Pull request")), value: Text(status(pr.string("state"))))
                if let checks = pr.object("checks") {
                    VStack(alignment: .leading, spacing: GroupedSurface.groupSpacing / 2) {
                        Text("Checks").font(.subheadline).foregroundStyle(CommaTheme.textTertiary)
                        Text("\(checks.int("passed") ?? 0) passed · \(checks.int("failed") ?? 0) failed · \(checks.int("total") ?? 0) total").font(.body).fixedSize(horizontal: false, vertical: true)
                    }.surfaceRowFrame()
                }
                if let link = pr.string("url"), let url = URL(string: link), url.scheme == "https" {
                    Link(destination: url) { SettingsRow(Text("Open on GitHub"), role: .action) }.buttonStyle(SurfaceRowButtonStyle())
                }
                if ["open", "draft"].contains(pr.string("state") ?? "") {
                    Button { prEditor = true } label: { SettingsRow(Text("Edit pull request"), role: .action) }.buttonStyle(SurfaceRowButtonStyle())
                    if pr.string("state") == "draft" {
                        Button { Task { await model.readyPR() } } label: { SettingsRow(Text("Mark ready for review"), role: .action) }.buttonStyle(SurfaceRowButtonStyle())
                    }
                    if pr.string("state") == "open", let number = pr.int("number"), let head = pr.string("headSha") {
                        Button { merging = MergeTarget(number: number, head: head) } label: { SettingsRow(Text("Merge pull request"), role: .action) }
                            .buttonStyle(SurfaceRowButtonStyle()).disabled(pr.string("mergeable") == "conflicting")
                    }
                } else if pr.bool("newCommits") {
                    Button { prEditor = true } label: { SettingsRow(Text("Create pull request"), role: .action) }.buttonStyle(SurfaceRowButtonStyle())
                }
            } else {
                Button { prEditor = true } label: { SettingsRow(Text("Create pull request"), role: .action) }.buttonStyle(SurfaceRowButtonStyle())
            }
        }
    }

    private var prForm: some View {
        SettingsPage(background: CommaTheme.cardPrimary) {
            SettingsSection(Text("Pull request")) {
                TextField("Title", text: $model.prTitle).surfaceRowFrame()
                TextEditor(text: $model.prBody).frame(minHeight: GroupedSurface.rowHeight * 4).surfaceRowFrame().accessibilityLabel("Description")
                if model.pr == nil || model.pr?.bool("newCommits") == true { SettingsToggle(title: Text("Draft"), isOn: $model.prDraft) }
                Button { Task { if await model.savePR() { prEditor = false } } } label: { SettingsRow(Text("Save"), role: .action) }
                    .buttonStyle(SurfaceRowButtonStyle()).disabled(model.prTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.scope.busy)
            }
            if let error = model.scope.error { InlineError(message: error, dismiss: { model.scope.error = nil }) }
        }.pageTitle("Pull request").sheetCloseButton { prEditor = false }
    }
    private struct MergeTarget { let number: Int; let head: String }
    private func status(_ value: String?) -> String {
        switch value {
        case "ready": String(localized: "Ready")
        case "starting": String(localized: "Starting")
        case "stopped": String(localized: "Stopped")
        case "lost": String(localized: "Disconnected")
        case "failed": String(localized: "Failed")
        case "ended": String(localized: "Ended")
        case "open": String(localized: "Open")
        case "draft": String(localized: "Draft")
        case "merged": String(localized: "Merged")
        case "closed": String(localized: "Closed")
        default: value ?? "—"
        }
    }
}

struct PhoneCodePatchView: View {
    let file: NSDictionary
    var body: some View {
        SettingsPage {
            SettingsSection {
                if let patch = file.string("patch") {
                    ScrollView(.horizontal) { Text(verbatim: patch).font(.footnote.monospaced()).textSelection(.enabled).fixedSize(horizontal: true, vertical: false).surfaceRowFrame() }
                } else { SettingsNote(icon: "icon-info") { Text("This file has no text diff. Open the pull request to review it.") } }
            }
        }.pageTitle(verbatim: file.string("path") ?? String(localized: "Changes"))
    }
}

struct PhoneCodingHistoryView: View {
    @Bindable var model: PhoneCodingModel
    var body: some View {
        SettingsPage {
            if model.history.object?.bool("available") == false {
                SettingsSection { SettingsNote(icon: "icon-info") { Text("Execution history is available while the sandbox is running.") } }
            }
            ForEach(Array(model.historyItems.enumerated()), id: \.offset) { _, item in
                if let json = item.object {
                    SettingsSection {
                        if json.string("kind") == "group" {
                            ForEach(json.objects("steps"), id: \.self) { step in
                                DisclosureGroup {
                                    if let body = step.object("body") {
                                        Text(verbatim: body.string("command") ?? body.string("diff") ?? body.string("lines") ?? body.string("text") ?? body.string("path") ?? "").font(.footnote.monospaced()).textSelection(.enabled)
                                    }
                                    Text(verbatim: step.string("result") ?? step.string("text") ?? "").font(.footnote.monospaced()).textSelection(.enabled)
                                } label: { Text(verbatim: step.string("hint") ?? step.string("tool") ?? String(localized: "Thinking")) }.surfaceRowFrame()
                            }
                        } else { Text(verbatim: json.text("text") ?? "").textSelection(.enabled).surfaceRowFrame() }
                    }
                }
            }
            if let start = model.history.object?.int("start"), start > 0 {
                Button("Load more") { Task { await model.loadHistory(more: true) } }.surfaceRowFrame()
            }
            if let error = model.scope.error { InlineError(message: error, retry: { Task { await model.loadHistory() } }) }
        }.pageTitle("Execution history").task { await model.loadHistory() }
    }
}
