import SwiftUI
import CommaCore

/// The member's name and email. The name saves the way iOS saves one: when the member presses Done, leaves the
/// field or leaves the page. There is no Save button; the row shows the save as it happens, a spinner and then
/// a tick, and an emptied name goes back to the saved one. One save runs at a time, and the field stays editable:
/// a name asked to be saved while another saves goes as soon as that one ends, so no edit is lost.
struct ProfileNameSection: View {
    let store: CommaStore
    @Binding var draft: String
    @State private var save = NameSave.idle
    /// A save asked for while another was under way, to run once it ends: true when the page was being left.
    @State private var queued: Bool?
    @FocusState private var focused: Bool
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The counter appears this close to the limit.
    private static let countdown = 10

    var body: some View {
        Group {
            details
            if case .failed(let message) = save {
                InlineError(message: message, retry: { commit() }, dismiss: { save = .idle })
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(CommaMotion.settle(reduced: reduceMotion), value: save)
    }

    private var details: some View {
        SettingsSection {
            nameRow
            SettingsRow(Text("Email"), value: Text(store.memberEmail))
                .truncationMode(.middle)
                .textSelection(.enabled)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Your name and photo are shown to people you work with in Comma.")
                if remaining <= Self.countdown {
                    Text("^[\(remaining) character](inflect: true) left").monospacedDigit()
                }
            }
        }
    }

    private var nameRow: some View {
        let stacked = typeSize.isAccessibilitySize
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(spacing: 16))
        return HStack(spacing: 8) {
            layout {
                // The field carries the name for VoiceOver, so the label is not read twice.
                Text("Name").font(.body).foregroundStyle(CommaTheme.textPrimary).fixedSize()
                    .accessibilityHidden(true)
                    .onTapGesture { focused = true }
                TextField("Name", text: $draft, prompt: Text("Add your name"))
                    .font(.body).foregroundStyle(CommaTheme.textSecondary)
                    .multilineTextAlignment(stacked ? .leading : .trailing)
                    .textContentType(.name)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($focused)
                    .onSubmit { commit() }
                    .accessibilityIdentifier("profileName")
            }
            status
        }
        .surfaceRowFrame()
        .sensoryFeedback(.success, trigger: save) { _, now in now == .saved }
        .onChange(of: draft) { _, value in
            if value.count > UserProfile.maxNameLength { draft = String(value.prefix(UserProfile.maxNameLength)) }
            // An edit after a save clears the tick; the saved name coming back from the server does not.
            if save == .saved, value != store.memberName { save = .idle }
        }
        .onChange(of: focused) { _, now in if !now { commit() } }
        // Leaving the page keeps the name too; a failure then shows on Settings.
        .onDisappear { commit(leaving: true) }
    }

    @ViewBuilder private var status: some View {
        switch save {
        case .saving:
            ProgressView().controlSize(.small).transition(.opacity)
        case .saved:
            CentralIcon("icon-check", size: 20, relativeTo: .body).foregroundStyle(CommaTheme.brandSolid)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
                .accessibilityHidden(true)
        case .idle, .failed:
            EmptyView()
        }
    }

    private var remaining: Int { UserProfile.maxNameLength - draft.count }

    private func commit(leaving: Bool = false) {
        guard save != .saving else {
            queued = (queued ?? false) || leaving
            return
        }
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = store.memberName ?? ""
        guard !name.isEmpty, name != saved else {
            if !leaving { draft = saved }
            return
        }
        save = .saving
        let boundary = store.boundaryToken
        Task {
            do {
                try await store.updateProfile(name: name)
                let next = queued
                queued = nil
                // Typed on while this saved: the newer name stays, and goes next if a save was asked for.
                guard draft.trimmingCharacters(in: .whitespacesAndNewlines) == name else {
                    save = .idle
                    if let next { commit(leaving: next) }
                    return
                }
                // The server's spelling of the name, which may differ from what was typed.
                // Set only when it differs: writing the same text moves the caret of a field still being edited.
                let saved = store.memberName ?? name
                if draft != saved { draft = saved }
                save = .saved
                AccessibilityNotification.Announcement(String(localized: "Name saved")).post()
                try? await Task.sleep(for: .seconds(1.5))
                if save == .saved { save = .idle }
            } catch {
                let next = queued
                queued = nil
                save = .failed(error.localizedDescription)
                if leaving || next == true { store.present(error, boundary: boundary) }
            }
        }
    }
}

/// Where saving the name stands.
private enum NameSave: Equatable {
    case idle, saving, saved
    case failed(String)
}
