import SwiftUI

/// The app's tabs, in tab-bar order, and how each one presents itself. A new tab is a case here with its
/// presentation and its page in `ShellTabs`, which puts them in the system tab bar.
enum AppTab: String, Hashable, CaseIterable {
    case home, inbox, people, apps, drive, plugins, settings

    /// The tab's name: the bar's title for it, which VoiceOver reads.
    var title: String {
        switch self {
        case .home: String(localized: "Home")
        case .inbox: String(localized: "Inbox")
        case .people: String(localized: "People")
        case .apps: String(localized: "Apps")
        case .drive: String(localized: "Drive")
        case .plugins: String(localized: "Plugins")
        case .settings: String(localized: "Settings")
        }
    }

    /// The tab's Central glyph, synced with the desktop's. The bar uses a filled (`-fill`) asset for selection
    /// where one exists. Settings shows the avatar instead.
    var icon: String {
        switch self {
        case .home: "icon-home"
        case .inbox: "icon-inbox"
        case .people: "icon-people"
        case .apps: "icon-square-grid"
        case .drive: "central-file-bend"
        case .plugins: "central-puzzle"
        case .settings: "central-people-circle"
        }
    }

    /// The bar shows the member's avatar for this tab instead of its glyph.
    var showsAvatar: Bool { self == .settings }

    /// On a wide screen the page lays out both shell columns: its list stands in the trailing column, then slides
    /// to the leading one, in place of Routines, while a detail opens beside it.
    var ownsShellColumns: Bool { self == .settings || self == .people }

    /// The tab is a row of the bar's menu, which grows out of its last slot, not a slot of its own.
    var inMenu: Bool {
        switch self {
        case .home, .inbox, .people: false
        case .apps, .drive, .plugins, .settings: true
        }
    }

    /// The tab the Apps page is on: its own from iOS 26, where the bar's menu holds it, and Settings' before.
    static var appsHost: AppTab { if #available(iOS 26.0, *) { .apps } else { .settings } }

    /// The system tab bar's tabs, before iOS 26: it has no menu, so the menu's other pages stay in Settings.
    static let systemBarTabs: [AppTab] = [.home, .inbox, .people, .settings]

    /// The bar item's identifier, which the UI tests find it by.
    var identifier: String { "tab-\(rawValue)" }
}
