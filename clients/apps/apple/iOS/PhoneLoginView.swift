import AuthenticationServices
import SwiftUI
import CommaCore

/// Two-stage login that follows the desktop `Login` component: email, then a six-cell code.
struct PhoneLoginView: View {
    @Bindable var store: CommaStore
    @State private var email = ""
    @State private var code = ""
    @State private var challengeID: String?
    @State private var appleLink = false
    @State private var appleAttempt: AppleLoginAttempt?
    @State private var preparingApple = false
    @State private var requestingCode = false
    @State private var emailInvalid = false
    @State private var localError: String?
    @State private var codeError: String?
    @State private var resendDeadline = Date()
    @Environment(\.colorScheme) private var colorScheme

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
                            emailStage.transition(.loginStage)
                        } else {
                            verificationStage.transition(.loginStage)
                        }
                    }
                }
                .frame(maxWidth: 360)
                .padding(.horizontal, 24 + sideInset)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .scrollDismissesKeyboard(.interactively)
            .ignoresSafeArea(.container, edges: .horizontal)
        }
        .background(CommaTheme.bgPrimary.ignoresSafeArea())
        .task { await prepareApple() }
    }

    // MARK: Email stage

    private var emailStage: some View {
        VStack(spacing: 24) {
            VStack(spacing: 2) {
                Text("Welcome to Comma")
                    .font(.system(size: 24, weight: .medium)).foregroundStyle(CommaTheme.textPrimary)
                Text("Work anywhere with your agents")
                    .font(.system(size: 18)).foregroundStyle(CommaTheme.textQuaternary)
            }
            .multilineTextAlignment(.center)

            if appleAttempt != nil {
                SignInWithAppleButton(.signIn) { request in
                    request.requestedScopes = [.email, .fullName]
                    request.nonce = appleAttempt?.nonce
                } onCompletion: { result in
                    Task { await completeApple(result) }
                }
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .whiteOutline)
                .frame(height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .disabled(preparingApple || requestingCode || store.loading)
                .transition(.opacity)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Email").font(.system(size: 14, weight: .medium)).foregroundStyle(CommaTheme.textSecondary)
                TextField("", text: $email, prompt: Text("Your email address").foregroundStyle(CommaTheme.textPlaceholder))
                    .textContentType(.emailAddress).keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.continue)
                    .onSubmit { Task { await requestCode() } }
                    .font(.system(size: 16)).foregroundStyle(CommaTheme.textPrimary)
                    .padding(.horizontal, 14).frame(height: 44)
                    .background(CommaTheme.bgPrimary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(emailInvalid ? CommaTheme.errorBorder : CommaTheme.borderPrimary, lineWidth: 1))
                    .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
                    .onChange(of: email) { _, _ in emailInvalid = false; localError = nil }
                    .accessibilityIdentifier("emailAddress")
                if emailInvalid {
                    Text("Please enter a valid email address.").font(.system(size: 14)).foregroundStyle(CommaTheme.errorPrimary)
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

            if let message = localError {
                Text(message).font(.system(size: 14)).foregroundStyle(CommaTheme.errorPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .animation(CommaMotion.stateChange, value: appleAttempt != nil)
        .animation(CommaMotion.stateChange, value: emailInvalid)
    }

    // MARK: Verification stage

    private var verificationStage: some View {
        VStack(spacing: 16) {
            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    Text("Check your email")
                        .font(.system(size: 20, weight: .medium)).foregroundStyle(CommaTheme.textPrimary)
                    Text("Enter the code sent to \(email)")
                        .font(.system(size: 14)).foregroundStyle(CommaTheme.textQuaternary)
                }
                .multilineTextAlignment(.center)
                VerificationCodeInput(code: $code, invalid: codeError != nil, disabled: store.loading) { value in
                    Task { await verify(value) }
                }
            }

            if let codeError {
                Text(codeError).font(.system(size: 14)).foregroundStyle(CommaTheme.errorPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            } else if store.loading {
                ProgressView().transition(.opacity)
            } else if !appleLink {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let seconds = max(0, Int(resendDeadline.timeIntervalSince(context.date).rounded(.up)))
                    HStack(spacing: 4) {
                        Text("Didn’t receive the code?").foregroundStyle(CommaTheme.textQuaternary)
                        if seconds > 0 {
                            Text("Resend in \(seconds)s").foregroundStyle(CommaTheme.textPrimary).monospacedDigit()
                        } else {
                            Button("Resend") { Task { await requestCode(resend: true) } }
                                .foregroundStyle(CommaTheme.textPrimary).disabled(requestingCode)
                        }
                    }
                    .font(.system(size: 14))
                }
            }

            Button("Use a different email") {
                withAnimation(CommaMotion.stageExit) {
                    challengeID = nil
                    appleLink = false
                    code = ""
                    codeError = nil
                }
                AppleCredentialMonitor.pendingSubject = nil
                Task { await prepareApple() }
            }
            .font(.system(size: 14)).foregroundStyle(CommaTheme.textPrimary)
            .disabled(store.loading)
        }
        .onChange(of: code) { _, _ in
            if codeError != nil { withAnimation(CommaMotion.stateChange) { codeError = nil } }
        }
        .animation(CommaMotion.stateChange, value: store.loading)
    }

    private var trimmedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }

    // MARK: Actions

    private func verify(_ value: String) async {
        guard let challengeID, value.count == VerificationCodeInput.length, !store.loading else { return }
        let accepted = await store.verifyEmail(challengeID: challengeID, code: value, appleLink: appleLink)
        guard !accepted else { return }
        withAnimation(CommaMotion.stateChange) {
            codeError = store.error ?? String(localized: "That code didn’t work. Check it and try again.")
        }
        store.dismissError()
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
        do {
            let challenge = try await store.requestEmailCode(email: address)
            resendDeadline = Date().addingTimeInterval(60)
            withAnimation(CommaMotion.surfaceSmoothOut) {
                email = address
                challengeID = challenge.challengeID
                code = ""
                codeError = nil
                appleLink = false
            }
            appleAttempt = nil
        } catch {
            if resend { codeError = error.localizedDescription } else { localError = error.localizedDescription }
        }
    }

    private func prepareApple() async {
        guard challengeID == nil, !preparingApple else { return }
        preparingApple = true
        defer { preparingApple = false }
        // Apple sign-in is optional: when the server has no matching client, only email is offered.
        guard let attempt = try? await store.client.beginAppleLogin(),
              attempt.clientID == Bundle.main.bundleIdentifier else { return }
        appleAttempt = attempt
    }

    private func completeApple(_ result: Result<ASAuthorization, any Error>) async {
        guard let attempt = appleAttempt else { return }
        do {
            let authorization = try result.get()
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let token = String(data: tokenData, encoding: .utf8) else {
                localError = String(localized: "Apple sign-in could not finish. Please try again.")
                return
            }
            switch try await store.client.completeAppleLogin(attemptID: attempt.attemptID, identityToken: token) {
            case .signedIn(let session):
                AppleCredentialMonitor.save(subject: credential.user, sessionID: session.id)
                await store.signedIn(session)
            case .otpRequired(let id, let address):
                AppleCredentialMonitor.pendingSubject = credential.user
                withAnimation(CommaMotion.surfaceSmoothOut) {
                    challengeID = id
                    email = address
                    appleLink = true
                }
            }
        } catch {
            if let error = error as? ASAuthorizationError, error.code == .canceled { return }
            localError = error.localizedDescription
            appleAttempt = nil
            await prepareApple()
        }
    }
}

// MARK: - Verification code

/// Six visual cells over one hidden field, so the system one-time-code autofill and paste still work.
struct VerificationCodeInput: View {
    static let length = 6
    @Binding var code: String
    let invalid: Bool
    let disabled: Bool
    let onComplete: (String) -> Void
    @FocusState private var focused: Bool
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
            TextField("", text: Binding(get: { code }, set: update))
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
                        .font(.system(size: 20, weight: .medium))
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

    /// Unit-mass spring (stiffness 910, damping 18) from a 12pt offset, staggered 8ms per cell.
    private func playShake() {
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
    /// Desktop `login-stage-enter/exit`: fade, 0.9 scale, 8pt shift, 8pt blur.
    static var loginStage: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: LoginStageModifier(progress: 0), identity: LoginStageModifier(progress: 1))
                .animation(CommaMotion.surfaceSmoothOut),
            removal: .modifier(active: LoginStageModifier(progress: 0), identity: LoginStageModifier(progress: 1))
                .animation(CommaMotion.stageExit))
    }
}
