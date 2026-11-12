import SwiftUI

/// Deletes the member's account (the core's `accountDeletion.*`): the member confirms, types the account email, then a
/// code goes to the account email, and the deletion is sent with it. A subscription that still renews blocks deletion; its renewal is turned off on the web, where
/// billing lives. Once deleted, the core ends the session and the app shows sign-in.
///
/// A message stays until the next answer replaces it: removing it as a button is released would move the rows
/// while the button's release animates, and its icon would trail behind.
struct AccountDeletionView: View {
    let store: CommaStore
    @State private var challenge: String?
    /// The member confirmed once and now types the account email.
    @State private var typing = false
    @State private var typedEmail = ""
    @State private var code = ""
    @State private var problem: String?
    @State private var action = PageAction()
    @FocusState private var codeFocused: Bool

    var body: some View {
        SettingsPage {
            if let problem { InlineError(message: problem, dismiss: { show(nil) }) }
            SettingsSection {
                if challenge == nil, !typing {
                    Button(role: .destructive) { typing = true; codeFocused = true } label: {
                        SettingsRow(Text("Continue"), icon: "central-trash-can", role: .destructive)
                    }
                    .buttonStyle(SurfaceRowButtonStyle())
                    .accessibilityIdentifier("continueAccountDeletion")
                } else if challenge == nil {
                    TextField("Account email", text: $typedEmail, prompt: Text(verbatim: store.memberEmail))
                        .font(.body)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($codeFocused)
                        .surfaceRowFrame()
                        .accessibilityIdentifier("accountDeletionEmail")
                    Button(role: .destructive) { requestCode() } label: {
                        SettingsRow(Text("Send code"), icon: "central-trash-can", role: .destructive)
                    }
                    .buttonStyle(SurfaceRowButtonStyle())
                    .disabled(!emailTyped)
                    .accessibilityIdentifier("sendAccountDeletionCode")
                } else {
                    TextField("Verification code", text: $code, prompt: Text("6-digit code"))
                        .font(.body)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .focused($codeFocused)
                        .surfaceRowFrame()
                        .onChange(of: code) { _, value in code = String(value.filter(\.isNumber).prefix(6)) }
                        .accessibilityIdentifier("accountDeletionCode")
                    Button(role: .destructive) { delete() } label: {
                        SettingsRow(Text("Confirm deletion"), icon: "central-trash-can", role: .destructive)
                    }
                    .buttonStyle(SurfaceRowButtonStyle())
                    .disabled(code.count != 6)
                    .accessibilityIdentifier("confirmAccountDeletion")
                }
            } footer: {
                if challenge == nil, typing {
                    Text("To confirm, type your account email: \(store.memberEmail)")
                } else if challenge == nil {
                    Text("Every device is signed out at once, and your account is deleted for good after 7 days: your tasks, chats, files and remaining credits will no longer be available, and connected channels are disconnected. Sign in again with this email within 7 days to cancel the deletion. We will email a code to \(store.memberEmail) to confirm.")
                } else {
                    Text("Enter the 6-digit code we sent to \(store.memberEmail). You are signed out as soon as you confirm, and your account is deleted after 7 days.")
                }
            }
        }
        .disabled(action.busy)
        .pageTitle("Delete account")
    }

    private var emailTyped: Bool {
        typedEmail.trimmingCharacters(in: .whitespaces).lowercased() == store.memberEmail.lowercased()
    }

    private func requestCode() {
        action.run {
            do {
                let answer = try await store.core.call("accountDeletion.requestCode").value as? [String: Any]
                challenge = answer?["challengeId"] as? String
                code = ""
                codeFocused = true
                show(nil)
            } catch {
                show(message(for: error))
            }
        }
    }

    private func delete() {
        guard let challenge else { return }
        action.run {
            do {
                _ = try await store.core.call("accountDeletion.delete", ["challengeId": challenge, "code": code])
            } catch let error as CoreError where error.code == "subscription_active" {
                self.challenge = nil
                show(message(for: error))
            } catch {
                show(message(for: error))
            }
        }
    }

    /// Changes the message without animating the rows it moves.
    private func show(_ message: String?) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { problem = message }
    }

    private func message(for error: Error) -> String {
        switch (error as? CoreError)?.code {
        case "subscription_active":
            String(localized: "Your subscription still renews. Turn off renewal under Usage & Billing in Comma on the web or on your Mac, then delete your account.")
        case "invalid_verification_code": String(localized: "That code is wrong or has expired.")
        case "rate_limited": String(localized: "Too many codes were asked for. Wait a minute, then try again.")
        default: error.localizedDescription
        }
    }
}
