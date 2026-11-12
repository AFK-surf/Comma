import SwiftUI

/// An Agent's request to the person, drawn as a card in the question card's shell, as the Android app draws it. The
/// server decides how it ends; the card shows what the core says, so every device shows the same ending. On a phone it
/// says only what is asked and why: authorizing opens the provider's page in the browser, whose verified answer ends
/// the request; declining asks the core. A status line shows only after the person acted. At its deadline the card
/// closes into its receipt. A request with `input` first asks the person to fill it in on the card.
struct AgentRequestCard: View {
    let request: AgentRequest
    let pane: ConversationPane

    /// The deadline passed on this phone, before the server says so.
    @State private var lapsed = false

    private var open: Bool { !lapsed && request.isOpen(at: Date().timeIntervalSince1970 * 1000) }

    var body: some View {
        Group {
            if open {
                AgentRequestForm(request: request, pane: pane)
            } else {
                AgentRequestReceipt(request: request)
            }
        }
        .task(id: request.expiresAt) {
            lapsed = false
            guard request.status == .pending, let deadline = request.expiresAt else { return }
            let wait = deadline / 1000 - Date().timeIntervalSince1970
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            if !Task.isCancelled { lapsed = true }
        }
    }
}

private struct AgentRequestForm: View {
    let request: AgentRequest
    let pane: ConversationPane

    @State private var declining = false
    @State private var declineFailed = false
    @State private var clientID = ""
    @State private var value = ""
    @State private var revealed = false
    @State private var filling = false
    @State private var fillFailed = false
    @State private var locating = false
    @State private var locationNote: LocalizedStringKey?
    @Environment(\.openURL) private var openURL
    @Environment(\.displayScale) private var displayScale

    private var opened: Bool { pane.openedRequests.contains(request.id) }
    /// A secret the card cannot take (one with fields) is filled in on Comma's own form, not authorized at a provider.
    private var form: Bool { request.provider == "secret" }
    /// This phone is answering by itself: the card only says so.
    private var answering: Bool { request.isLocation && pane.store?.locationAnswers.reading.contains(request.id) == true }
    private var card: RoundedRectangle { RoundedRectangle(cornerRadius: 20, style: .continuous) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                mark
                VStack(alignment: .leading, spacing: 2) {
                    Text(request.title).font(.headline).foregroundStyle(CommaTheme.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    if !request.reason.isEmpty {
                        Text(request.reason).font(.subheadline).foregroundStyle(CommaTheme.textSecondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding([.horizontal, .top], 16)
            if let input = request.input, input.fills { fields(input) }
            if let code = request.input?.code {
                Text(verbatim: code).font(.title3.monospaced().weight(.semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                    .background(CommaTheme.bgPrimary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .textSelection(.enabled)
                    .padding(.horizontal, 16).padding(.top, 12)
            }
            if let status {
                status.font(.footnote).foregroundStyle(CommaTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16).padding(.top, 8)
            }
            ThirdsLayout(spacing: 8) {
                Button("Decline", action: decline)
                    .buttonStyle(CommaButtonStyle(hierarchy: .secondary))
                    .disabled(declining)
                if request.isLocation {
                    Button("Share location", action: shareLocation)
                        .buttonStyle(CommaButtonStyle())
                        .disabled(locating || answering)
                } else if let input = request.input, input.fills {
                    Button(input.kind == .app ? "Next" : input.kind == .paste ? "Submit" : "Save", action: fill)
                        .buttonStyle(CommaButtonStyle())
                        .disabled(!ready || filling)
                } else {
                    Button(opened ? "Open again" : request.input?.code != nil ? "Copy code and open" : form ? "Open form" : "Authorize in browser", action: authorize)
                        .buttonStyle(CommaButtonStyle())
                        .disabled(request.authorizationURL == nil)
                }
            }
            .padding(8).padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CommaTheme.bgSecondary, in: card)
        .overlay(card.strokeBorder(CommaTheme.borderPrimary, lineWidth: 1 / displayScale))
        .shadowXs()
        .accessibilityElement(children: .contain)
    }

    /// What the person fills in. It stays in this view until it is sent to the server.
    private func fields(_ input: AgentRequest.Input) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if input.kind == .paste {
                field("Code from the page") {
                    TextField("", text: $value).onSubmit(fill)
                }
                if let page = request.authorizationURL {
                    Link("Open the sign-in page", destination: page).font(.footnote)
                }
            } else if input.kind == .app {
                field("App ID") {
                    TextField("App ID", text: $clientID)
                }
            }
            if input.kind != .paste { field(input.kind == .app ? "App Secret" : LocalizedStringKey(request.secretName)) {
                HStack(spacing: 8) {
                    Group {
                        if revealed {
                            TextField("", text: $value)
                        } else {
                            SecureField("", text: $value)
                        }
                    }
                    .onSubmit(fill)
                    Button {
                        revealed.toggle()
                    } label: {
                        CentralIcon("central-eye-open", size: 16)
                            .foregroundStyle(revealed ? CommaTheme.brandSolid : CommaTheme.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show value")
                }
            } }
            if let help = input.helpURL {
                Link(input.kind == .app ? "Find them in \(request.providerName)'s developer console" : "Where to get it",
                     destination: help)
                    .font(.footnote)
            }
            if let redirect = input.redirectURI {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Redirect URL").font(.footnote).foregroundStyle(CommaTheme.textTertiary)
                    Text(verbatim: redirect).font(.footnote).foregroundStyle(CommaTheme.textPrimary)
                        .textSelection(.enabled)
                }
            }
            Text(input.kind == .paste ? "You authorize in your browser. Comma never sees your password." : "Saved to Comma directly. It stays out of the chat and is not sent to the model.")
                .font(.footnote).foregroundStyle(CommaTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16).padding(.top, 12)
    }

    private func field(_ label: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.footnote).foregroundStyle(CommaTheme.textSecondary)
            content()
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.subheadline)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(CommaTheme.bgPrimary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(CommaTheme.borderPrimary, lineWidth: 1))
        }
    }

    private var ready: Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (request.input?.kind != .app || !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func fill() {
        guard ready, !filling, let input = request.input else { return }
        filling = true
        fillFailed = false
        let values = input.kind == .app
            ? ["client_id": clientID.trimmingCharacters(in: .whitespacesAndNewlines),
               "client_secret": value.trimmingCharacters(in: .whitespacesAndNewlines)]
            : ["value": value]
        Task {
            let taken = await pane.fillRequest(request.id, values: values)
            filling = false
            fillFailed = !taken
            if taken { value = "" }
        }
    }

    /// The account's mark on a bordered, lightly shadowed tile beside the title; monochrome marks (GitHub) follow the
    /// text colour.
    private var mark: some View {
        let tile = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return Group {
            if request.isLocation {
                CentralIcon("central-map-pin", size: 22).foregroundStyle(CommaTheme.textPrimary)
            } else if let image = ProviderArtwork.image(request.provider) {
                Image(uiImage: image).resizable().scaledToFit().foregroundStyle(CommaTheme.textPrimary)
            } else {
                CentralIcon("central-puzzle", size: 22).foregroundStyle(CommaTheme.sidebarIcon)
            }
        }
        .frame(width: 22, height: 22)
        .frame(width: 40, height: 40)
        .background(CommaTheme.bgPrimary, in: tile)
        .overlay(tile.strokeBorder(CommaTheme.borderPrimary, lineWidth: 1))
        .shadowXs()
        .accessibilityHidden(true)
    }

    /// Said only after the person acted: the decline did not go, or the browser is open.
    private var status: Text? {
        if declineFailed { return Text("Could not decline. Try again.") }
        if fillFailed { return Text("Could not save. Try again.") }
        if locating || answering { return Text("Getting your location…") }
        if let locationNote { return Text(locationNote) }
        if opened { return Text(form ? "Finish filling in the form…" : "Finish authorizing in your browser…") }
        return nil
    }

    private func authorize() {
        guard let url = request.authorizationURL else { return }
        if let code = request.input?.code { UIPasteboard.general.string = code }
        pane.openedRequests.insert(request.id)
        openURL(url)
    }

    private func shareLocation() {
        guard !locating else { return }
        locating = true
        locationNote = nil
        Task {
            do {
                let position = try await DeviceLocation().read()
                if !(await pane.shareLocation(request.id, position: position)) {
                    locationNote = "Could not share. Try again."
                }
            } catch DeviceLocation.Failure.denied {
                locationNote = "Location is off for Comma. Turn it on in your settings, then try again."
            } catch {
                locationNote = "Your location is not known now. Try again."
            }
            locating = false
        }
    }

    private func decline() {
        guard !declining else { return }
        declining = true
        declineFailed = false
        Task {
            let taken = await pane.declineRequest(request.id)
            declining = false
            declineFailed = !taken
        }
    }
}

private struct AgentRequestReceipt: View {
    let request: AgentRequest

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 16, style: .continuous) }
    private var connected: Bool {
        request.status == .completed && (request.outcome == .connected || request.outcome == .shared)
    }

    var body: some View {
        HStack(spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(request.title).font(.footnote).foregroundStyle(CommaTheme.textTertiary)
                outcome.font(.subheadline)
                    .fontWeight(connected ? .medium : .regular)
                    .foregroundStyle(connected ? CommaTheme.textPrimary : CommaTheme.textSecondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 12).padding(.leading, 12).padding(.trailing, 16)
        .background(CommaTheme.bgSecondary, in: shape)
        .overlay(shape.strokeBorder(CommaTheme.borderSecondary, lineWidth: 1))
        .shadowXs()
        .accessibilityElement(children: .combine)
    }

    private var outcome: Text {
        switch (request.status, request.outcome) {
        case (.completed, .shared): return Text("Location shared")
        case (.completed, .declined) where request.isLocation: return Text("You did not share your location")
        case (.completed, .connected):
            if request.provider == "secret" { return Text("Saved") }
            if request.provider == "cli" { return Text("Logged in") }
            if let account = request.account { return Text("Connected \(request.providerName) · \(account)") }
            return Text("Connected \(request.providerName)")
        case (.completed, .declined): return Text("You did not connect \(request.providerName)")
        case (.cancelled, _): return Text("The Agent withdrew this request")
        case (.pending, _), (.expired, _): return Text("The request expired")
        default: return Text("This request did not finish")
        }
    }

    private var icon: some View {
        ZStack {
            Circle().fill(connected ? CommaTheme.brandSolid : CommaTheme.bgTertiary)
            switch (request.status, request.outcome) {
            case (.completed, .connected), (.completed, .shared): CentralIcon("icon-check", size: 18).foregroundStyle(.white)
            case (.completed, .declined): glyph("icon-cross-small")
            case (.pending, _), (.expired, _): glyph("central-history")
            default: glyph("central-arrow-rotate-clockwise")
            }
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }

    private func glyph(_ name: String) -> some View {
        CentralIcon(name, size: 14).foregroundStyle(CommaTheme.textTertiary)
    }
}

private extension View {
    /// The design's shadow xs: 0 1 2, gray 900 (#101828) at 5%.
    func shadowXs() -> some View {
        shadow(color: Color(red: 16 / 255, green: 24 / 255, blue: 40 / 255).opacity(0.05), radius: 1, y: 1)
    }
}
