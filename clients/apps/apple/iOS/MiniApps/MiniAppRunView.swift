import SwiftUI
import WebKit
import PhotosUI
import AVFoundation
import UniformTypeIdentifiers
import ImageIO

/// The restricted runtime shared by Apps and chat previews. Publication stays in trusted host controls.
struct MiniAppRunView: View {
    let store: CommaStore
    let target: MiniAppTarget
    @State private var session: MiniAppSession
    @State private var management: MiniAppsModel?
    @State private var publishing = false
    @State private var runID = UUID()
    @State private var sideStatusBar = false
    @Environment(AppNavigation.self) private var navigation: AppNavigation?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    init(store: CommaStore, target: MiniAppTarget, session: MiniAppSession? = nil) {
        self.store = store
        let execution = session ?? store.retainedMiniApp(for: target) ?? MiniAppSession(core: store.core, target: target)
        self.target = target
        _session = State(initialValue: execution)
        _management = State(initialValue: self.target.publication == nil ? nil : store.workspace.map { MiniAppsModel(store: store, workspace: $0) })
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                if !session.immersive && !sideStatusBar { header }
                Color.clear
                    .overlay {
                        Group {
                            if #available(iOS 18.4, *) { runtime.id(runID) }
                            else { EmptyState(Text("iOS update required"), icon: "central-exclamation-triangle", description: Text("Apps require iOS 18.4 or later.")) }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .ignoresSafeArea(.container, edges: session.immersive ? .all : .bottom)
                    }
            }
            .overlay(alignment: .topLeading) {
                if session.immersive { controls.padding(GroupedSurface.radius) }
            }
            .overlay(alignment: .bottomTrailing) {
                if !session.immersive && sideStatusBar {
                    controls
                        .padding(.bottom, GroupedSurface.radius)
                        .offset(x: (geometry.safeAreaInsets.trailing + 44) / 2)
                }
            }
            .onChange(of: geometry.safeAreaInsets, initial: true) { _, insets in
                // A side status rail reserves asymmetric trailing space. Notched phones in landscape
                // reserve symmetric horizontal insets; the legacy statusBarFrame is not the rail's frame.
                sideStatusBar = insets.trailing > max(insets.leading, insets.top)
            }
        }
        .background(CommaTheme.bgPrimary.ignoresSafeArea())
        .background { MiniAppBackGesture(back: suspend) }
        .modifier(MiniAppImmersiveChrome(immersive: session.immersive))
        .task { await management?.followApp(target.appID) }
        .task(id: management?.app?.id) { await management?.followReview(target.publication?.conversationID) }
        .sheet(isPresented: $publishing) {
            if let management, let publication = target.publication { MiniAppPublishView(model: management, publication: publication) }
        }
        .sheet(item: Binding(get: { session.photoRequest }, set: { if $0 == nil { session.cancelPhotoRequest() } })) { request in
            MiniAppPhotoSheet(request: request, appName: session.name,
                share: { session.finishPhotoRequest(id: request.id, assets: $0) },
                cancel: { session.cancelPhotoRequest(id: request.id) })
                .id(request.id)
                .onDisappear { session.cancelPhotoRequest(id: request.id) }
        }
        .sheet(item: Binding(get: { session.hostRequest }, set: { if $0 == nil { session.cancelHostRequest() } })) { request in
            MiniAppHostPermissionSheet(session: session, request: request).commaSheet([.medium, .large])
                .onDisappear { session.finishHostRequest(id: request.id, approved: false) }
        }
        .onAppear {
            let boundary = store.boundaryToken
            let workspace = store.workspace?.id
            let pane = (navigation?.taskRaised == true ? store.task : nil) ?? store.router.pane
            session.draftHandler = { [weak store, weak pane] text in
                guard let store, let pane, store.isCurrent(boundary), store.workspace?.id == workspace, !pane.closed else { throw CancellationError() }
                pane.fillDraft(text)
            }
            session.resume()
        }
        .onDisappear {
            if session.canContinue { session.suspend() }
            else { store.closeMiniApp(session, target: target) }
        }
        .onChange(of: store.workspace?.id) { _, _ in session.stop(); dismiss() }
        .onChange(of: store.boundaryToken) { _, _ in session.stop(); dismiss() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { session.suspend() }
            else if phase == .active { session.resume() }
        }
    }

    private var header: some View {
        HStack(spacing: GroupedSurface.margin) {
            controls
            Spacer(minLength: 0)
            VStack(spacing: 2) {
                Text(session.name).font(.headline).lineLimit(1)
                if let version = session.version {
                    Text("v\(version)").font(.caption).foregroundStyle(CommaTheme.textSecondary)
                }
            }
            Spacer(minLength: 0)
            Color.clear.frame(width: 89, height: 44).accessibilityHidden(true)
        }
        .padding(.horizontal, GroupedSurface.margin)
        .padding(.vertical, GroupedSurface.margin)
        .background(CommaTheme.bgPrimary)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mini-app-header")
    }

    private var canPublish: Bool {
        guard session.ready, let publication = target.publication, let management,
              let version = management.versions.first(where: { $0.number == publication.version }) else { return false }
        return management.publication(for: version) == publication
    }

    @ViewBuilder private var controls: some View {
        if #available(iOS 26.0, *) {
            buttons.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            buttons.background(.regularMaterial, in: Capsule())
        }
    }

    private var buttons: some View {
        let sidebar = !session.immersive && sideStatusBar
        return (sidebar ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))) {
            Button(action: suspend) {
                CentralIcon("central-chevron-right-small", size: 20).rotationEffect(.degrees(180))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Back")
            .accessibilityIdentifier("mini-app-back")
            Divider().frame(width: sidebar ? 20 : nil, height: sidebar ? nil : 20)
            Menu {
                Text(session.name)
                if let version = session.version { Text("v\(version)") }
                Toggle("Immersive mode", isOn: $session.immersive)
                    .accessibilityIdentifier("mini-app-immersive")
                Button("Reload app", action: reload).accessibilityIdentifier("mini-app-reload")
                if canPublish { Button("Publish") { publishing = true } }
                Divider()
                Button("Close app", role: .destructive, action: close).accessibilityIdentifier("mini-app-close")
            } label: {
                CentralIcon("icon-more", size: 20).frame(width: 44, height: 44)
            }
            .accessibilityLabel("App menu")
            .accessibilityIdentifier("mini-app-menu")
        }
        .foregroundStyle(CommaTheme.textPrimary)
        .buttonStyle(.plain)
    }

    private func suspend() {
        session.suspend()
        dismiss()
    }

    private func close() { store.closeMiniApp(session, target: target); dismiss() }

    private func reload() {
        let immersive = session.immersive
        store.closeMiniApp(session, target: target)
        session = MiniAppSession(core: store.core, target: target)
        session.immersive = immersive
        runID = UUID()
    }

    @available(iOS 18.4, *)
    private var runtime: some View {
        MiniAppRuntimeSurface(session: session)
            .task {
                store.retainMiniApp(session, target: target)
                await session.open(target)
                session.resume()
            }
            .alert("Run this app?", isPresented: $session.needsConsent) {
                Button("Run") { session.approve() }
                Button("Cancel", role: .cancel) { session.stop(); dismiss() }
            } message: {
                Text("This app can send what you enter to its backend, save cloud data, and use AI and web search. AI and search may use your workspace credits. Profile information, the app’s Drive folder, and notifications require separate approval. Photos are shared only after you choose and confirm them.")
            }
    }
}

@available(iOS 18.4, *)
private struct MiniAppRuntimeSurface: View {
    let session: MiniAppSession
    @Environment(\.colorScheme) private var colorScheme
    @State private var host: MiniAppWebHost?

    var body: some View {
        ZStack {
            if let host { MiniAppWebView(host: host) }
            if let failure = session.failure {
                EmptyState(Text("App unavailable"), icon: "central-exclamation-triangle", description: Text(verbatim: failure))
            } else if !session.ready { ProgressView("Loading app…") }
        }
        .onChange(of: session.canRun, initial: true) { _, running in
            guard running else { host = nil; return }
            if let retained = session.runtime as? MiniAppWebHost {
                host = retained
                Task { await retained.updateTheme(dark: colorScheme == .dark) }
                return
            }
            do {
                let created = try MiniAppWebHost(session: session, dark: colorScheme == .dark)
                session.runtime = created; host = created; created.load()
            }
            catch { session.failed(error) }
        }
        .onChange(of: colorScheme) { _, scheme in Task { await host?.updateTheme(dark: scheme == .dark) } }
    }
}

@available(iOS 18.4, *)
private struct MiniAppWebView: UIViewRepresentable {
    let host: MiniAppWebHost
    func makeUIView(context: Context) -> WKWebView { host.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}

}

/// Preferences belong to the presented run screen; dismissing it restores the presenting shell.
private struct MiniAppImmersiveChrome: ViewModifier {
    let immersive: Bool
    @State private var active = true
    private var hidden: Bool { active && immersive }

    func body(content: Content) -> some View {
        visibility(content)
            .persistentSystemOverlays(hidden ? .hidden : .visible)
            .onAppear { active = true }
            .onDisappear { active = false }
    }

    @ViewBuilder private func visibility(_ content: Content) -> some View {
        if #available(iOS 27.0, *) {
            content.toolbarVisibility(hidden ? .hidden : .visible, for: .statusBar)
        } else {
            content.statusBarHidden(hidden)
        }
    }
}

/// A native left-edge recognizer belongs only to the presented runtime's hosting view.
private struct MiniAppBackGesture: UIViewRepresentable {
    let back: () -> Void
    func makeUIView(context: Context) -> BackView { BackView(back: back) }
    func updateUIView(_ view: BackView, context: Context) { view.back = back }
    static func dismantleUIView(_ view: BackView, coordinator: ()) { view.detach() }

    final class BackView: UIView {
        var back: () -> Void
        private var edge: UIScreenEdgePanGestureRecognizer?
        private weak var owner: UIView?
        init(back: @escaping () -> Void) { self.back = back; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            detach()
            guard window != nil else { return }
            var responder: UIResponder? = self
            var parent: UIView?
            while let current = responder {
                if let controller = current as? UIViewController { parent = controller.view; break }
                responder = current.next
            }
            guard let parent else { return }
            let edge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(panned(_:)))
            edge.edges = .left
            edge.cancelsTouchesInView = false
            parent.addGestureRecognizer(edge)
            owner = parent; self.edge = edge
        }
        func detach() { if let edge { owner?.removeGestureRecognizer(edge) }; edge = nil; owner = nil }
        @objc private func panned(_ edge: UIScreenEdgePanGestureRecognizer) {
            let delta = edge.translation(in: owner)
            if edge.state == .ended, delta.x > 80, delta.x > abs(delta.y) * 1.5 { back() }
        }
    }
}

private struct MiniAppPhotoSheet: View {
    let request: MiniAppPhotoRequest
    let appName: String
    let share: ([MiniAppPhotoAsset]) -> Void
    let cancel: () -> Void
    @State private var assets: [MiniAppPhotoAsset] = []
    @State private var library = false
    @State private var camera = false
    @State private var requestingCamera = false
    @State private var active = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: GroupedSurface.margin) {
                    Text("Send to \(appName)").font(.headline)
                    Text("Only the photos you confirm here will be shared with this app.")
                        .foregroundStyle(CommaTheme.textSecondary)
                    if let failure { Text(verbatim: failure).foregroundStyle(CommaTheme.errorPrimary) }
                    if !assets.isEmpty {
                        ScrollView(.horizontal) {
                            HStack {
                                ForEach(assets.indices, id: \.self) { index in
                                    if let image = UIImage(data: assets[index].data) {
                                        Image(uiImage: image).resizable().scaledToFill()
                                            .frame(width: 96, height: 96).clipped()
                                            .clipShape(RoundedRectangle(cornerRadius: GroupedSurface.radius))
                                    }
                                }
                            }
                        }
                        Button("Share selected photos") { share(assets) }
                            .buttonStyle(CommaButtonStyle())
                            .accessibilityIdentifier("mini-app-photo-share")
                    }
                    Button("Choose photos") { failure = nil; library = true }
                        .buttonStyle(CommaButtonStyle(hierarchy: .secondary))
                        .accessibilityIdentifier("mini-app-photo-library")
                    if CameraPicker.available {
                        Button("Take photo") { Task { await openCamera() } }
                            .buttonStyle(CommaButtonStyle(hierarchy: .secondary))
                            .disabled(requestingCamera)
                            .accessibilityIdentifier("mini-app-photo-camera")
                    } else {
                        Text("Camera unavailable on this device.").font(.caption).foregroundStyle(CommaTheme.textSecondary)
                    }
                }
                .padding(GroupedSurface.margin)
            }
            .background(CommaTheme.bgPrimary)
            .onAppear { active = true }
            .onDisappear { active = false }
            .navigationTitle("Share photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) } }
            .sheet(isPresented: $library) {
                MiniAppLibraryPicker(request: request) { result in
                    library = false
                    switch result {
                    case .success(let picked):
                        guard picked.reduce(0, { $0 + $1.data.count }) <= 8 * 1024 * 1024 else {
                            assets = []; failure = String(localized: "Select fewer photos. The total limit is 8 MB."); return
                        }
                        assets = picked
                    case .failure: assets = []; failure = String(localized: "The selected photos could not be loaded. Try other photos.")
                    }
                }.ignoresSafeArea()
            }
            .sheet(isPresented: $camera) {
                CameraPicker(take: { image in
                    camera = false
                    do { assets = [try MiniAppPhotoEncoding.camera(image, png: request.png)] }
                    catch { failure = String(localized: "The photo could not be prepared. Try again.") }
                }, cancel: { camera = false }, preferredDevice: .rear).ignoresSafeArea()
            }
        }
    }

    private func openCamera() async {
        requestingCamera = true
        defer { requestingCamera = false }
        let allowed: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: allowed = true
        case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .video)
        default: allowed = false
        }
        guard active, !Task.isCancelled else { return }
        if allowed { failure = nil; camera = true }
        else { failure = String(localized: "Allow camera access in Settings to take a photo.") }
    }
}

private struct MiniAppLibraryPicker: UIViewControllerRepresentable {
    let request: MiniAppPhotoRequest
    let complete: (Result<[MiniAppPhotoAsset], Error>) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(request: request, complete: complete) }
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = request.multiple ? 6 : 1
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}
    static func dismantleUIViewController(_ controller: PHPickerViewController, coordinator: Coordinator) { coordinator.cancel() }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let request: MiniAppPhotoRequest
        let complete: (Result<[MiniAppPhotoAsset], Error>) -> Void
        private var progress: [MiniAppPhotoLoad] = []
        private var cancelled = false
        init(request: MiniAppPhotoRequest, complete: @escaping (Result<[MiniAppPhotoAsset], Error>) -> Void) {
            self.request = request; self.complete = complete
        }
        func cancel() { cancelled = true; for task in progress { task.cancel() }; progress = [] }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard !results.isEmpty else { complete(.success([])); return }
            let png = request.png
            Task {
                do {
                    var assets: [MiniAppPhotoAsset] = []
                    for result in results.prefix(request.multiple ? 6 : 1) {
                        guard !cancelled else { return }
                        let load = MiniAppPhotoLoad()
                        progress.append(load)
                        let asset: MiniAppPhotoAsset = try await withCheckedThrowingContinuation { reply in
                            load.start(result.itemProvider, png: png, reply: reply)
                        }
                        assets.append(asset)
                        guard assets.reduce(0, { $0 + $1.data.count }) <= 8 * 1024 * 1024 else {
                            throw CoreError(code: "quota_exceeded", message: "Select fewer photos.")
                        }
                    }
                    if !cancelled { complete(.success(assets)) }
                } catch { if !cancelled { complete(.failure(error)) } }
            }
        }
    }
}

/// The provider can invoke its cancellation handler after completion. Take the continuation exactly once.
private final class MiniAppPhotoLoad: @unchecked Sendable {
    private let lock = NSLock()
    private var reply: CheckedContinuation<MiniAppPhotoAsset, Error>?
    private var progress: Progress?
    private var cancelled = false

    func start(_ provider: NSItemProvider, png: Bool, reply: CheckedContinuation<MiniAppPhotoAsset, Error>) {
        guard lock.withLock({
            if !cancelled { self.reply = reply }
            return !cancelled
        }) else { reply.resume(throwing: CancellationError()); return }
        let progress = provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { [self] url, error in
            guard let reply = take() else { return }
            do {
                guard let url else { throw error ?? CoreError(code: "unavailable", message: "The photo is unavailable.") }
                reply.resume(returning: try MiniAppPhotoEncoding.file(url, png: png))
            } catch { reply.resume(throwing: error) }
        }
        if lock.withLock({ self.progress = progress; return cancelled }) { progress.cancel() }
    }

    func cancel() {
        let progress = lock.withLock { cancelled = true; defer { self.progress = nil }; return self.progress }
        take()?.resume(throwing: CancellationError())
        progress?.cancel()
    }

    private func take() -> CheckedContinuation<MiniAppPhotoAsset, Error>? {
        lock.withLock { defer { reply = nil }; return reply }
    }
}

/// New image encodings omit source EXIF and library identifiers. Decode work stays at preview-sized dimensions.
enum MiniAppPhotoEncoding {
    nonisolated static func file(_ url: URL, png: Bool) throws -> MiniAppPhotoAsset {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= 32 * 1024 * 1024,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048,
                kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { throw CoreError(code: "invalid", message: "The photo could not be loaded.") }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, (png ? UTType.png.identifier : UTType.jpeg.identifier) as CFString, 1, nil) else {
            throw CoreError(code: "failed", message: "The photo could not be encoded.")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination), data.length <= 4 * 1024 * 1024 else {
            throw CoreError(code: "quota_exceeded", message: "The photo is too large.")
        }
        return MiniAppPhotoAsset(data: data as Data, png: png)
    }

    static func camera(_ image: UIImage, png: Bool) throws -> MiniAppPhotoAsset {
        let factor = min(1, 2048 / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * factor, height: image.size.height * factor)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let data = png ? resized.pngData() : resized.jpegData(compressionQuality: 0.8), data.count <= 4 * 1024 * 1024 else {
            throw CoreError(code: "quota_exceeded", message: "The photo is too large.")
        }
        return MiniAppPhotoAsset(data: data, png: png)
    }
}

struct MiniAppHostPermissionSheet: View {
    let session: MiniAppSession
    let request: MiniAppHostRequest
    var body: some View {
        NavigationStack {
            SettingsPage(background: CommaTheme.cardPrimary) {
                SettingsSection(Text(verbatim: session.name)) {
                    Text(verbatim: request.title).font(.headline).surfaceRowFrame()
                    if !request.detail.isEmpty { Text(verbatim: request.detail).textSelection(.enabled).surfaceRowFrame() }
                    Button("Allow") { session.finishHostRequest(id: request.id, approved: true) }.surfaceRowFrame()
                    Button("Cancel", role: .cancel) { session.finishHostRequest(id: request.id, approved: false) }.surfaceRowFrame()
                }
            }.pageTitle("App request")
        }
    }
}
