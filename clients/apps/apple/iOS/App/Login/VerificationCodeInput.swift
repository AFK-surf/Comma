import SwiftUI

// MARK: - Verification code

/// Six visual cells over one hidden field, so the system one-time-code autofill and paste still work.
struct VerificationCodeInput: View {
    static let length = 6
    @Binding var code: String
    let invalid: Bool
    let disabled: Bool
    let onComplete: (String) -> Void
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var popping: Set<Int> = []
    @State private var shake = Array(repeating: CGFloat.zero, count: length)

    var body: some View {
        // The cells size the control; the hidden field only fills behind them, so it cannot
        // stretch the login layout vertically.
        HStack(spacing: 8) {
            ForEach(0..<Self.length, id: \.self) { index in cell(index) }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .background {
            // A closure, not the method itself: Swift 6.3 crashes in IRGen converting the method to `@isolated(any)`.
            TextField("", text: Binding(get: { code }, set: { update($0) }))
                .textContentType(.oneTimeCode).keyboardType(.numberPad)
                .focused($focused)
                .foregroundStyle(.clear).tint(.clear)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(0.02)
                .accessibilityLabel("Verification code")
                .accessibilityIdentifier("verificationCode")
                .disabled(disabled)
        }
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .onAppear { focused = true }
        // Checking the code disables the field, which lowers the keyboard; a code that failed takes it back up.
        .onChange(of: disabled) { _, now in if !now { focused = true } }
        .onChange(of: invalid) { _, value in if value { playShake() } }
    }

    private func cell(_ index: Int) -> some View {
        let characters = Array(code)
        let filled = index < characters.count
        let active = focused && !disabled && index == min(characters.count, Self.length - 1) && !(filled && characters.count == Self.length)
        return RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(filled && !active ? CommaTheme.bgDisabled : CommaTheme.bgPrimary)
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(invalid ? CommaTheme.errorBorder : (active ? CommaTheme.textQuaternary : CommaTheme.borderPrimary), lineWidth: 1))
            .shadow(color: .black.opacity(filled && !active ? 0 : 0.05), radius: 1, y: 1)
            .overlay {
                if filled {
                    Text(String(characters[index]))
                        .font(.title3.weight(.medium))
                        .foregroundStyle(active ? CommaTheme.textPrimary : CommaTheme.textQuaternary)
                } else if active {
                    BlinkingCaret()
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .scaleEffect(popping.contains(index) ? 0.97 : (active ? 1.106 : 1))
            .zIndex(active ? 1 : 0)
            .offset(x: shake[index])
            .animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.2), value: active)
            .animation(CommaMotion.feedbackIn, value: popping)
    }

    private func update(_ raw: String) {
        let next = String(raw.filter { $0.isLetter || $0.isNumber }.uppercased().prefix(Self.length))
        let previous = code
        guard next != previous else { return }
        let entering = Set((0..<next.count).filter { $0 >= previous.count })
        code = next
        if !entering.isEmpty {
            popping = entering
            Task { try? await Task.sleep(for: .milliseconds(120)); popping = [] }
        }
        if next.count == Self.length { onComplete(next) }
    }

    /// Unit-mass spring (stiffness 910, damping 18) from a 12pt offset, staggered 8ms per cell. With Reduce Motion
    /// the cells stay put: their red outline, the message and the error haptic still mark the wrong code.
    private func playShake() {
        guard !reduceMotion else { return }
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) { shake = Array(repeating: 12, count: Self.length) }
        Task { @MainActor in
            await Task.yield()
            for index in 0..<Self.length {
                withAnimation(.interpolatingSpring(mass: 1, stiffness: 910, damping: 18).delay(Double(index) * 0.008)) {
                    shake[index] = 0
                }
            }
        }
    }
}

private struct BlinkingCaret: View {
    @State private var visible = true
    var body: some View {
        Rectangle().fill(CommaTheme.textPrimary).frame(width: 1.5, height: 24)
            .opacity(visible ? 1 : 0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) { visible = false }
            }
    }
}
