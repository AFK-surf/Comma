import SwiftUI

/// The Comma mark, which plays the desktop `CommaLogoAnimation` while the router thinks or streams a reply.
struct RouterMark: View {
    let replying: Bool
    let size: CGFloat
    var ink: Color = CommaTheme.textPrimary

    var body: some View {
        ZStack {
            if replying {
                CommaLogoAnimation(ink: ink, aperture: CommaTheme.bgPrimary)
                    .transition(.opacity)
            } else {
                CommaMark(size: size).foregroundStyle(ink).transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .animation(CommaMotion.stateChange, value: replying)
    }
}
