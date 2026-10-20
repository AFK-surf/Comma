import SwiftUI

// MARK: - Transitions

private struct OutgoingBubbleModifier: ViewModifier {
    let progress: CGFloat
    func body(content: Content) -> some View {
        content
            .scaleEffect(x: 0.86 + 0.14 * progress, y: 0.9 + 0.1 * progress, anchor: .bottomTrailing)
            .offset(y: 72 * (1 - progress))
            .opacity(Double(min(1, progress * 3)))
    }
}

private struct AssistantEntryModifier: ViewModifier {
    let progress: CGFloat
    func body(content: Content) -> some View {
        content.opacity(0.58 + 0.42 * progress).offset(y: 2 * (1 - progress))
    }
}

extension AnyTransition {
    /// The sent bubble rises out of the composer and widens into place (desktop outgoing flight springs).
    static var outgoingBubble: AnyTransition {
        .asymmetric(insertion: .modifier(active: OutgoingBubbleModifier(progress: 0), identity: OutgoingBubbleModifier(progress: 1))
                        .animation(CommaMotion.sendPosition),
                    removal: .identity)
    }
    static var assistantEntry: AnyTransition {
        .asymmetric(insertion: .modifier(active: AssistantEntryModifier(progress: 0), identity: AssistantEntryModifier(progress: 1))
                        .animation(CommaMotion.assistantEntry),
                    removal: .identity)
    }
}
