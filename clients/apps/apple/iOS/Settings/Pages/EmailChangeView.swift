import SwiftUI

/// Moves the member's account to another email (the core's `emailChange.*`): a code goes to the current email, then
/// a code to the new one; with both the email changes. The account, its workspaces and this session stay, and the
/// page goes back to the profile, which shows the new email.
///
/// A message stays until the next answer replaces it, as on the account deletion page.
struct EmailChangeView: View {
    let store: CommaStore
    @Environment(AppNavigation.self) private var navigation
    @State private var step = Step.intro
    @State private var code = ""
    @State private var email = ""
    @State private var problem: String?
    @State private var action = PageAction()
    @FocusState private var focused: Bool

    private enum Step: Equatable {
        case intro
        case currentCode(challenge: String)
        case newEmail(challenge: String, code: String)
        case newCode(challenge: String, email: String)
    }

    var body: some View {
        SettingsPage {
            if let problem { InlineError(message: problem, dismiss: { show(nil) }) }
            SettingsSection {
                switch step {
                case .intro:
                    button("Send code", id: "sendCurrentEmailCode") { requestCode() }
                case .currentCode(let challenge):
                    codeField
                    button("Continue", id: "continueEmailChange", disabled: code.count != 6) {
                        step = .newEmail(challenge: challenge, code: code)
                        focused = true
                    }
                case .newEmail(let challenge, let currentCode):
                    TextField("New email", text: $email, prompt: Text(verbatim: "name@example.com"))
                        .font(.body)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused)
                        .surfaceRowFrame()
                        .accessibilityIdentifier("newEmail")
                    button("Send code", id: "sendNewEmailCode", disabled: email.trimmed.isEmpty) {
                        requestNewCode(challenge: challenge, code: currentCode)
                    }
                case .newCode(let challenge, _):
                    codeField
                    button("Change email", id: "confirmEmailChange", disabled: code.count != 6) {
                        confirm(challenge: challenge)
                    }
                }
            } footer: {
                switch step {
                case .intro:
                    Text("Your account, workspaces, tasks and files stay as they are; only the email you sign in with changes. We will email a code to \(store.memberEmail) first. If you can no longer read that mailbox, contact support@comma.surf.")
                case .currentCode:
                    Text("Enter the 6-digit code we sent to \(store.memberEmail).")
                case .newEmail:
                    Text("Enter the new email. We will send a code to it.")
                case .newCode(_, let email):
                    Text("Enter the 6-digit code we sent to \(email). Your email changes as soon as you confirm.")
                }
            }
        }
        .disabled(action.busy)
        .pageTitle("Change email")
    }

    private var codeField: some View {
        TextField("Verification code", text: $code, prompt: Text("6-digit code"))
            .font(.body)
            .keyboardType(.numberPad)
            .textContentType(.oneTimeCode)
            .focused($focused)
            .surfaceRowFrame()
            .onChange(of: code) { _, value in code = String(value.filter(\.isNumber).prefix(6)) }
            .accessibilityIdentifier("emailChangeCode")
    }

    private func button(_ title: LocalizedStringKey, id: String, disabled: Bool = false,
                        run: @escaping () -> Void) -> some View {
        Button(action: run) { SettingsRow(Text(title)) }
            .buttonStyle(SurfaceRowButtonStyle())
            .disabled(disabled)
            .accessibilityIdentifier(id)
    }

    private func requestCode() {
        action.run {
            do {
                let answer = try await store.core.call("emailChange.requestCode").value as? [String: Any]
                guard let challenge = answer?["challengeId"] as? String else { return }
                code = ""
                step = .currentCode(challenge: challenge)
                focused = true
                show(nil)
            } catch {
                show(message(for: error))
            }
        }
    }

    private func requestNewCode(challenge: String, code currentCode: String) {
        let newEmail = email.trimmed
        action.run {
            do {
                let answer = try await store.core.call(
                    "emailChange.requestNewCode",
                    ["email": newEmail, "challengeId": challenge, "code": currentCode]
                ).value as? [String: Any]
                guard let next = answer?["challengeId"] as? String else { return }
                code = ""
                step = .newCode(challenge: next, email: newEmail)
                focused = true
                show(nil)
            } catch let error as CoreError where error.code == "invalid_verification_code" {
                // A wrong first code is typed again where it was asked for.
                code = ""
                step = .currentCode(challenge: challenge)
                show(message(for: error))
            } catch let error as CoreError where error.code == "email_taken" || error.code == "email_pending_deletion" {
                // The first code was used up (it is checked before the email is looked up): start again.
                step = .intro
                show(message(for: error))
            } catch {
                show(message(for: error))
            }
        }
    }

    private func confirm(challenge: String) {
        action.run {
            do {
                _ = try await store.core.call("emailChange.confirm", ["challengeId": challenge, "code": code])
                if navigation.settingsPath.last == .changeEmail { navigation.settingsPath.removeLast() }
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
        case "invalid_verification_code": String(localized: "That code is wrong or has expired.")
        case "invalid_email": String(localized: "Enter a valid email address.")
        case "same_email": String(localized: "This is already your email.")
        case "email_taken": String(localized: "Another Comma account uses this email. Use another email, or sign in to that account and delete it first (deletion completes after 7 days).")
        case "email_pending_deletion":
            if let date = deletionDate(of: error) {
                String(localized: "The account with this email is waiting to be deleted. You can use this email after \(date.formatted(date: .abbreviated, time: .omitted)). Sign in with this email to cancel the deletion.")
            } else {
                String(localized: "Another Comma account uses this email. Use another email, or sign in to that account and delete it first (deletion completes after 7 days).")
            }
        case "email_changed": String(localized: "Your email changed in the meantime. Start again.")
        case "rate_limited": String(localized: "Too many codes were asked for. Wait a minute, then try again.")
        default: error.localizedDescription
        }
    }
}

/// When the account that has the new email is deleted (`email_pending_deletion`), as the server said it.
private func deletionDate(of error: Error) -> Date? {
    guard let at = (error as? CoreError)?.detail?["deletion_scheduled_at"] as? String else { return nil }
    return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(at))
        ?? (try? Date(at, strategy: .iso8601))
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
