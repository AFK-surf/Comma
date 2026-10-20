import SwiftUI

/// The search capsule at the top of a filter sheet: the filter glyph, the query, and a clear button once
/// there is text. A tap anywhere on the capsule focuses it; `focusChanged` lets the sheet grow so the
/// keyboard never covers the results.
struct FilterSearchField: View {
    let prompt: LocalizedStringKey
    @Binding var text: String
    var focusChanged: (Bool) -> Void = { _ in }
    @FocusState private var focused: Bool
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 42

    var body: some View {
        HStack(spacing: 8) {
            CentralIcon("icon-filter", relativeTo: .body).foregroundStyle(CommaTheme.textSecondary)
            TextField(text: $text, prompt: Text(prompt).foregroundStyle(CommaTheme.textPlaceholder)) {
                Text(prompt)
            }
            .font(.body)
            .foregroundStyle(CommaTheme.textPrimary)
            .tint(CommaTheme.brandSolid)
            .focused($focused)
            .submitLabel(.search)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .accessibilityIdentifier("filterSearch")
            if !text.isEmpty {
                Button { text = "" } label: {
                    CentralIcon("icon-close", relativeTo: .body).scaleEffect(0.8).foregroundStyle(CommaTheme.textQuaternary)
                        .frame(width: 44, height: height).contentShape(Rectangle())
                }
                .buttonStyle(TactileButtonStyle(scale: 0.88))
                .accessibilityLabel("Clear search")
                .transition(.opacity)
            }
        }
        .padding(.leading, GroupedSurface.inset)
        .padding(.trailing, text.isEmpty ? GroupedSurface.inset : 0)
        .frame(minHeight: height)
        .background(GroupedSurface.ink, in: Capsule())
        .contentShape(Capsule())
        .onTapGesture { focused = true }
        .animation(CommaMotion.stateChange, value: text.isEmpty)
        .onChange(of: focused) { _, isFocused in focusChanged(isFocused) }
    }
}
