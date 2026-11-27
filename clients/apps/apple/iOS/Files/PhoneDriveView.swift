import SwiftUI
import QuickLook

struct PhoneDriveView: View {
    @State var model: PhoneDriveModel
    var pane: ConversationPane? = nil
    @State private var query = ""
    @State private var searchActive: Bool
    @State private var page = 0
    @Environment(\.inSheet) private var inSheet

    init(model: PhoneDriveModel, pane: ConversationPane? = nil, initialQuery: String = "") {
        _model = State(initialValue: model)
        self.pane = pane
        _query = State(initialValue: initialQuery)
        _searchActive = State(initialValue: !initialQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var searching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var background: Color { inSheet ? GroupedSurface.sheet : GroupedSurface.page }

    private var showOfflineNodeNote: Bool {
        model.feed.loaded
            && (model.selectedSpace.map { model.entryCount(in: $0.id, path: []) } ?? 0) == 0
            && !searching
            && model.scope.error == nil
            && model.feed.value.object?.object("node")?.string("status") == "off"
    }

    private var searchEmpty: Bool {
        guard searching, let space = model.selectedSpace, model.scope.error == nil else { return false }
        return model.searchFiles(in: space.id, under: [], query: query, page: page).results.isEmpty
    }

    private var folderEmpty: Bool {
        guard !searching, model.feed.loaded, let space = model.selectedSpace, model.scope.error == nil else { return false }
        return model.entryCount(in: space.id, path: []) == 0
    }

    private var childFolderBinding: Binding<String?> {
        Binding(
            get: { model.folderPath.first },
            set: { next in
                if let next {
                    model.openFolder(next, in: model.selectedSpaceID, from: [])
                } else if !model.folderPath.isEmpty {
                    model.popFolder(toDepth: 0)
                }
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if !model.spaces.isEmpty {
                VStack(alignment: .leading, spacing: GroupedSurface.margin) {
                    DriveSearchBar(text: $query, active: $searchActive, disabled: !model.scope.current)
                    if model.spaces.count > 1 {
                        spacePicker
                    }
                }
                .padding(.horizontal, GroupedSurface.margin)
                .padding(.top, 8)
                .padding(.bottom, GroupedSurface.inset)
            }
            SettingsPage(background: background) {
                if let space = model.selectedSpace {
                    PhoneDriveDirectorySection(
                        model: model,
                        space: space,
                        folderPath: [],
                        query: query,
                        page: $page,
                        pane: pane,
                        sectionTitle: model.spaces.count == 1 ? space.name : nil
                    )
                }
                if showOfflineNodeNote {
                    EmptyState(Text("Folder is empty"), icon: "central-folder-1")
                    SettingsSection {
                        SettingsNote(icon: "icon-info") {
                            Text("System Files and Task files are available here. Folders synced from a computer require that computer’s Drive node.")
                        }
                    }
                }
                if let error = model.scope.error { InlineError(message: error, retry: { Task { await model.refresh() } }) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if !model.feed.loaded, model.spaces.isEmpty {
                    ProgressView().allowsHitTesting(false)
                } else if model.feed.loaded, model.spaces.isEmpty, model.scope.error == nil {
                    EmptyState(Text("No files found"), icon: "central-folder-1").allowsHitTesting(false)
                } else if searchEmpty {
                    EmptyState(Text("No files found"), icon: "icon-search").allowsHitTesting(false)
                } else if folderEmpty, !showOfflineNodeNote {
                    EmptyState(Text("Folder is empty"), icon: "central-folder-1").allowsHitTesting(false)
                }
            }
        }
        .background(background)
        .scrollDismissesKeyboard(.interactively)
        .pageTitle("Drive")
        .toolbarVisibility(searchActive ? .hidden : .visible, for: .navigationBar)
        .modifier(DriveNewMemoryFileModifier(model: model, spaceID: model.selectedSpaceID, folderPath: []))
        .navigationDestination(item: childFolderBinding) { folderName in
            if let space = model.selectedSpace {
                PhoneDriveFolderView(model: model, space: space, folderPath: [folderName], pane: pane)
            }
        }
        .onChange(of: model.selectedSpaceID) { _, _ in page = 0 }
        .onChange(of: query) { _, _ in page = 0 }
        .onAppear { model.startFollowing() }
        .onChange(of: model.scope.current) { _, current in if !current { model.stopFollowing() } }
        .refreshable { await model.refresh() }
    }

    private var spacePicker: some View {
        ScrollView(.horizontal) {
            HStack(spacing: GroupedSurface.groupSpacing) {
                ForEach(model.spaces) { space in
                    let selected = space.id == model.selectedSpaceID
                    Button { model.selectSpace(space.id) } label: {
                        Text(verbatim: space.name)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(selected ? CommaTheme.bgPrimary : CommaTheme.textSecondary)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 36)
                            .background(selected ? CommaTheme.textPrimary : GroupedSurface.surface, in: Capsule())
                            .contentShape(Capsule().inset(by: -4))
                    }
                    .buttonStyle(TactileButtonStyle())
                    .disabled(!model.scope.current)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("driveSpace-" + space.id)
                }
            }
        }
        .scrollIndicators(.hidden)
        .contentMargins(.horizontal, GroupedSurface.margin, for: .scrollContent)
        .padding(.horizontal, -GroupedSurface.margin)
        .sensoryFeedback(.selection, trigger: model.selectedSpaceID)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("driveSpacePicker")
    }
}

/// One folder pushed onto the Drive navigation stack. Native back navigation and swipe-back replace desktop breadcrumbs.
struct PhoneDriveFolderView: View {
    let model: PhoneDriveModel
    let space: PhoneDriveSpace
    let folderPath: [String]
    var pane: ConversationPane? = nil
    @State private var query = ""
    @State private var searchActive: Bool
    @State private var page = 0
    @Environment(\.inSheet) private var inSheet

    init(model: PhoneDriveModel, space: PhoneDriveSpace, folderPath: [String],
         pane: ConversationPane? = nil, initialQuery: String = "") {
        self.model = model
        self.space = space
        self.folderPath = folderPath
        self.pane = pane
        _query = State(initialValue: initialQuery)
        _searchActive = State(initialValue: !initialQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var folderName: String { folderPath.last ?? space.name }
    private var background: Color { inSheet ? GroupedSurface.sheet : GroupedSurface.page }
    private var searching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var searchEmpty: Bool {
        guard searching, model.scope.error == nil else { return false }
        return model.searchFiles(in: space.id, under: folderPath, query: query, page: page).results.isEmpty
    }

    private var folderEmpty: Bool {
        guard !searching, model.feed.loaded, model.scope.error == nil else { return false }
        return model.entryCount(in: space.id, path: folderPath) == 0
    }

    private var childFolderBinding: Binding<String?> {
        Binding(
            get: {
                guard model.selectedSpaceID == space.id,
                      model.folderPath.count > folderPath.count,
                      model.folderPath.starts(with: folderPath) else { return nil }
                return model.folderPath[folderPath.count]
            },
            set: { next in
                if let next {
                    model.openFolder(next, in: space.id, from: folderPath)
                } else if model.selectedSpaceID == space.id,
                          model.folderPath.count > folderPath.count,
                          model.folderPath.starts(with: folderPath) {
                    model.popFolder(toDepth: folderPath.count)
                }
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            DriveSearchBar(text: $query, active: $searchActive, disabled: !model.scope.current)
                .padding(.horizontal, GroupedSurface.margin)
                .padding(.top, 8)
                .padding(.bottom, GroupedSurface.inset)
            SettingsPage(background: background) {
                PhoneDriveDirectorySection(
                    model: model,
                    space: space,
                    folderPath: folderPath,
                    query: query,
                    page: $page,
                    pane: pane,
                    sectionTitle: nil
                )
                if let error = model.scope.error { InlineError(message: error, retry: { Task { await model.refresh() } }) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if searchEmpty {
                    EmptyState(Text("No files found"), icon: "icon-search").allowsHitTesting(false)
                } else if folderEmpty {
                    EmptyState(Text("Folder is empty"), icon: "central-folder-1").allowsHitTesting(false)
                }
            }
        }
        .background(background)
        .scrollDismissesKeyboard(.interactively)
        .pageTitle(verbatim: folderName)
        .toolbarVisibility(searchActive ? .hidden : .visible, for: .navigationBar)
        .modifier(DriveNewMemoryFileModifier(model: model, spaceID: space.id, folderPath: folderPath))
        .navigationDestination(item: childFolderBinding) { folderName in
            PhoneDriveFolderView(model: model, space: space, folderPath: folderPath + [folderName], pane: pane)
        }
        .onChange(of: query) { _, _ in page = 0 }
        .onAppear { model.startFollowing() }
        .onChange(of: model.scope.current) { _, current in if !current { model.stopFollowing() } }
        .refreshable { await model.refresh() }
    }
}

/// In-page search capsule styled like iOS Files: sits cleanly below the navigation bar at rest,
/// then rises to the top beside a circular glass close button while active.
private struct DriveSearchBar: View {
    @Binding var text: String
    @Binding var active: Bool
    let disabled: Bool
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 42

    var body: some View {
        HStack(spacing: GroupedSurface.groupSpacing) {
            HStack(spacing: 8) {
                CentralIcon("icon-search", relativeTo: .body).foregroundStyle(CommaTheme.textSecondary)
                TextField(text: $text, prompt: Text("Search loaded files").foregroundStyle(CommaTheme.textPlaceholder)) {
                    Text("Search loaded files")
                }
                .font(.body)
                .foregroundStyle(CommaTheme.textPrimary)
                .tint(CommaTheme.brandSolid)
                .focused($focused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .accessibilityIdentifier("driveFileSearch")
                if !text.isEmpty {
                    Button { text = "" } label: {
                        CentralIcon("central-circle-x-fill", size: 20, relativeTo: .body).foregroundStyle(CommaTheme.textQuaternary)
                            .frame(width: 44, height: height).contentShape(Rectangle())
                    }
                    .buttonStyle(TactileButtonStyle(scale: 0.88))
                    .accessibilityLabel("Clear search")
                    .transition(.opacity)
                }
            }
            .padding(.leading, GroupedSurface.inset)
            .padding(.trailing, text.isEmpty ? GroupedSurface.inset : 0)
            .frame(minHeight: height)
            .background(GroupedSurface.ink, in: Capsule())
            .contentShape(Capsule())
            .onTapGesture {
                guard !disabled else { return }
                withAnimation(reduceMotion ? nil : CommaMotion.stateChange) { active = true }
                focused = true
            }
            .disabled(disabled)

            if active {
                Button {
                    text = ""
                    focused = false
                    withAnimation(reduceMotion ? nil : CommaMotion.stateChange) { active = false }
                } label: {
                    CentralIcon("icon-close", size: 18, relativeTo: .body)
                        .foregroundStyle(CommaTheme.textPrimary)
                        .frame(width: height, height: height)
                        .commaGlass(in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(TactileButtonStyle(scale: 0.92))
                .accessibilityLabel("Cancel search")
                .accessibilityIdentifier("driveCancelSearch")
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : CommaMotion.stateChange, value: text.isEmpty)
        .animation(reduceMotion ? nil : CommaMotion.stateChange, value: active)
        .onChange(of: focused) { _, isFocused in
            if isFocused, !active {
                withAnimation(reduceMotion ? nil : CommaMotion.stateChange) { active = true }
            }
        }
    }
}

private struct DriveNewMemoryFileModifier: ViewModifier {
    let model: PhoneDriveModel
    let spaceID: String
    let folderPath: [String]
    @State private var creating = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                if spaceID == PhoneDriveModel.systemFilesSpaceID {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { creating = true } label: { Label("New memory file", image: "central-plus-small") }
                            .accessibilityIdentifier("driveNewFile")
                            .disabled(!model.scope.current || model.scope.busy)
                    }
                    .verticalBarPreferred()
                }
            }
            .sheet(isPresented: $creating) {
                NavigationStack {
                    PhoneDriveDocumentView(
                        model: PhoneDriveDocument(
                            scope: model.scope,
                            initialPath: PhoneDriveModel.initialMemoryPath(for: folderPath)
                        )
                    )
                    .sheetCloseButton { creating = false }
                }
                .commaSheet([.large])
            }
    }
}

private struct PhoneDriveDirectorySection: View {
    let model: PhoneDriveModel
    let space: PhoneDriveSpace
    let folderPath: [String]
    let query: String
    @Binding var page: Int
    let pane: ConversationPane?
    let sectionTitle: String?

    private var searching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        if searching {
            let search = model.searchFiles(in: space.id, under: folderPath, query: query, page: page)
            let currentPage = PhoneDriveModel.clampedPage(page, pageCount: search.pageCount)
            Group {
                if !search.results.isEmpty {
                    SettingsSection(sectionTitle.map { Text(verbatim: $0) }) {
                        ForEach(search.results) { result in
                            NavigationLink {
                                PhoneDriveDocumentView(model: PhoneDriveDocument(scope: model.scope, file: result.file), pane: pane)
                            } label: {
                                DriveSearchResultRow(result: result)
                            }
                            .buttonStyle(SurfaceRowButtonStyle())
                            .disabled(!model.scope.current)
                            .accessibilityIdentifier("driveFile-" + result.file.id)
                        }
                    }
                    pagination(currentPage: currentPage, pageCount: search.pageCount)
                }
            }
            .onChange(of: search.pageCount) { _, count in
                let clamped = PhoneDriveModel.clampedPage(page, pageCount: count)
                if page != clamped { page = clamped }
            }
        } else {
            let pageCount = model.pageCount(in: space.id, path: folderPath)
            let currentPage = PhoneDriveModel.clampedPage(page, pageCount: pageCount)
            let entries = model.entries(in: space.id, path: folderPath, page: currentPage)
            Group {
                if !entries.isEmpty {
                    SettingsSection(sectionTitle.map { Text(verbatim: $0) }) {
                        ForEach(entries) { entry in
                            switch entry {
                            case .folder(let name):
                                let nextPath = folderPath + [name]
                                let count = model.entryCount(in: space.id, path: nextPath)
                                Button {
                                    model.openFolder(name, in: space.id, from: folderPath)
                                } label: {
                                    SettingsRow(Text(verbatim: name), icon: "central-folder-1", value: Text("\(count) items")) {
                                        SettingsChevron()
                                    }
                                }
                                .buttonStyle(SurfaceRowButtonStyle())
                                .disabled(!model.scope.current)
                                .accessibilityIdentifier("driveFolder-" + name)
                            case .file(let file):
                                NavigationLink {
                                    PhoneDriveDocumentView(model: PhoneDriveDocument(scope: model.scope, file: file), pane: pane)
                                } label: {
                                    SettingsRow(Text(verbatim: file.name),
                                                icon: file.isImage ? "central-images-1" : "central-file-bend",
                                                value: Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))) {
                                        SettingsChevron()
                                    }
                                }
                                .buttonStyle(SurfaceRowButtonStyle())
                                .disabled(!model.scope.current)
                                .accessibilityIdentifier("driveFile-" + file.id)
                            }
                        }
                    }
                    pagination(currentPage: currentPage, pageCount: pageCount)
                }
            }
            .onChange(of: pageCount) { _, count in
                let clamped = PhoneDriveModel.clampedPage(page, pageCount: count)
                if page != clamped { page = clamped }
            }
        }
    }

    @ViewBuilder private func pagination(currentPage: Int, pageCount: Int) -> some View {
        if pageCount > 1 {
            SettingsSection {
                HStack {
                    Button("Previous page") { page = max(0, currentPage - 1) }
                        .disabled(!model.scope.current || currentPage == 0)
                    Spacer()
                    Text("\(currentPage + 1) / \(pageCount)").font(.footnote).foregroundStyle(CommaTheme.textTertiary)
                    Spacer()
                    Button("Next page") { page = min(pageCount - 1, currentPage + 1) }
                        .disabled(!model.scope.current || currentPage + 1 >= pageCount)
                }.surfaceRowFrame()
            }
        }
    }
}

private struct DriveSearchResultRow: View {
    let result: PhoneDriveSearchResult
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(spacing: 8) {
            CentralIcon(result.file.isImage ? "central-images-1" : "central-file-bend", size: 20, relativeTo: .body)
                .foregroundStyle(CommaTheme.textSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: result.file.name)
                    .font(.body)
                    .foregroundStyle(CommaTheme.textPrimary)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                if !result.relativeFolder.isEmpty {
                    Text(verbatim: result.relativeFolder)
                        .font(.footnote)
                        .foregroundStyle(CommaTheme.textTertiary)
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(ByteCountFormatter.string(fromByteCount: Int64(result.file.size), countStyle: .file))
                .font(.footnote)
                .foregroundStyle(CommaTheme.textTertiary)
                .lineLimit(1)
            SettingsChevron()
        }
        .surfaceRowFrame()
        .accessibilityElement(children: .combine)
    }
}

struct PhoneDriveDocumentView: View {
    @State var model: PhoneDriveDocument
    var pane: ConversationPane? = nil
    @State private var preview: URL?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.inSheet) private var inSheet
    @Environment(AppNavigation.self) private var navigation

    var body: some View {
        SettingsPage(background: inSheet ? GroupedSurface.sheet : GroupedSurface.page) {
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
