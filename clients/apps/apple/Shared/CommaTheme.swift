import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Comma design tokens for the native clients.
/// Values follow `clients/packages/ui/src/tokens` so the chat and shell match the desktop client.
enum CommaTheme {
    static let brandSolid = dynamic(light: 0x205BFF, dark: 0x3B7CFF)
    static let bubbleAssistant = dynamic(light: 0xF1F1F1, dark: 0x343538)
    static let bubbleCode = dynamic(light: 0xF5F5F5, dark: 0x27282B)
    static let textPrimary = dynamic(light: 0x1A1B1E, dark: 0xF6F6F6)
    static let textSecondary = dynamic(light: 0x4A4C50, dark: 0xD1D1D1)
    static let textTertiary = dynamic(light: 0x5B5E63, dark: 0xA4A5A9)
    static let textQuaternary = dynamic(light: 0x7F8286, dark: 0xA4A5A9)
    static let textPlaceholder = dynamic(light: 0xB6B8BB, dark: 0x7E8187)
    static let borderPrimary = dynamic(light: 0xDFE0E2, dark: 0x343538)
    static let borderSecondary = dynamic(light: 0xF1F1F1, dark: 0x27282B)
    static let bgPrimary = dynamic(light: 0xFFFFFF, dark: 0x0F0F10)
    static let bgSecondary = dynamic(light: 0xFAFAFA, dark: 0x18191B)
    static let bgTertiary = dynamic(light: 0xF5F5F5, dark: 0x27282B)
    static let bgDisabled = dynamic(light: 0xF5F5F5, dark: 0x27282B)
    static let bgWindow = dynamic(light: 0xF5F5F5, dark: 0x0F0F10)
    static let cardPrimary = dynamic(light: 0xFFFFFF, dark: 0x18191B)
    static let sidebarItem = dynamic(light: 0xDFE0E2, dark: 0x222326)
    static let sidebarIcon = dynamic(light: 0x7F8286, dark: 0xB6B8BB)
    static let agentAvatar = dynamic(light: 0x706FFC, dark: 0x9594FC)
    static let errorPrimary = dynamic(light: 0xD92D20, dark: 0xF97066)
    static let errorBorder = dynamic(light: 0xFDA29B, dark: 0xF97066)
    static let successPrimary = dynamic(light: 0x079455, dark: 0x47CD89)
    static let attention = Color(hex: 0xEAAA08)
    /// Markdown component tokens (`colors/components.ts`, `markdown`).
    static let markdownLink = dynamic(light: 0x3B7CFF, dark: 0x619EFF)
    static let markdownInlineCode = dynamic(light: 0x912018, dark: 0xF97066)
    static let markdownInlineCodeBackground = dynamic(light: 0xE8E8E8, dark: 0x27282B)
    static let markdownTable = dynamic(light: 0xF5F5F5, dark: 0x343538)
    static let markdownBorder = dynamic(light: 0xDFE0E2, dark: 0x4A4C50)
    static let markdownSurface = dynamic(light: 0xFFFFFF, dark: 0x18191B)

    /// Chat body text. Desktop uses 13/20 at a desk distance; iPhone keeps the same 20pt rhythm one step larger.
    static let messageFont = Font.system(size: 16)
    static let bubbleRadius: CGFloat = 20
    static let bubblePadding = EdgeInsets(top: 10, leading: 13, bottom: 10, trailing: 13)
    /// Avatar column: a 16pt mark with 4pt margin, plus spacing-md.
    static let avatarGutter: CGFloat = 32
    static let replyLineWidth: CGFloat = 2.5

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        #if os(iOS)
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
        #else
        Color(hex: dark)
        #endif
    }
}

/// Motion tokens from `clients/packages/ui/src/tokens/motion.ts`.
enum CommaMotion {
    /// iOS drawer curve: fast start, long even deceleration.
    static let drawer = Animation.timingCurve(0.32, 0.72, 0, 1, duration: 0.42)
    /// Shell rail fold spring (stiffness 275, damping 30, unit mass).
    static let railFold = Animation.interpolatingSpring(mass: 1, stiffness: 275, damping: 30)
    static let surfaceSmoothOut = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.75)
    static let stageExit = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.38)
    static let stateChange = Animation.easeInOut(duration: 0.15)
    static let spatialMove = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.2)
    /// Outgoing bubble position spring: response 0.44, damping ratio 0.99.
    static let sendPosition = Animation.spring(response: 0.44, dampingFraction: 0.99)
    /// Outgoing bubble width spring: response 0.34, damping ratio 0.86.
    static let sendWidth = Animation.spring(response: 0.34, dampingFraction: 0.86)
    /// Assistant arrival: 160ms strong ease-out from a 2pt drop and 58% opacity.
    static let assistantEntry = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.16)
    static let replyDraw: Double = 0.6
    static let feedbackIn = Animation.easeOut(duration: 0.12)
    /// The composer growing or shrinking by a line.
    static let composerLines = Animation.spring(response: 0.3, dampingFraction: 0.9)
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

#if os(iOS)
extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
#endif

/// The Comma brand mark. It is a protected brand shape, not an interface glyph.
struct CommaMark: View {
    var size: CGFloat = 48
    var body: some View {
        Image("CommaMark").renderingMode(.template).resizable().interpolation(.high)
            .frame(width: size, height: size).accessibilityHidden(true)
    }
}

/// Button press feedback shared by the shell: scale to 0.96 and settle back.
struct TactileButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.96
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(configuration.isPressed ? .easeOut(duration: 0.05) : .timingCurve(0.25, 0.3, 0.25, 1.32, duration: 0.15),
                       value: configuration.isPressed)
    }
}

/// Primary and secondary-gray buttons from the desktop design system (size lg).
struct CommaButtonStyle: ButtonStyle {
    enum Hierarchy { case primary, secondary }
    var hierarchy: Hierarchy = .primary
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(foreground)
            .background(background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                if hierarchy == .secondary {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(CommaTheme.borderPrimary, lineWidth: 1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private var foreground: Color {
        switch hierarchy {
        case .primary: isEnabled ? .white : CommaTheme.textPlaceholder
        case .secondary: isEnabled ? CommaTheme.textSecondary : CommaTheme.textPlaceholder
        }
    }
    private var background: Color {
        switch hierarchy {
        case .primary: isEnabled ? CommaTheme.brandSolid : CommaTheme.bgDisabled
        case .secondary: CommaTheme.bgPrimary
        }
    }
}
