import SwiftUI

/// The app's tabs, in tab-bar order, and how each one presents itself. A new tab is a case here with its
/// presentation and its page in `ShellTabs`, which puts them in the system tab bar.
enum AppTab: String, Hashable, CaseIterable {
    case home, inbox, apps, settings

    /// The tab's name: the bar's title for it, which VoiceOver reads.
    var title: String {
        switch self {
        case .home: String(localized: "Home")
        case .inbox: String(localized: "Inbox")
        case .apps: String(localized: "Apps")
        case .settings: String(localized: "Settings")
        }
    }

    /// The tab's Central glyph, synced with the desktop's. The bar uses a filled (`-fill`) asset for selection
    /// where one exists. Apps keeps its grid glyph. Settings shows the avatar instead.
    var icon: String {
        switch self {
        case .home: "icon-home"
        case .inbox: "icon-inbox"
        case .apps: "icon-square-grid"
        case .settings: "central-people-circle"
        }
    }

    /// The bar shows the member's avatar for this tab instead of its glyph.
    var showsAvatar: Bool { self == .settings }

    /// The bar item's identifier, which the UI tests find it by.
    var identifier: String { "tab-\(rawValue)" }
}
