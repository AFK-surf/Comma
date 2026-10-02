import SwiftUI
import PhotosUI
import QuickLook
import UniformTypeIdentifiers
import CommaCore

struct PhoneConversationView: View {
    let store: CommaStore
    @Bindable var pane: ConversationPane
    var composerFocus: FocusState<Bool>.Binding? = nil
    @State private var previewURL: URL?
    @State private var previewDirectory: URL?
    @State private var downloading = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var filePickerOpen = false
    @State private var uploading = false
    @FocusState private var composerFocused: Bool
    @State private var flight = OutgoingFlightController()
    @State private var fieldHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var focus: FocusState<Bool>.Binding { composerFocus ?? $composerFocused }

    var body: some View {
        VStack(spacing: 0) {
            if pane.loading && pane.messages.isEmpty {
                Spacer()
                ProgressView().controlSize(.regular)
                Spacer()
            } else if rows.isEmpty {
                emptyState
            } else {
                ChatTranscriptView(
                    rows: rows, isTask: pane.conversation?.isTask == true,
                    hasOlderMessages: pane.hasOlderMessages, loadingMore: pane.loadingMore,
                    flight: reduceMotion ? nil : flight,
                    onUserScroll: { focus.wrappedValue = false },
                    loadEarlier: { Task { await pane.loadEarlierMessages() } },
                    retry: { id in
                        guard let attempt = pane.pendingSends.first(where: { $0.id == id }) else { return }
                        Task { await pane.retry(attempt) }
                    },
                    openTask: { id in Task { await store.openTask(id: id) } },
                    taskSummary: store.taskSummary(id:),
                    openAttachment: { message, index, name in
                        Task { await download(messageID: message.id, index: index, name: name) }
                    })
                .id(pane.target)
            }
        }
        .animation(CommaMotion.stateChange, value: pane.error)
        .background(CommaTheme.bgPrimary)
        // Errors float over the transcript, so it keeps scrolling under the header's progressive blur.
        .overlay(alignment: .top) {
            if let error = pane.error {
                InlineError(message: error, retry: { Task { await pane.refresh() } },
                            dismiss: { pane.dismissError() })
                    .background(CommaTheme.bgPrimary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
                    .padding(.horizontal, 16).padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay(alignment: .top) {
            if downloading {
                Label("Opening attachment…", systemImage: "arrow.down.circle")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(CommaTheme.textSecondary)
                    .padding(.horizontal, 12).frame(height: 32)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 8).transition(.opacity)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .coordinateSpace(.chat)
        .overlay { OutgoingFlightOverlay(controller: flight) }
        .fileImporter(isPresented: $filePickerOpen, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            Task { await uploadFiles(result) }
        }
        .quickLookPreview($previewURL)
        .onChange(of: previewURL) { _, value in
            if value == nil, let directory = previewDirectory {
                try? FileManager.default.removeItem(at: directory)
                previewDirectory = nil
            }
        }
        .onChange(of: pane.target) { _, _ in previewURL = nil }
        .onChange(of: photos) { _, values in
            Task { await uploadPhotos(values) }
        }
    }

    private var rows: [ChatRow] {
        ChatTranscriptModel.rows(messages: pane.messages, pending: pane.currentPendingSends,
                                 draft: pane.assistantDraft, isTask: pane.conversation?.isTask == true,
                                 activity: pane.replyActivity)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            CommaMark(size: 40).foregroundStyle(CommaTheme.textPrimary)
            Text(pane.conversation?.isTask == true ? "No messages yet" : "What would you like to do?")
                .font(.system(size: 20, weight: .medium)).foregroundStyle(CommaTheme.textPrimary)
            Text("Ask a question or give Comma a task. You can follow its progress from the task list.")
                .font(.system(size: 15)).foregroundStyle(CommaTheme.textQuaternary)
                .multilineTextAlignment(.center).frame(maxWidth: 300)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .contentShape(Rectangle())
        .onTapGesture { focus.wrappedValue = false }
    }

    private var canSubmit: Bool {
        pane.canSend && !uploading &&
            !(pane.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pane.attachments.isEmpty)
    }

    /// Liquid Glass input: a separate attach button beside a field that grows line by line.
    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !pane.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(pane.attachments.enumerated()), id: \.offset) { index, attachment in
                            HStack(spacing: 5) {
                                Image(systemName: "paperclip").font(.system(size: 12))
                                Text(attachment.fields["name"]?.string ?? String(localized: "Attachment"))
                                    .font(.system(size: 13, weight: .medium)).lineLimit(1)
                                Button {
                                    withAnimation(CommaMotion.stateChange) { _ = pane.attachments.remove(at: index) }
                                } label: {
                                    Image(systemName: "xmark.circle.fill").font(.system(size: 14))
                                        .foregroundStyle(CommaTheme.textQuaternary)
                                }
                                .accessibilityLabel("Remove")
                            }
                            .foregroundStyle(CommaTheme.textSecondary)
                            .padding(.leading, 10).padding(.trailing, 6).frame(height: 30)
                            .background(CommaTheme.bgSecondary, in: Capsule())
                            .overlay(Capsule().strokeBorder(CommaTheme.borderPrimary, lineWidth: 0.5))
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    PhotosPicker(selection: $photos, maxSelectionCount: 8, matching: .images) {
                        Label("Photos", systemImage: "photo")
                    }
                    Button("Files", systemImage: "folder") { filePickerOpen = true }
                } label: {
                    Group {
                        if uploading { ProgressView().controlSize(.small) }
                        else { Image(systemName: "plus").font(.system(size: 18, weight: .medium)) }
                    }
                    .foregroundStyle(CommaTheme.textPrimary)
                    .frame(width: 44, height: 44)
                    .commaGlass(in: Circle(), interactive: true)
                    .contentShape(Circle())
                }
                .disabled(uploading || pane.target == nil)
                .accessibilityLabel("Add attachment")

                HStack(alignment: .bottom, spacing: 6) {
                    TextField("", text: $pane.draftText,
                              prompt: Text(pane.conversation?.isTask == true ? "Reply to this task" : "Message Comma")
                                .foregroundStyle(CommaTheme.textPlaceholder),
                              axis: .vertical)
                        .font(.system(size: 16)).foregroundStyle(CommaTheme.textPrimary)
                        .lineLimit(1...6).focused(focus)
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGPoint.self) { $0.frame(in: .chat).origin } action: { flight.composerTextOrigin = $0 }
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                            // The field follows each added or removed line on a short spring instead of jumping.
                            if fieldHeight == 0 { fieldHeight = height }
                            else if abs(height - fieldHeight) > 0.5 { withAnimation(CommaMotion.composerLines) { fieldHeight = height } }
                        }
                        .frame(height: fieldHeight > 0 ? fieldHeight : nil, alignment: .top)
                        .clipped()
                        .padding(.vertical, 11)
                        .padding(.leading, 16)
                        .accessibilityIdentifier("chatComposer")
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(canSubmit ? CommaTheme.brandSolid : CommaTheme.textPlaceholder, in: Circle())
                            .scaleEffect(canSubmit ? 1 : 0.92)
                            .animation(CommaMotion.stateChange, value: canSubmit)
                    }
                    .buttonStyle(TactileButtonStyle(scale: 0.9))
                    .disabled(!canSubmit)
                    .padding(.trailing, 6).padding(.bottom, 6)
                    .accessibilityLabel("Send message").accessibilityIdentifier("sendMessage")
                }
                .frame(minHeight: 44)
                .commaGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous), interactive: true)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .chat) } action: { flight.composerFrame = $0 }
            }
            .commaGlassGroup(spacing: 8)
        }
        .animation(CommaMotion.stateChange, value: pane.attachments.count)
        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 8)
    }

    /// The composer surface lifts off as the sent bubble; delivery runs underneath it.
    private func send() {
        guard canSubmit, let attempt = pane.enqueueSend() else { return }
        if !reduceMotion, !attempt.text.isEmpty { flight.launch(id: attempt.id, text: attempt.text) }
        Task { await pane.deliver(attempt) }
    }

    private func download(messageID: String, index: Int, name: String) async {
        guard let target = pane.target, !downloading, previewURL == nil else { return }
        let sessionID = store.session?.id
        downloading = true
        defer { downloading = false }
        do {
            let file = try await store.client.download(target: target, messageID: messageID, index: index)
            guard pane.target == target, store.session?.id == sessionID, sessionID != nil else { return }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("comma-preview-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let filename = String((name as NSString).lastPathComponent.prefix(150))
            let url = directory.appendingPathComponent(filename.isEmpty ? "Attachment" : filename)
            try file.data.write(to: url, options: .atomic)
            previewDirectory = directory
            previewURL = url
        } catch { pane.showError(error.localizedDescription) }
    }

    private func uploadPhotos(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        uploading = true
        defer { uploading = false; photos = [] }
        for item in items {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                let type = item.supportedContentTypes.first ?? .jpeg
                try await pane.attachFile(filename: "Photo." + (type.preferredFilenameExtension ?? "jpg"),
                                           contentType: type.preferredMIMEType ?? "image/jpeg", data: data)
            } catch { pane.showError(error.localizedDescription); break }
        }
    }

    private func uploadFiles(_ result: Result<[URL], any Error>) async {
        uploading = true
        defer { uploading = false }
        do {
            for url in try result.get() {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey, .isRegularFileKey])
                guard values.isRegularFile == true, (values.fileSize ?? 0) <= 10_000_000 else {
                    pane.showError("Choose a file smaller than 10 MB.")
                    return
                }
                let data = try Data(contentsOf: url)
                try await pane.attachFile(filename: url.lastPathComponent,
                                           contentType: values.contentType?.preferredMIMEType ?? "application/octet-stream", data: data)
            }
        } catch { pane.showError(error.localizedDescription) }
    }
}

extension View {
    /// Liquid Glass on iOS 26 and later; a translucent material with a hairline on earlier systems.
    @ViewBuilder func commaGlass<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
                .overlay(shape.stroke(CommaTheme.borderPrimary.opacity(0.7), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.06), radius: 10, y: 3)
        }
    }

    /// Lets neighbouring glass shapes blend and morph together on iOS 26 and later.
    @ViewBuilder func commaGlassGroup(spacing: CGFloat) -> some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { self }
        } else {
            self
        }
    }
}
