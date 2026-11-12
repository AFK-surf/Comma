import SwiftUI

/// Follow-ups for the settled turn. The transcript clips and scrolls them within its current column.
struct ChatSuggestionChips: View {
    let pane: ConversationPane
    @ScaledMetric(relativeTo: .subheadline) private var height: CGFloat = 44

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: GroupedSurface.groupSpacing) {
                ForEach(pane.suggestions) { suggestion in
                    Button {
                        guard let attempt = pane.enqueueSuggestion(suggestion) else { return }
                        Task { await pane.deliver(attempt) }
                    } label: {
                        Text(suggestion.label).font(.subheadline.weight(.medium))
                            .foregroundStyle(CommaTheme.textSecondary)
                            .padding(.horizontal, GroupedSurface.inset).frame(minHeight: height)
                            .background(GroupedSurface.surface, in: Capsule())
                    }
                    .buttonStyle(TactileButtonStyle())
                    .accessibilityIdentifier("chatSuggestion-" + suggestion.id)
                }
            }
        }
        .scrollIndicators(.hidden)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Suggested replies")
    }
}
