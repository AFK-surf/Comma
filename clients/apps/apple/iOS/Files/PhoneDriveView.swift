import SwiftUI
import QuickLook

struct PhoneDriveView: View {
    @State var model: PhoneDriveModel
    var pane: ConversationPane? = nil
    @State private var creating = false

    var body: some View {
        @Bindable var model = model
        SettingsPage {
            SettingsSection {
                HStack(spacing: GroupedSurface.groupSpacing) {
                    CentralIcon("icon-search", size: 20, relativeTo: .body).foregroundStyle(CommaTheme.textTertiary)
                    TextField("Search loaded files", text: $model.query)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search)
                        .accessibilityIdentifier("driveFileSearch")
                    if !model.query.isEmpty {
                        Button { model.query = "" } label: { CentralIcon("icon-close", size: 16, relativeTo: .body) }
                            .accessibilityLabel("Clear search")
                    }
                }.surfaceRowFrame()
            }
            if !model.feed.loaded { ProgressView().frame(maxWidth: .infinity) }
            if !model.spaces.isEmpty {
                if let space = model.selectedSpace { breadcrumb(space) }
                SettingsSection {
                    ForEach(model.entries) { entry in
                        switch entry {
                        case .folder(let name):
                            Button { model.openFolder(name) } label: {
                                SettingsRow(Text(verbatim: name), icon: "central-folder-1") { SettingsChevron() }
                            }
                            .buttonStyle(SurfaceRowButtonStyle())
                            .accessibilityIdentifier("driveFolder-" + name)
                        case .file(let file):
                            NavigationLink {
                                PhoneDriveDocumentView(model: PhoneDriveDocument(scope: model.scope, file: file), pane: pane)
                            } label: {
                                SettingsRow(Text(verbatim: file.name), icon: "central-file-bend",
                                            value: Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))) {
                                    SettingsChevron()
                                }
                            }
                            .buttonStyle(SurfaceRowButtonStyle())
                            .accessibilityIdentifier("driveFile-" + file.id)
                        }
                    }
                    if model.feed.loaded, model.entries.isEmpty {
                        SettingsRow(Text(model.query.isEmpty ? "Folder is empty" : "No files found"))
                    }
                }
                if model.pageCount > 1 {
                    SettingsSection {
                        HStack {
                            Button("Previous page") { model.movePage(by: -1) }.disabled(model.page == 0)
                            Spacer()
                            Text("\(model.page + 1) / \(model.pageCount)").font(.footnote).foregroundStyle(CommaTheme.textTertiary)
                            Spacer()
                            Button("Next page") { model.movePage(by: 1) }.disabled(model.page + 1 >= model.pageCount)
                        }.surfaceRowFrame()
                    }
                }
            } else if model.feed.loaded, model.scope.error == nil {
                EmptyState(Text("No files found"), icon: "central-folder-1")
            }
            if model.feed.loaded, model.entryCount == 0, model.query.isEmpty, model.scope.error == nil,
               model.feed.value.object?.object("node")?.string("status") == "off" {
                SettingsSection { SettingsNote(icon: "icon-info") { Text("System Files and Task files are available here. Folders synced from a computer require that computer’s Drive node.") } }
            }
            if let error = model.scope.error { InlineError(message: error, retry: { Task { await model.refresh() } }) }
        }
        .pageTitle("Drive")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Picker("Space", selection: Binding(get: { model.selectedSpaceID }, set: { model.selectSpace($0) })) {
                        ForEach(model.spaces) { space in Text(verbatim: space.name).tag(space.id) }
                    }
                } label: { Label("File scope", image: "icon-filter") }
                    .accessibilityValue(Text(verbatim: model.selectedSpace?.name ?? ""))
                    .accessibilityIdentifier("driveScopeFilter")
                    .disabled(model.spaces.isEmpty || !model.scope.current)
                Button { creating = true } label: { Label("New memory file", image: "central-plus-small") }
                    .accessibilityIdentifier("driveNewFile")
                    .disabled(model.selectedSpaceID != "comma-system-files" || !model.scope.current || model.scope.busy)
            }
            .verticalBarPreferred()
        }
        .task { await model.follow() }
        .refreshable { await model.refresh() }
        .sheet(isPresented: $creating) {
            NavigationStack { PhoneDriveDocumentView(model: PhoneDriveDocument(scope: model.scope)).sheetCloseButton { creating = false } }.commaSheet([.large])
        }
    }

    private func breadcrumb(_ space: PhoneDriveSpace) -> some View {
        ScrollViewReader { scroller in
            ScrollView(.horizontal) {
                HStack(spacing: GroupedSurface.groupSpacing) {
                    ForEach(Array(([space.name] + model.folderPath).enumerated()), id: \.offset) { depth, name in
                        if depth > 0 {
                            CentralIcon("central-chevron-right-small", size: 16, relativeTo: .subheadline)
                                .foregroundStyle(CommaTheme.textQuaternary)
                        }
                        if depth == model.folderPath.count {
                            Text(verbatim: name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(CommaTheme.textPrimary)
                                .accessibilityAddTraits(.isHeader)
                                .id(depth)
                        } else {
                            Button { model.navigate(to: depth) } label: {
                                Text(verbatim: name).font(.subheadline)
                                    .frame(minHeight: GroupedSurface.rowHeight)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(CommaTheme.textSecondary)
                            .accessibilityIdentifier("driveBreadcrumb-\(depth)")
                            .id(depth)
                        }
                    }
                }
                .frame(minHeight: GroupedSurface.rowHeight)
                .padding(.horizontal, GroupedSurface.margin)
            }
            .frame(height: GroupedSurface.rowHeight)
            .scrollIndicators(.hidden)
            .background(GroupedSurface.page)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Location")
            .accessibilityValue(Text(verbatim: ([space.name] + model.folderPath).joined(separator: " / ")))
            .accessibilityIdentifier("driveBreadcrumb")
            .onAppear { scroller.scrollTo(model.folderPath.count, anchor: .trailing) }
            .onChange(of: model.folderPath) { _, path in scroller.scrollTo(path.count, anchor: .trailing) }
        }
    }
}

struct PhoneDriveDocumentView: View {
    @State var model: PhoneDriveDocument
    var pane: ConversationPane? = nil
    @State private var preview: URL?
    @Environment(\.dismiss) private var dismiss
    @Environment(AppNavigation.self) private var navigation

    var body: some View {
        SettingsPage {
            if !model.loaded { ProgressView().frame(maxWidth: .infinity) }
            else {
                if model.file == nil {
                    SettingsSection(Text("Memory path"), footer: Text("Use an allowed memory path, such as /memory/scoped/project.md.")) {
                        TextField("Memory path", text: $model.path).textInputAutocapitalization(.never).autocorrectionDisabled().surfaceRowFrame()
                    }
                }
                SettingsSection(Text(model.editable ? "Content" : "Preview")) {
                    if model.editable {
                        TextEditor(text: $model.text).font(.body.monospaced()).frame(minHeight: GroupedSurface.rowHeight * 5)
                            .surfaceRowFrame().accessibilityLabel("File content")
                    } else if !model.text.isEmpty {
                        Text(verbatim: model.text).font(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).surfaceRowFrame()
                    } else if let url = model.preview {
                        Button { preview = url } label: { SettingsRow(Text("Open preview"), role: .action) }.buttonStyle(SurfaceRowButtonStyle())
                    }
                }
                SettingsSection {
                    if model.editable {
                        Button { Task { if await model.save(), model.file == nil { dismiss() } } } label: { SettingsRow(Text("Save"), role: .action) }
                            .buttonStyle(SurfaceRowButtonStyle()).disabled(model.saved == model.text && model.file != nil)
                    }
                    if let url = model.preview {
                        ShareLink(item: url) { SettingsRow(Text("Save or share…"), icon: "central-share-os") }.buttonStyle(SurfaceRowButtonStyle())
                        Button {
                            Task { if await model.attach(to: pane ?? model.scope.store.router.pane) { if pane == nil { navigation.openRouter() } else { dismiss() } } }
                        } label: { SettingsRow(Text(pane == nil ? "Add to Router chat" : "Add to context"), role: .action) }.buttonStyle(SurfaceRowButtonStyle())
                            .disabled(model.saved != model.text)
                    }
                }
            }
            if let error = model.scope.error { InlineError(message: error, retry: { Task { await model.load() } }) }
        }
        .pageTitle(verbatim: model.file?.name ?? String(localized: "New memory file"))
        .task { await model.load() }
        .quickLookPreview($preview)
        .disabled(model.scope.busy || !model.scope.current)
    }
}
