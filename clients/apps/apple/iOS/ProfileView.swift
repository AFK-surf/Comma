import SwiftUI
import PhotosUI
import UIKit
import CommaCore

/// The member's photo, or their initials until a photo loads or when there is none.
struct UserAvatar: View {
    let store: CommaStore
    let size: CGFloat

    var body: some View {
        Group {
            if let data = store.avatarData, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Text(initials).font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(CommaTheme.brandSolid)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    private var initials: String {
        let source = store.profile?.name ?? store.session?.user.name ?? store.session?.user.email ?? "C"
        return String(source.split(separator: " ").prefix(2).compactMap(\.first)).uppercased()
    }
}

/// Name and photo. The name is shared with every device and shown to collaborators.
struct ProfileView: View {
    let store: CommaStore
    @State private var name = ""
    @State private var photo: PhotosPickerItem?
    @State private var busy = false
    @State private var error: String?
    @State private var saved = false

    var body: some View {
        Form {
            Section {
                HStack {
                    Spacer()
                    VStack(spacing: 12) {
                        UserAvatar(store: store, size: 88)
                        HStack(spacing: 16) {
                            PhotosPicker(selection: $photo, matching: .images) {
                                Text(store.profile?.avatarID == nil ? "Add photo" : "Change photo")
                            }
                            if store.profile?.avatarID != nil {
                                Button("Remove", role: .destructive) { run { try await store.removeAvatar() } }
                            }
                        }
                        .buttonStyle(.borderless)
                        .font(.subheadline)
                    }
                    Spacer()
                }
                .listRowBackground(Color.clear)
            }
            Section {
                TextField("Name", text: $name)
                    .textContentType(.name)
                    .submitLabel(.done)
                    .onSubmit(saveName)
                    .onChange(of: name) { _, _ in saved = false }
                LabeledContent("Email", value: store.profile?.email ?? store.session?.user.email ?? "")
            } footer: {
                Text("Your name and photo are shown to people you work with in Comma.")
            }
            Section {
                Button(saved ? "Saved" : "Save name", action: saveName)
                    .disabled(!nameChanged || trimmed.isEmpty || trimmed.count > UserProfile.maxNameLength)
            }
            if let error {
                Section { Text(error).foregroundStyle(CommaTheme.errorPrimary) }
            }
        }
        .disabled(busy)
        .tint(CommaTheme.brandSolid)
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await store.loadProfile()
            if name.isEmpty { name = store.profile?.name ?? store.session?.user.name ?? "" }
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            photo = nil
            run {
                guard let data = try await item.loadTransferable(type: Data.self) else { throw CommaError.invalidInput("That photo couldn’t be read.") }
                let jpeg = try Self.avatarJPEG(from: data)
                try await store.uploadAvatar(jpeg, contentType: "image/jpeg")
            }
        }
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var nameChanged: Bool { trimmed != (store.profile?.name ?? store.session?.user.name ?? "") }

    private func saveName() {
        guard nameChanged, !trimmed.isEmpty else { return }
        run { try await store.updateProfile(name: trimmed); saved = true }
    }

    private func run(_ operation: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true; error = nil
        Task {
            defer { busy = false }
            do { try await operation() } catch { self.error = error.localizedDescription }
        }
    }

    /// A centred square, at most 512 points, as JPEG under the 2 MB server limit.
    static func avatarJPEG(from data: Data) throws -> Data {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else {
            throw CommaError.invalidInput("That photo couldn’t be read.")
        }
        let side = min(image.size.width, image.size.height)
        let target = min(512, side)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: CGSize(width: target, height: target), format: format).image { _ in
            let scale = target / side
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(x: (target - size.width) / 2, y: (target - size.height) / 2, width: size.width, height: size.height))
        }
        for quality in [0.85, 0.7, 0.5] {
            if let jpeg = rendered.jpegData(compressionQuality: quality), jpeg.count <= UserProfile.maxAvatarBytes { return jpeg }
        }
        throw CommaError.invalidInput("That photo is too large.")
    }
}

/// The member's signed-in devices. Signing out another device also signs out the Apple Watch paired from it.
struct SessionsView: View {
    let store: CommaStore
    @State private var sessions: [AuthSessionRecord] = []
    @State private var cursor: String?
    @State private var hasMore = false
    @State private var loaded = false
    @State private var busy = false
    @State private var error: String?
    @State private var notice: String?
    @State private var confirmingAll = false

    var body: some View {
        let active = sessions.filter { $0.isActive() }
        let currentID = store.session?.id
        Form {
            if !loaded {
                Section { ProgressView().frame(maxWidth: .infinity) }
            }
            if let current = active.first(where: { $0.id == currentID }) {
                Section("This device") { SessionRow(session: current, current: true) }
            }
            let others = active.filter { $0.id != currentID }
            if loaded {
                Section {
                    if others.isEmpty {
                        Text("No other devices are signed in.").foregroundStyle(CommaTheme.textQuaternary)
                    }
                    ForEach(others) { session in
                        SessionRow(session: session, current: false)
                            .swipeActions {
                                Button("Sign out", role: .destructive) { revoke(session) }
                            }
                            .contextMenu {
                                Button("Sign out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { revoke(session) }
                            }
                    }
                    if hasMore {
                        Button("Show more") { Task { await load(more: true) } }
                    }
                } header: {
                    Text("Other devices")
                } footer: {
                    Text("Signing out a device also signs out the Apple Watch connected through it.")
                }
                if !others.isEmpty {
                    Section {
                        Button("Sign out all other devices", role: .destructive) { confirmingAll = true }
                    }
                }
            }
            if let notice {
                Section { Text(notice).foregroundStyle(CommaTheme.textTertiary) }
            }
            if let error {
                Section { Text(error).foregroundStyle(CommaTheme.errorPrimary) }
            }
        }
        .disabled(busy)
        .tint(CommaTheme.brandSolid)
        .navigationTitle("Signed-in devices")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load(more: false) }
        .task { await load(more: false) }
        .confirmationDialog("Sign out all other devices?", isPresented: $confirmingAll, titleVisibility: .visible) {
            Button("Sign out all other devices", role: .destructive) {
                run {
                    let count = try await store.client.revokeOtherAuthSessions()
                    notice = String(localized: "Signed out \(count) sessions.")
                }
            }
        } message: {
            Text("This iPhone stays signed in.")
        }
    }

    private func revoke(_ session: AuthSessionRecord) {
        run { try await store.client.revokeAuthSession(id: session.id) }
    }

    private func run(_ operation: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true; error = nil; notice = nil
        Task {
            defer { busy = false }
            do {
                try await operation()
                await load(more: false)
            } catch { self.error = error.localizedDescription }
        }
    }

    private func load(more: Bool) async {
        guard !more || cursor != nil else { return }
        do {
            let page = try await store.client.authSessions(cursor: more ? cursor : nil)
            var known = more ? Set(sessions.map(\.id)) : []
            sessions = (more ? sessions : []) + page.data.filter { known.insert($0.id).inserted }
            cursor = page.nextCursor
            hasMore = page.hasMore == true
            error = nil
        } catch { self.error = error.localizedDescription }
        loaded = true
    }
}

private struct SessionRow: View {
    let session: AuthSessionRecord
    let current: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(CommaTheme.textSecondary).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body)
                Text(detail).font(.footnote).foregroundStyle(CommaTheme.textQuaternary)
            }
        }
        .padding(.vertical, 2)
    }

    private var symbol: String {
        switch session.clientKind {
        case "watch": "applewatch"
        case "ios": "iphone"
        case "web": "globe"
        case "ssh", "api": "terminal"
        default: "laptopcomputer"
        }
    }

    private var title: String {
        if let label = session.deviceLabel, !label.isEmpty { return label }
        switch session.clientKind {
        case "watch": return "Apple Watch"
        case "ios": return session.clientPlatform == "ipados" ? "iPad" : "iPhone"
        case "web": return String(localized: "Web browser")
        case "ssh": return String(localized: "Command line")
        case "api": return "API"
        case "electron":
            switch session.clientPlatform {
            case "windows": return String(localized: "Comma for Windows")
            case "linux": return String(localized: "Comma for Linux")
            default: return String(localized: "Comma for Mac")
            }
        default: return String(localized: "Unknown device")
        }
    }

    private var detail: String {
        if current { return String(localized: "Active now") }
        guard let seen = session.lastSeenAt ?? session.authenticatedAt else { return "" }
        let date = Date(timeIntervalSince1970: seen > 100_000_000_000 ? seen / 1000 : seen)
        return String(localized: "Last active \(date.formatted(.relative(presentation: .named)))")
    }
}
