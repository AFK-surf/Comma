import AuthenticationServices
import SwiftUI
import CommaCore

/// Two-stage login that follows the desktop `Login` component: email, then a six-cell code. The client core runs
/// the sign-in (`session.*`) and keeps the attempt under way, so the code stage shows while the core has one.
struct PhoneLoginView: View {
    @Bindable var store: CommaStore
    @State var email = ""
    @State private var code = ""
    @State private var requestingCode = false
    @State private var signingInWithApple = false
    @State private var emailInvalid = false
    @State var localError: String?
    @State private var codeError: String?

    private var challengeID: String? { store.signIn?.challengeID }
    private var appleLink: Bool { store.signIn?.linkingApple == true }
    private var resendDeadline: Date { store.resendAt ?? .distantPast }
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // The empty navigation bar lets a system vertical bar (iPhone Duo) render over this page's
        // background instead of as a separate black column.
        NavigationStack {
            form
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.hidden, for: .navigationBar)
        }
    }

    private var form: some View {
        GeometryReader { geometry in
            // Center on the whole screen: landscape devices can reserve a status-bar or camera
            // inset on one side only, so pad both sides by the larger one instead.
            let sideInset = max(geometry.safeAreaInsets.leading, geometry.safeAreaInsets.trailing)
            ScrollView {
                VStack(spacing: 16) {
                    CommaMark(size: 48).foregroundStyle(CommaTheme.textPrimary)
                    ZStack(alignment: .top) {
                        if challengeID == nil {
                            emailStage.transition(.loginStage(reduced: reduceMotion))
                        } else {
                            verificationStage.transition(.loginStage(reduced: reduceMotion))
                        }
                    }
                }
                .frame(maxWidth: 360)
                .padding(.horizontal, 24 + sideInset)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .scrollDismissesKeyboard(.interactively)
            // At large text sizes the stage scrolls up under the empty bar above the keyboard; the page colour
            // covers the bar and fades out below it, so the time never prints over the text.
            .overlay(alignment: .top) {
                let top = geometry.safeAreaInsets.top
                LinearGradient(stops: [.init(color: CommaTheme.bgPrimary, location: top / (top + 12)),
                                       .init(color: CommaTheme.bgPrimary.opacity(0), location: 1)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: top + 12).offset(y: -top)
                    .allowsHitTesting(false)
            }
            .ignoresSafeArea(.container, edges: .horizontal)
        }
        .background(CommaTheme.bgPrimary.ignoresSafeArea())
        .animation(CommaMotion.surfaceSmoothOut, value: challengeID)
        .onChange(of: store.signIn?.email) { _, address in
            if let address { email = address }
        }
    }

    // MARK: Email stage

    private var emailStage: some View {
        VStack(spacing: 24) {
            LoginHeading(title: "Welcome to Comma", subtitle: Text("Work anywhere with your agents"))

            AppleSignInButton(style: colorScheme == .dark ? .white : .whiteOutline) {
                Task { await signInWithApple() }
            }
            .frame(height: 44)
            // The capsule of the field and button below; the outline is redrawn along it, as the clip cuts the
            // system's at the corners.
            .clipShape(Capsule())
            .overlay { if colorScheme != .dark { Capsule().strokeBorder(.black, lineWidth: 1).allowsHitTesting(false) } }
            .disabled(signingInWithApple || requestingCode || store.loading)

            VStack(alignment: .leading, spacing: 6) {
                Text("Email").font(.subheadline.weight(.medium)).foregroundStyle(CommaTheme.textSecondary)
                TextField("", text: $email, prompt: Text("Your email address").foregroundStyle(CommaTheme.textPlaceholder))
                    .textContentType(.emailAddress).keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.continue)
                    .onSubmit { Task { await requestCode() } }
                    .font(.body).foregroundStyle(CommaTheme.textPrimary)
                    // A filled capsule, like every text field in the app; only an invalid address draws a border.
                    .padding(.horizontal, 16).frame(minHeight: 44)
                    .background(CommaTheme.bgTertiary, in: Capsule())
                    .overlay(Capsule().strokeBorder(CommaTheme.errorBorder, lineWidth: 1).opacity(emailInvalid ? 1 : 0))
                    .onChange(of: email) { _, _ in emailInvalid = false; localError = nil }
                    .accessibilityLabel("Email")
                    .accessibilityIdentifier("emailAddress")
                if emailInvalid {
                    Text("Please enter a valid email address.").font(.subheadline).foregroundStyle(CommaTheme.errorPrimary)
                }
            }

            Button {
                Task { await requestCode() }
            } label: {
                ZStack {
                    Text("Continue with email").opacity(requestingCode ? 0 : 1)
                    if requestingCode { ProgressView().tint(.white) }
                }
            }
            .buttonStyle(CommaButtonStyle())
            .disabled(trimmedEmail.isEmpty || requestingCode || store.loading)
            .accessibilityIdentifier("requestEmailCode")

            if let problem = store.sessionProblem {
                InlineError(message: problem.message, retry: { Task { await store.retrySession() } })
            }
            if let message = localError {
                Text(message).font(.subheadline).foregroundStyle(CommaTheme.errorPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .animation(CommaMotion.stateChange, value: emailInvalid)
        .announcing(emailInvalid ? String(localized: "Please enter a valid email address.") : nil)
        .announcing(localError)
    }

    // MARK: Verification stage

    private var verificationStage: some View {
        VStack(spacing: 16) {
            VStack(spacing: 24) {
                LoginHeading(title: "Check your email", subtitle: Text("Enter the code sent to \(email)"))
                VerificationCodeInput(code: $code, invalid: codeError != nil, disabled: store.loading) { value in
                    Task { await verify(value) }
                }
            }

            if let codeError {
                Text(codeError).font(.subheadline).foregroundStyle(CommaTheme.errorPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            } else if store.loading {
                ProgressView().transition(.opacity)
            } else if !appleLink {
                ResendCodeLine(deadline: resendDeadline, disabled: requestingCode) {
                    Task { await requestCode(resend: true) }
                }
            }

            Button("Use a different email") {
                withAnimation(CommaMotion.stageExit) {
                    code = ""
                    codeError = nil
                }
                Task { await store.changeEmail() }
            }
            .font(.subheadline).foregroundStyle(CommaTheme.textPrimary)
            .disabled(store.loading)
        }
        // Typing the next try clears the message; clearing the wrong code (`verify`) keeps it.
        .onChange(of: code) { _, new in
            if !new.isEmpty, codeError != nil { withAnimation(CommaMotion.stateChange) { codeError = nil } }
        }
        .sensoryFeedback(.error, trigger: codeError) { _, new in new != nil }
        .announcing(codeError)
        .animation(CommaMotion.stateChange, value: store.loading)
    }

    private var trimmedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }

    // MARK: Actions

    private func verify(_ value: String) async {
        guard challengeID != nil, value.count == VerificationCodeInput.length, !store.loading else { return }
        guard let problem = await store.verify(code: value) else { return }
        withAnimation(CommaMotion.stateChange) { codeError = problem.message }
        // The wrong digits shake, then clear so the next try starts in the first cell, as a passcode does.
        try? await Task.sleep(for: .milliseconds(450))
        if codeError != nil, code == value { code = "" }
    }

    private func requestCode(resend: Bool = false) async {
        let address = trimmedEmail
        guard !address.isEmpty, !requestingCode else { return }
        guard address.wholeMatch(of: /[^\s@]+@[^\s@]+\.[^\s@]+/) != nil else {
            emailInvalid = true
            return
        }
        AppleCredentialMonitor.pendingSubject = nil
        requestingCode = true
        localError = nil
        defer { requestingCode = false }
        if let problem = await store.requestEmailCode(email: address) {
            if resend { codeError = problem.message } else { localError = problem.message }
            return
        }
        email = address
        code = ""
        codeError = nil
    }

    private func signInWithApple() async {
        signingInWithApple = true
        localError = nil
        defer { signingInWithApple = false }
        if let problem = await store.signInWithApple() { localError = problem.message }
    }
}

/// Apple's Sign in with Apple button. The client core asks for the sign-in itself (`session.apple`), so the button only
/// starts it.
private struct AppleSignInButton: UIViewRepresentable {
    let style: ASAuthorizationAppleIDButton.Style
    let action: () -> Void

    func makeUIView(context: Context) -> ASAuthorizationAppleIDButton {
        let button = ASAuthorizationAppleIDButton(authorizationButtonType: .signIn, authorizationButtonStyle: style)
        button.addTarget(context.coordinator, action: #selector(Coordinator.tapped), for: .touchUpInside)
        return button
    }

    func updateUIView(_ view: ASAuthorizationAppleIDButton, context: Context) { context.coordinator.action = action }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func tapped() { action() }
    }
}

/// A login stage's title and the line under it. The title is the app's 20pt title, like every page title.
private struct LoginHeading: View {
    let title: LocalizedStringKey
    let subtitle: Text

    var body: some View {
        VStack(spacing: 4) {
            Text(title).font(.title3.weight(.semibold)).foregroundStyle(CommaTheme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            subtitle.font(.body).foregroundStyle(CommaTheme.textTertiary)
        }
        .multilineTextAlignment(.center)
    }
}
