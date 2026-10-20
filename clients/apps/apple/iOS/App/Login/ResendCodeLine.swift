import SwiftUI

/// "Didn't receive the code?" with the countdown to the next resend, then the Resend button. At accessibility
/// text sizes the two parts stack instead of squeezing into two narrow columns.
struct ResendCodeLine: View {
    let deadline: Date
    let disabled: Bool
    let resend: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = max(0, Int(deadline.timeIntervalSince(context.date).rounded(.up)))
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 4))
                : AnyLayout(HStackLayout(spacing: 4))
            layout {
                Text("Didn’t receive the code?").foregroundStyle(CommaTheme.textQuaternary)
                if seconds > 0 {
                    Text("Resend in \(seconds)s").foregroundStyle(CommaTheme.textPrimary).monospacedDigit()
                } else {
                    Button("Resend", action: resend)
                        .foregroundStyle(CommaTheme.textPrimary).disabled(disabled)
                }
            }
            .font(.subheadline)
            .multilineTextAlignment(.center)
        }
    }
}
