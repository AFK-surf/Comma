import SwiftUI

/// Name and photo. The name is shared with every device and shown to collaborators.
struct ProfileView: View {
    let store: CommaStore
    /// The name in the field, which the avatar's initials follow as it is typed.
    @State private var draft = ""

    var body: some View {
        SettingsPage {
            ProfilePhotoHeader(store: store, draftName: draftName)
            ProfileNameSection(store: store, draft: $draft)
        }
        .refreshable {
            let shown = store.memberName ?? ""
            await store.reloadProfile()
            // A name being edited stays as typed.
            if draft == shown { draft = store.memberName ?? "" }
        }
        .pageTitle("Profile")
        .task {
            await store.loadProfile()
            if draft.isEmpty { draft = store.memberName ?? "" }
        }
    }

    private var draftName: String? {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}
