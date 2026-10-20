import SwiftUI
import UIKit
import CommaCore

/// The member's photo, or their initials when there is no photo. Until a name is known it shows a person
/// glyph, so the avatar changes once, to the member, instead of passing through an email's or the app's
/// initial while the session and profile load.
struct UserAvatar: View {
    let store: CommaStore
    let size: CGFloat
    /// A name to take the initials from instead of the member's, such as one still being typed.
    var name: String?

    var body: some View {
        ZStack {
            if let data = store.avatarData, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
                    .transition(.opacity)
            } else {
                CommaTheme.brandSolid
                if let initials {
                    // The initials fill a fixed circle, so they scale with it rather than with Dynamic Type.
                    Text(initials).font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(.white)
                        .transition(.opacity)
                } else {
                    CentralIcon("central-people", size: size * 0.55).foregroundStyle(.white.opacity(0.9))
                        .transition(.opacity)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .animation(CommaMotion.stateChange, value: initials)
        .animation(CommaMotion.stateChange, value: store.avatarData)
        .accessibilityHidden(true)
    }

    /// Up to two initials from the member's name; none while only an email is known.
    private var initials: String? {
        guard let name = name ?? store.memberName else { return nil }
        let letters = String(name.split(separator: " ").prefix(2).compactMap(\.first)).uppercased()
        return letters.isEmpty ? nil : letters
    }
}
