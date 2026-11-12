import SwiftUI

struct MiniAppCardValue: Identifiable, Equatable, Sendable {
    let appID: String
    let version: Int
    let name: String
    let summary: String
    let conversationID: String
    var id: String { appID + ":" + String(version) + ":" + conversationID }

    init?(_ json: NSDictionary) {
        guard let app = json.string("appId"), !app.isEmpty, let version = json.int("appVersion"), version > 0,
              let conversation = json.string("conversationId") else { return nil }
        appID = app; self.version = version; conversationID = conversation
        name = json.string("name") ?? String(localized: "App"); summary = json.string("summary") ?? ""
    }
}

/// A launch card, not a background WebView. Only an explicit press starts the restricted preview.
struct MiniAppChatCard: View {
    let app: MiniAppCardValue
    let open: () -> Void
    @Environment(\.inlineTaskStore) private var store

    var body: some View {
        Button(action: open) {
            SurfaceGroup {
                if let store, let workspace = store.workspace {
                    MiniAppArtwork(store: store, url: "/v1/comma/apps/\(app.appID)/screenshots/0?v=\(app.version)", via: ["workspace": workspace.id])
                        .frame(maxWidth: .infinity)
                    HStack {
                        MiniAppArtwork(store: store, url: "/v1/comma/apps/\(app.appID)/icon?v=\(app.version)", via: ["workspace": workspace.id], icon: true)
                        SettingsRow(Text(app.name), value: Text("v\(app.version)")) { SettingsChevron() }
                    }.padding(.leading, GroupedSurface.margin)
                } else {
                    SettingsRow(Text(app.name), icon: "icon-square-grid", value: Text("v\(app.version)")) { SettingsChevron() }
                }
                if !app.summary.isEmpty { SettingsRow(Text(app.summary)).lineLimit(3) }
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the preview of version \(app.version)")
        .accessibilityIdentifier("mini-app-preview-" + app.appID)
    }
}
