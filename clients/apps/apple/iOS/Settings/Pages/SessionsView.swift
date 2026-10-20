import SwiftUI
import CommaCore

/// The member's signed-in devices (the core's `accountSessions`). Signing out another device also signs out the Apple
/// Watch paired from it.
struct SessionsView: View {
    let store: CommaStore
    @State private var sessions: [AccountSession] = []
    @State private var loaded = false
    @State private var failed = false
    @State private var action = PageAction()
    @State private var notice: String?
    @State private var confirmingAll = false

    var body: some View {
        let others = sessions.filter { !$0.current }
        SettingsPage {
            if let error = action.error { InlineError(message: error, dismiss: { action.error = nil }) }
            if failed, sessions.isEmpty {
                InlineError(message: String(localized: "Comma could not load your devices."), retry: { refresh() })
            }
            if !loaded {
                ProgressView().frame(maxWidth: .infinity).padding(.top, 24)
            }
            if let current = sessions.first(where: \.current) {
                SettingsSection(Text("This device")) { SessionRow(session: current, current: true) }
            }
            // A list that failed to load says so, never that no other device is signed in.
            if loaded, !failed || !sessions.isEmpty {
                SettingsSection(Text("Other devices"), footer: Text("Signing out a device also signs out the Apple Watch connected through it.")) {
                    if others.isEmpty {
                        Text("No other devices are signed in.").font(.body).foregroundStyle(CommaTheme.textTertiary)
                            .surfaceRowFrame()
                    }
                    ForEach(others) { session in
                        SessionRow(session: session, current: false) { revoke(session) }
                    }
                }
                if !others.isEmpty {
                    SettingsSection {
                        Button(role: .destructive) { confirmingAll = true } label: {
                            SettingsRow(Text("Sign out all other devices"), icon: "central-arrow-box-left", role: .destructive)
                        }
                        .buttonStyle(SurfaceRowButtonStyle())
                    }
                }
            }
            if let notice {
                Text(notice).font(.subheadline).foregroundStyle(CommaTheme.textTertiary).padding(.horizontal, 4)
            }
        }
        .disabled(action.busy)
        .pageTitle("Signed-in devices")
        .refreshable { _ = try? await store.core.call("accountSessions.refresh") }
        .task { await follow() }
        .confirmationDialog("Sign out all other devices?", isPresented: $confirmingAll, titleVisibility: .visible) {
            Button("Sign out all other devices", role: .destructive) {
                run {
                    let count = try await store.core.call("accountSessions.revokeOthers").value as? NSNumber
                    notice = String(localized: "Signed out \(count?.intValue ?? 0) sessions.")
                }
            }
        } message: {
            Text("This iPhone stays signed in.")
        }
    }

    /// Follows the list while the page shows it; the core reads it again after each sign-out.
    private func follow() async {
        for await value in store.core.subscribe(["topic": "accountSessions"], read: AccountSessions.init) {
            guard case .value(let next) = value else { failed = true; loaded = true; continue }
            sessions = next.sessions
            failed = next.status == "error"
            loaded = next.status != "loading"
        }
    }

    private func refresh() { Task { _ = try? await store.core.call("accountSessions.refresh") } }

    private func revoke(_ session: AccountSession) {
        run { _ = try await store.core.call("accountSessions.revoke", ["id": session.id]) }
    }

    private func run(_ operation: @escaping () async throws -> Void) {
        guard !action.busy else { return }
        notice = nil
        action.run(operation) {}
    }
}

/// One of the account's open sessions, as the core lists it: this one first, then the most recently active.
struct AccountSession: Identifiable, Equatable, Sendable {
    let id: String
    let deviceLabel: String?
    let clientKind: String?
    let clientPlatform: String?
    let lastActiveDate: Date?
    let current: Bool
}

private struct AccountSessions: Sendable {
    let status: String
    let sessions: [AccountSession]

    init(_ value: Any?) {
        let json = value as? NSDictionary
        status = json?.string("status") ?? "loading"
        sessions = json?.objects("sessions").compactMap { row in
            guard let id = row.string("id") else { return nil }
            let seen = row.double("lastSeenAt") ?? row.double("authenticatedAt")
            return AccountSession(id: id, deviceLabel: row.string("deviceLabel"), clientKind: row.string("clientKind"),
                                  clientPlatform: row.string("clientPlatform"), lastActiveDate: seen.map(Date.init(wireTimestamp:)),
                                  current: row.bool("current"))
        } ?? []
    }
}

/// A device: its kind's glyph, its name and when it was last active. Another device's row has a menu, and a
/// long press, for signing it out.
private struct SessionRow: View {
    let session: AccountSession
    let current: Bool
    var signOut: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            CentralIcon(icon, size: 20, relativeTo: .body).foregroundStyle(CommaTheme.textSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body).foregroundStyle(CommaTheme.textPrimary)
                Text(detail).font(.footnote).foregroundStyle(CommaTheme.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            if let signOut {
                Menu {
                    signOutButton(signOut)
                } label: {
                    CentralIcon("inbox-actions", size: 20).foregroundStyle(CommaTheme.textSecondary)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .padding(.trailing, -12)
                .accessibilityLabel(Text("Actions for \(title)"))
            }
        }
        .surfaceRowFrame()
        .contextMenu { if let signOut { signOutButton(signOut) } }
    }

    private func signOutButton(_ action: @escaping () -> Void) -> some View {
        Button(role: .destructive, action: action) {
            Label { Text("Sign out") } icon: { MenuIcon.destructive("central-arrow-box-left") }
        }
    }

    private var icon: String {
        switch session.clientKind {
        case "watch": "central-smartwatch-1"
        case "ios": "central-phone-dynamic-island"
        case "web": "icon-globe"
        case "ssh", "api": "central-console-simple"
        default: "icon-macbook"
        }
    }

    private var title: String {
        if let label = session.deviceLabel, !label.isEmpty { return label }
        switch session.clientKind {
        case "watch": return "Apple Watch"
        case "ios": return session.clientPlatform == "ipados" ? "iPad" : "iPhone"
        case "web": return String(localized: "Web browser")
        case "ssh": return String(localized: "Command line")
        case "api": return "API"
        case "electron":
            switch session.clientPlatform {
            case "windows": return String(localized: "Comma for Windows")
            case "linux": return String(localized: "Comma for Linux")
            default: return String(localized: "Comma for Mac")
            }
        default: return String(localized: "Unknown device")
        }
    }

    private var detail: String {
        if current { return String(localized: "Active now") }
        guard let date = session.lastActiveDate else { return "" }
        return String(localized: "Last active \(date.formatted(.relative(presentation: .named)))")
    }
}
