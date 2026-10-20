import SwiftUI
import PhotosUI
import CommaCore

/// The member's photo at the top of Profile. Tapping it, or Edit under it, offers taking a photo, choosing one
/// or taking it down, as Contacts does; with nothing but the library to offer, it opens the library at once. A
/// new photo goes through Move and Scale, then shows everywhere at once while it uploads; a failed upload keeps
/// the photo for a retry.
struct ProfilePhotoHeader: View {
    let store: CommaStore
    /// The name being typed, whose initials the avatar previews.
    let draftName: String?
    @State private var picking = false
    @State private var item: PhotosPickerItem?
    /// The camera, then Move and Scale, in one cover so the camera hands its photo straight on.
    @State private var flow: PhotoFlow?
    @State private var working = false
    @State private var failure: PhotoFailure?
    /// Count finished changes, for a success or error tap.
    @State private var successes = 0
    @State private var failures = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A photo is shown, or is still downloading.
    private var hasPhoto: Bool { store.avatarData != nil || store.profile?.avatarID != nil }

    var body: some View {
        VStack(spacing: 12) {
            Group {
                if hasPhoto || CameraPicker.available {
                    Menu {
                        if CameraPicker.available {
                            Button { flow = PhotoFlow() } label: { Label("Take Photo", image: "icon-camera") }
                        }
                        Button { picking = true } label: { Label("Choose Photo…", image: "central-images-1") }
                        if hasPhoto {
                            Button(role: .destructive, action: remove) {
                                Label { Text("Remove Photo") } icon: { MenuIcon.destructive("central-trash-can") }
                            }
                        }
                    } label: { face }
                } else {
                    Button { picking = true } label: { face }
                }
            }
            .buttonStyle(TactileButtonStyle())
            .disabled(working)
            .accessibilityLabel(Text("Profile photo"))
            .accessibilityValue(working ? Text("Updating") : Text(verbatim: ""))
            .accessibilityHint(hasPhoto ? Text("Changes or removes your photo") : Text("Adds a photo"))
            if let failure {
                InlineError(message: failure.message, retry: failure.retry, dismiss: { self.failure = nil })
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .animation(CommaMotion.settle(reduced: reduceMotion), value: failure?.message)
        .animation(CommaMotion.stateChange, value: working)
        .sensoryFeedback(.success, trigger: successes)
        .sensoryFeedback(.error, trigger: failures)
        .photosPicker(isPresented: $picking, selection: $item, matching: .images, preferredItemEncoding: .current)
        .onChange(of: item) { _, picked in
            guard let picked else { return }
            item = nil
            open(picked)
        }
        .fullScreenCover(item: $flow) { current in
            if let image = current.image {
                AvatarCropView(image: image) { crop in
                    flow = nil
                    upload(image, crop: crop)
                } cancel: {
                    flow = nil
                }
            } else {
                CameraPicker { taken in
                    Task { await frame(taken) }
                } cancel: {
                    flow = nil
                }
                .ignoresSafeArea()
            }
        }
    }

    /// The photo and the word under it, which open the choices.
    private var face: some View {
        VStack(spacing: 8) {
            UserAvatar(store: store, size: 96, name: draftName)
                .overlay { if working { progress } }
            Text(hasPhoto ? "Edit" : "Add Photo").font(.body).foregroundStyle(CommaTheme.brandSolid)
                .frame(minHeight: 32)
        }
        .contentShape(Rectangle())
    }

    private var progress: some View {
        ZStack {
            Circle().fill(.black.opacity(0.35))
            ProgressView().tint(.white)
        }
        .transition(.opacity)
    }

    /// Reads the picked photo and puts it in Move and Scale.
    private func open(_ picked: PhotosPickerItem) {
        failure = nil
        Task {
            do {
                guard let data = try await picked.loadTransferable(type: Data.self) else {
                    throw CommaError.invalidInput(String(localized: "That photo couldn’t be read."))
                }
                flow = PhotoFlow(image: try await AvatarImage.load(data))
            } catch {
                fail(PhotoFailure(message: error.localizedDescription, retry: nil))
            }
        }
    }

    /// The camera's photo, at Move and Scale's working size, framed in the same cover.
    private func frame(_ taken: UIImage) async {
        guard let image = try? await AvatarImage.load(taken) else {
            flow = nil
            return fail(PhotoFailure(message: String(localized: "That photo couldn’t be read."), retry: nil))
        }
        flow?.image = image
    }

    private func fail(_ next: PhotoFailure) {
        failure = next
        failures += 1
    }

    private func upload(_ image: UIImage, crop: CGRect) {
        working = true
        failure = nil
        Task {
            do {
                send(try await AvatarImage.jpeg(from: image, crop: crop))
            } catch {
                working = false
                fail(PhotoFailure(message: error.localizedDescription, retry: nil))
            }
        }
    }

    private func send(_ jpeg: Data) {
        attempt(String(localized: "Couldn’t update your photo."), done: String(localized: "Photo updated"),
                retry: { send(jpeg) }) {
            try await store.uploadAvatar(jpeg, contentType: "image/jpeg")
        }
    }

    private func remove() {
        attempt(String(localized: "Couldn’t remove your photo."), done: String(localized: "Photo removed"),
                retry: remove) {
            try await store.removeAvatar()
        }
    }

    /// Runs a change to the photo with the spinner on it, announcing `done`, or keeping `message` and a retry.
    private func attempt(_ message: String, done: String, retry: @escaping () -> Void,
                         _ change: @escaping () async throws -> Void) {
        working = true
        failure = nil
        Task {
            defer { working = false }
            do {
                try await change()
                successes += 1
                AccessibilityNotification.Announcement(done).post()
            } catch is CancellationError {
            } catch {
                fail(PhotoFailure(message: message, retry: retry))
            }
        }
    }
}

/// A new photo on its way to Move and Scale: none yet while the camera is open.
private struct PhotoFlow: Identifiable {
    let id = UUID()
    var image: UIImage?
}

/// What went wrong with the photo, and how to try again when trying again can help.
private struct PhotoFailure {
    let message: String
    let retry: (() -> Void)?
}
