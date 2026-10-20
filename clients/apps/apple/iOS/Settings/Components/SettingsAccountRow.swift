import SwiftUI
import CommaCore

/// The member at the top of Settings: photo, name and email, leading to their profile.
struct SettingsAccountRow: View {
    let store: CommaStore

    var body: some View {
        HStack(spacing: 12) {
            UserAvatar(store: store, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName).font(.headline).foregroundStyle(CommaTheme.textPrimary).lineLimit(2)
                if displayName != email {
                    Text(email).font(.subheadline).foregroundStyle(CommaTheme.textTertiary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            SettingsChevron()
        }
        .surfaceRowFrame(vertical: 12)
        .accessibilityElement(children: .combine)
    }

    private var email: String { store.memberEmail }
    private var displayName: String { store.memberName ?? email }
}
