import SwiftUI

/// An Agent's request to the person, drawn as a card in the question card's shell, as the Android app draws it. The
/// server decides how it ends; the card shows what the core says, so every device shows the same ending. On a phone it
/// says only what is asked and why: authorizing opens the provider's page in the browser, whose verified answer ends
/// the request; declining asks the core. A status line shows only after the person acted. At its deadline the card
/// closes into its receipt.
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
    @Environment(\.openURL) private var openURL
    @Environment(\.displayScale) private var displayScale

    private var opened: Bool { pane.openedRequests.contains(request.id) }
    private var card: RoundedRectangle { RoundedRectangle(cornerRadius: 20, style: .continuous) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                mark
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connect \(request.providerName)").font(.headline).foregroundStyle(CommaTheme.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    if !request.reason.isEmpty {
                        Text(request.reason).font(.subheadline).foregroundStyle(CommaTheme.textSecondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding([.horizontal, .top], 16)
            if let status {
                status.font(.footnote).foregroundStyle(CommaTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16).padding(.top, 8)
            }
            ThirdsLayout(spacing: 8) {
                Button("Decline", action: decline)
                    .buttonStyle(CommaButtonStyle(hierarchy: .secondary))
                    .disabled(declining)
                Button(opened ? "Open again" : "Authorize in browser", action: authorize)
                    .buttonStyle(CommaButtonStyle())
                    .disabled(request.authorizationURL == nil)
            }
            .padding(8).padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CommaTheme.bgSecondary, in: card)
        .overlay(card.strokeBorder(CommaTheme.borderPrimary, lineWidth: 1 / displayScale))
        .shadowXs()
        .accessibilityElement(children: .contain)
    }

    /// The account's mark on a bordered, lightly shadowed tile beside the title; monochrome marks (GitHub) follow the
    /// text colour.
    private var mark: some View {
        let tile = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return Group {
            if let image = ProviderArtwork.image(request.provider) {
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
        if opened { return Text("Finish authorizing in your browser…") }
        return nil
    }

    private func authorize() {
        guard let url = request.authorizationURL else { return }
        pane.openedRequests.insert(request.id)
        openURL(url)
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
    private var connected: Bool { request.status == .completed && request.outcome == .connected }

    var body: some View {
        HStack(spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text("Connect \(request.providerName)").font(.footnote).foregroundStyle(CommaTheme.textTertiary)
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
        case (.completed, .connected):
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
            case (.completed, .connected): CentralIcon("icon-check", size: 18).foregroundStyle(.white)
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
