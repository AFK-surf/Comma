import SwiftUI
import CommaCore

/// The Task status glyph and colour, shared by the app and the Live Activity extension.
extension TaskBucket {
    /// The dashed ring of a Task without a status to show, as the desktop's `taskNeutralIcon`.
    static let neutralIconName = "status-neutral"

    /// The desktop status glyph (Central Icons in `status-indicator`), as a template asset.
    var iconName: String {
        switch self {
        case .archived: Self.neutralIconName
        case .inProgress: "status-in-progress"
        case .needsReview: "status-needs-review"
        case .done: "status-done"
        case .cancelled: "status-cancelled"
        }
    }
    var tint: Color {
        switch self {
        case .needsReview: CommaTheme.attention
        case .done: CommaTheme.successPrimary
        case .cancelled: CommaTheme.cancelled
        default: CommaTheme.sidebarIcon
        }
    }
}
