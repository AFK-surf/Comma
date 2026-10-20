import SwiftUI

/// Where a Task was asked for, as on the desktop Task panel, with the same brand marks.
enum TaskOrigin: String {
    case slack, telegram, feishu, lark, wechat, signal, comma

    var label: String {
        switch self {
        case .slack: "Slack"
        case .telegram: "Telegram"
        case .feishu: String(localized: "Feishu")
        case .lark: "Lark"
        case .wechat: String(localized: "WeChat")
        case .signal: "Signal"
        case .comma: "Comma"
        }
    }

    /// The provider's own artwork in its colours; Comma's mark follows the text colour.
    var icon: some View { icon(size: 18) }

    /// `icon` in a `size` square, the artwork at the same proportions inside it.
    @ViewBuilder func icon(size: CGFloat) -> some View {
        switch self {
        case .comma:
            CommaMark(size: size * 15 / 18).foregroundStyle(CommaTheme.textPrimary).frame(width: size, height: size)
        default:
            Image(decorative: "provider-" + rawValue).resizable().scaledToFit()
                .frame(width: size * 16 / 18, height: size * 16 / 18).frame(width: size, height: size)
        }
    }
}
