import SwiftUI

// MARK: - Stage transition

private struct LoginStageModifier: ViewModifier {
    let progress: CGFloat
    func body(content: Content) -> some View {
        content
            .opacity(progress)
            .scaleEffect(0.9 + 0.1 * progress)
            .offset(y: 8 * (1 - progress))
            .blur(radius: 8 * (1 - progress))
    }
}

extension AnyTransition {
    /// Desktop `login-stage-enter/exit`: fade, 0.9 scale, 8pt shift, 8pt blur. With Reduce Motion the stages
    /// only cross-fade, without the scale and shift.
    static func loginStage(reduced: Bool) -> AnyTransition {
        guard !reduced else { return .opacity.animation(CommaMotion.stateChange) }
        return .asymmetric(
            insertion: .modifier(active: LoginStageModifier(progress: 0), identity: LoginStageModifier(progress: 1))
                .animation(CommaMotion.surfaceSmoothOut),
            removal: .modifier(active: LoginStageModifier(progress: 0), identity: LoginStageModifier(progress: 1))
                .animation(CommaMotion.stageExit))
    }
}

// MARK: - Announcements

extension View {
    /// Reads `message` to VoiceOver whenever it appears or changes: a login error shows up under the field that
    /// caused it, away from the VoiceOver cursor, and would otherwise go unheard.
    func announcing(_ message: String?) -> some View {
        onChange(of: message) { _, new in
            if let new { AccessibilityNotification.Announcement(new).post() }
        }
    }
}
