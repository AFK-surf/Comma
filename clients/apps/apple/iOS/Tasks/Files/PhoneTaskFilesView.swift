import SwiftUI
import QuickLook

struct PhoneTaskFilesView: View {
    @State var model: PhoneTaskFilesModel
    @State private var query = ""
    @State private var previewURL: URL?
    @State private var shared: SharedTaskFile?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SettingsPage(background: CommaTheme.cardPrimary) {
            if model.loading, !model.loaded { ProgressView().frame(maxWidth: .infinity) }
            if model.indexing {
                SettingsSection {
                    SettingsNote(icon: "central-file-bend") { Text("Older task files are being indexed. Try refreshing shortly.") }
                    Button { Task { await model.load() } } label: { SettingsRow(Text("Refresh"), role: .action) }.buttonStyle(SurfaceRowButtonStyle())
                }
            }
            if model.loaded, !model.loading, !model.indexing, model.files.isEmpty, model.scope.error == nil {
                SettingsSection { SettingsRow(Text("No files yet")) }
            }
            if !filtered.isEmpty {
                SettingsSection(Text("Task files")) {
                    ForEach(filtered) { file in row(file) }
                }
            }
            if let cursor = model.cursor, !cursor.isEmpty {
                Button { Task { await model.load(more: true) } } label: {
                    SettingsRow(Text(model.loading ? String(localized: "Loading…") : String(localized: "Load more")), role: .action)
                }.buttonStyle(SurfaceRowButtonStyle()).disabled(model.loading)
            }
            if let error = model.scope.error { InlineError(message: error, retry: { Task { await model.load() } }) }
        }
        .pageTitle("Files")
        .sheetCloseButton { dismiss() }
        .searchable(text: $query, prompt: "Search loaded files")
        .task { await model.load() }
        .refreshable { await model.load() }
        .quickLookPreview($previewURL)
        .sheet(item: $shared) { file in TaskFileShareSheet(url: file.url) }
        .disabled(!model.current)
    }

    private var filtered: [PhoneTaskFile] { model.files.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) } }

    private func row(_ file: PhoneTaskFile) -> some View {
        HStack(spacing: GroupedSurface.groupSpacing) {
            Button { Task { previewURL = await model.prepare(file) } } label: {
                HStack(spacing: GroupedSurface.groupSpacing) {
                    CentralIcon(file.mediaType?.hasPrefix("image/") == true ? "central-images-1" : "central-file-bend", relativeTo: .title2)
                        .foregroundStyle(CommaTheme.textTertiary)
                    VStack(alignment: .leading, spacing: GroupedSurface.groupSpacing / 2) {
                        Text(file.name).font(.body).foregroundStyle(CommaTheme.textPrimary).lineLimit(2)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                            .font(.footnote).foregroundStyle(CommaTheme.textTertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if model.preparing == file.id { ProgressView() }
                }.contentShape(Rectangle())
            }.buttonStyle(SurfaceRowButtonStyle()).disabled(model.preparing != nil)
            Menu {
                Button("Preview") { Task { previewURL = await model.prepare(file) } }
                Button("Save or share…") {
                    Task { if let url = await model.prepare(file) { shared = SharedTaskFile(url: url) } }
                }
                Button("Add to context") {
                    Task { if await model.attach(file) { dismiss() } }
                }
                .disabled(model.pane.state.attachments.count >= ConversationPane.maxAttachments)
            } label: {
                CentralIcon("icon-more", relativeTo: .title2)
                    .foregroundStyle(CommaTheme.textTertiary)
                    .frame(minWidth: GroupedSurface.rowHeight, minHeight: GroupedSurface.rowHeight)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Actions for \(file.name)")
            .disabled(model.preparing != nil || model.attaching)
        }
        .surfaceRowFrame()
    }
}

private struct SharedTaskFile: Identifiable { let url: URL; var id: URL { url } }

private struct TaskFileShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
}
