import SwiftUI

/// A screen's card in a message (a line that is only its `comma:screen/…` link): what it is, and a tap opens it live.
/// The tap opens the link, which the transcript turns into the screen's page (`ScreenLinkPage`).
struct ScreenLinkCard: View {
    let link: ScreenLinkRef
    @Environment(\.openURL) private var openURL
    @Environment(\.screenListings) private var listings
    /// The device the card first found there: another in its place later is not the one the message meant.
    @State private var meant: String?
    /// Whether any of the card shows in the transcript: its device is read only then, as reading wakes the computer's
    /// adb (the transcript lays out all its rows, so a card scrolled away keeps its task).
    @State private var shown = false

    private var ended: Bool {
        link.screen != "display" && Self.ended(listings?.rows[link.device], screen: link.screen, meant: meant)
    }

    /// A listing read without the device the card meant says it has ended (a computer's own screen is not listed).
    /// A failed read keeps the last listing, and none read yet (`rows` nil) says nothing.
    static func ended(_ rows: [ListedDeviceScreen]?, screen: String, meant: String?) -> Bool {
        guard let rows else { return false }
        return !rows.contains { $0.id == screen && (meant == nil || $0.instance == meant) }
    }

    var body: some View {
        Group {
            if ended { endedTag } else { card }
        }
        .onScrollVisibilityChange(threshold: 0.01) { shown = $0 }
        .task(id: ListenKey(device: link.device, shown: shown)) {
            guard shown, link.screen != "display", let listings else { return }
            // (ended once the device it meant is known stays ended: another boot is never that one)
            while !Task.isCancelled, !(meant != nil && ended) {
                await listings.read(link.device)
                if meant == nil, let there = listings.rows[link.device]?.first(where: { $0.id == link.screen }) {
                    meant = there.instance
                }
                try? await Task.sleep(for: ScreenListings.every)
            }
        }
    }

    private struct ListenKey: Equatable {
        let device: String
        let shown: Bool
    }

    private var endedTag: some View {
        HStack(spacing: 8) {
            CentralIcon("icon-devices", size: 16, relativeTo: .subheadline)
            Text("Screen ended").font(.subheadline)
        }
        .foregroundStyle(CommaTheme.textSecondary)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(CommaTheme.markdownTable, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var card: some View {
        Button {
            if let url = link.url { openURL(url) }
        } label: {
            HStack(spacing: 12) {
                CentralIcon("icon-devices", size: 20, relativeTo: .body)
                    .foregroundStyle(CommaTheme.textSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: link.label ?? ScreenLinkCard.kindName(link.screen))
                        .font(.body.weight(.medium)).foregroundStyle(CommaTheme.textPrimary)
                        .lineLimit(1)
                    Text("Open live").font(.subheadline).foregroundStyle(CommaTheme.textTertiary)
                }
                Spacer(minLength: 0)
                SettingsChevron()
            }
            .padding(CommaTheme.bubblePadding)
            .frame(maxWidth: 320, alignment: .leading)
            .background(CommaTheme.markdownTable, in: RoundedRectangle(cornerRadius: CommaTheme.bubbleRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: CommaTheme.bubbleRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(link.url == nil)
    }

    static func kindName(_ screen: String) -> String {
        if screen == "display" { return String(localized: "Computer screen") }
        if screen.hasPrefix("simulator:") { return String(localized: "iOS Simulator") }
        return String(localized: "Android device")
    }
}

/// The page a screen's link opens: the computer's own display as `PhoneScreenView` shows it, or a device it lists (a
/// simulator, an Android device) live over the mesh once the computer lists it running.
struct ScreenLinkPage: View {
    let scope: WorkspaceSettingsScope
    let link: ScreenLinkRef
    @State private var station: String?
    @State private var screen: ListedDeviceScreen?
    @State private var error: String?
    @State private var attempt = 0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if link.screen == "display" {
                PhoneScreenView(scope: scope, device: link.device).toolbar { close }
            } else if let screen {
                // (its own toolbar closes it)
                PhoneDeviceScreenView(scope: scope, device: link.device, station: station, screen: screen)
            } else if let error {
                SettingsPage { InlineError(message: error, retry: { attempt += 1 }) }
                    .pageTitle(verbatim: link.label ?? ScreenLinkCard.kindName(link.screen))
                    .toolbar { close }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).toolbar { close }
            }
        }
        .task(id: attempt) {
            guard link.screen != "display" else { return }
            await find()
        }
        .task(id: attempt) {
            guard link.screen != "display" else { return }
            await findStation()
        }
    }

    /// Closes the page while it shows no device of its own (the device's page has its own close).
    private var close: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .accessibilityLabel(Text("Close"))
        }
    }

    /// The computer's station (how this phone reaches it shows on the page), looked up beside `find` so that it never
    /// holds the page back.
    private func findStation() async {
        let workspace = scope.workspace.id, device = link.device
        let found = await scope.store.core.first(["topic": "devices", "prefer": workspace]) { value -> String? in
            guard let json = value as? NSDictionary, !json.bool("loading") else { return nil }
            return json.objects("devices").first { $0.string("device_id") == device }?.string("station_id") ?? ""
        }
        if let found, !found.isEmpty { station = found }
    }

    /// The device as the computer lists it.
    private func find() async {
        error = nil
        let device = link.device
        do {
            let answer = try await scope.call("devices.listScreens", ["device": device])
            let rows = answer.object?.objects("screens").compactMap(ListedDeviceScreen.init) ?? []
            if let found = rows.first(where: { $0.id == link.screen }) {
                screen = found
            } else {
                error = String(localized: "This device is not running on the computer now.")
            }
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// The devices each computer in a workspace lists (`devices.listScreens`), shared by the screen cards in its chats: a
/// card shows that its device has ended once a read no longer lists it. Read while a card shows, at most once each
/// `every` for a computer however many cards show it: a person has few computers, and a read is one request.
@MainActor @Observable final class ScreenListings {
    static let every: Duration = .seconds(5)
    private(set) var rows: [String: [ListedDeviceScreen]] = [:]
    @ObservationIgnored private let scope: WorkspaceSettingsScope
    @ObservationIgnored private var readAt: [String: ContinuousClock.Instant] = [:]
    @ObservationIgnored private var reading: Set<String> = []
    @ObservationIgnored private static var made: [String: ScreenListings] = [:]

    @ObservationIgnored private let boundary: Int

    private init(scope: WorkspaceSettingsScope) { self.scope = scope; boundary = scope.store.boundaryToken }

    /// The workspace's listings, one for each signed-in account's workspace.
    static func of(_ scope: WorkspaceSettingsScope) -> ScreenListings {
        let key = "\(ObjectIdentifier(scope.store).hashValue)/\(scope.workspace.id)"
        if let kept = made[key], kept.boundary == scope.store.boundaryToken { return kept }
        // (a new sign-in's listings replace the last one's: none of its rows are this account's)
        let listings = ScreenListings(scope: scope)
        made[key] = listings
        return listings
    }

    /// Reads `device`'s list, unless it was read within `every` or a read is under way. A failed read keeps the last.
    func read(_ device: String) async {
        let now = ContinuousClock.now
        if reading.contains(device) { return }
        if let at = readAt[device], now - at < Self.every { return }
        reading.insert(device)
        defer { reading.remove(device) }
        guard let answer = try? await scope.call("devices.listScreens", ["device": device]) else { return }
        readAt[device] = ContinuousClock.now
        rows[device] = answer.object?.objects("screens").compactMap(ListedDeviceScreen.init) ?? []
    }
}

extension EnvironmentValues {
    /// The workspace's device listings for the screen cards in a chat; none outside one.
    @Entry var screenListings: ScreenListings?
}
