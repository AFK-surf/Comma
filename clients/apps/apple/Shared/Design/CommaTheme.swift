import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Comma design tokens for the native clients.
/// Values follow `clients/packages/ui/src/tokens` so the chat and shell match the desktop client.
enum CommaTheme {
    static let brandSolid = dynamic(light: 0x205BFF, dark: 0x3B7CFF)
    static let bubbleAssistant = dynamic(light: 0xF1F1F1, dark: 0x343538)
    /// The assistant bubble over an open reply thread's blurred backdrop, which is about as light as the bubble
    /// itself: one step deeper, as the desktop's bg-tertiary.
    static let bubbleAssistantOverBlur = dynamic(light: 0xE4E5E7, dark: 0x44464A)
    static let bubbleCode = dynamic(light: 0xF5F5F5, dark: 0x27282B)
    /// An inline Task's pill: one step from the assistant bubble, as the desktop's bg-tertiary is from its page.
    static let inlineTaskPill = dynamic(light: 0xE4E5E7, dark: 0x44464A)
    static let textPrimary = dynamic(light: 0x1A1B1E, dark: 0xF6F6F6)
    static let textSecondary = dynamic(light: 0x4A4C50, dark: 0xD1D1D1)
    static let textTertiary = dynamic(light: 0x5B5E63, dark: 0xA4A5A9)
    /// Section headers and captions. Light is darker than the desktop's gray-500 (#7F8286, 3.9:1 on white), so
    /// 15pt semibold headers reach 4.5:1 on the page.
    static let textQuaternary = dynamic(light: 0x6F7276, dark: 0xA4A5A9)
    static let textPlaceholder = dynamic(light: 0xB6B8BB, dark: 0x7E8187)
    static let borderPrimary = dynamic(light: 0xDFE0E2, dark: 0x343538)
    static let borderSecondary = dynamic(light: 0xF1F1F1, dark: 0x27282B)
    /// The desktop's border-menu-primary: the outline of an unpicked radio or checkbox.
    static let borderMenuPrimary = dynamic(light: 0xB6B8BB, dark: 0x54565A)
    static let bgPrimary = dynamic(light: 0xFFFFFF, dark: 0x0F0F10)
    static let bgSecondary = dynamic(light: 0xFAFAFA, dark: 0x18191B)
    static let bgTertiary = dynamic(light: 0xF5F5F5, dark: 0x27282B)
    /// The desktop's bg-quaternary: the quiet fill of a property row, which the desktop shows on hover.
    static let bgQuaternary = dynamic(light: 0xF1F1F1, dark: 0x343538)
    static let bgDisabled = dynamic(light: 0xF5F5F5, dark: 0x27282B)
    static let bgWindow = dynamic(light: 0xF5F5F5, dark: 0x0F0F10)
    static let cardPrimary = dynamic(light: 0xFFFFFF, dark: 0x18191B)
    /// The colour the system's glass shows over the page, as the tab bar draws its circles: gray-50 in light,
    /// gray-700 in dark, within a step of the circle on screen in each.
    static let glassOverPage = dynamic(light: 0xFAFAFA, dark: 0x343538)
    static let sidebarItem = dynamic(light: 0xDFE0E2, dark: 0x222326)
    static let sidebarIcon = dynamic(light: 0x7F8286, dark: 0xB6B8BB)
    static let agentAvatar = dynamic(light: 0x706FFC, dark: 0x9594FC)
    static let errorPrimary = dynamic(light: 0xD92D20, dark: 0xF97066)
    static let errorBorder = dynamic(light: 0xFDA29B, dark: 0xF97066)
    static let successPrimary = dynamic(light: 0x079455, dark: 0x47CD89)
    static let attention = Color(hex: 0xEAAA08)
    /// A neutral action behind white text, such as the Inbox's Clear swipe: gray-700 in both appearances, 8.6:1
    /// with white, where the muted text colours would not hold the label.
    static let neutralAction = Color(hex: 0x4A4C50)
    /// Desktop `error-500`, the cancelled status glyph.
    static let cancelled = Color(hex: 0xF04438)
    /// Markdown component tokens (`colors/components.ts`, `markdown`).
    static let markdownLink = dynamic(light: 0x3B7CFF, dark: 0x619EFF)
    static let markdownInlineCode = dynamic(light: 0x912018, dark: 0xF97066)
    static let markdownInlineCodeBackground = dynamic(light: 0xE8E8E8, dark: 0x27282B)
    static let markdownTable = dynamic(light: 0xF5F5F5, dark: 0x343538)
    static let markdownBorder = dynamic(light: 0xDFE0E2, dark: 0x4A4C50)
    static let markdownSurface = dynamic(light: 0xFFFFFF, dark: 0x18191B)

    /// Type scale, the one source for every text size in the app. Text uses these Dynamic Type styles only,
    /// so it follows the reader's text size and SF's size-specific tracking and leading (default sizes in points):
    /// - `.title3` 20, semibold: every title. The sign-in title, page titles (`pageTitle(_:)`, the Home
    ///   greeting, sheets) and empty-state titles (`EmptyState`). No `.title`, `.title2`, `.largeTitle` or
    ///   large navigation titles.
    /// - `.body` 17, regular: messages, the composer, list rows, names, buttons; `.headline` 17 semibold
    ///   where a row's title needs weight
    /// - `.subheadline` 15: details, descriptions and errors; semibold section headers; medium pills and chips
    /// - `.footnote` 13: timestamps, sender names, counts, hints
    /// - `.caption` 12: badges only
    /// Same role, same style everywhere. Glyphs inside fixed-size controls keep point sizes. Chat body text is
    /// `.body`, as in Messages.
    static let messageFont = Font.body
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
    static let railFold = railFold(velocity: 0)
    /// The rail fold starting at a released gesture's speed, as a fraction of the remaining distance per
    /// second, so the drawer carries on at the finger's speed instead of starting from rest.
    static func railFold(velocity: Double) -> Animation {
        .interpolatingSpring(mass: 1, stiffness: 275, damping: 30, initialVelocity: velocity)
    }
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
    /// A reply thread lifting out of the transcript and settling back: each bubble travels to its new place on
    /// one spring, slightly underdamped so the gathered stack lands with the weight Messages gives it.
    static let replyThread = Animation.spring(response: 0.42, dampingFraction: 0.86)
    /// `replyThread`, or a crossfade under Reduce Motion.
    static func replyThread(reduced: Bool) -> Animation { reduced ? stateChange : replyThread }
    static let feedbackIn = Animation.easeOut(duration: 0.12)
    /// A pressed control returning to rest: critically damped, so it settles without a bounce.
    static let release = Animation.spring(response: 0.3, dampingFraction: 1)
    /// The composer growing or shrinking by a line.
    static let composerLines = Animation.spring(response: 0.3, dampingFraction: 0.9)
    /// The composer opening into its typing card as the keyboard rises, and closing as it falls: critically
    /// damped at the keyboard's own response, so the card rides the keyboard without overshooting it.
    static let composerExpand = Animation.spring(response: 0.34, dampingFraction: 1)
    /// A choice or a row settling where a tap put it: the tab bar's and the status switcher's pill, rows
    /// arriving and leaving. Critically damped, as a tap carries no momentum to overshoot with.
    static let settle = Animation.spring(response: 0.32, dampingFraction: 1)
    /// `settle`, or a crossfade under Reduce Motion.
    static func settle(reduced: Bool) -> Animation { reduced ? stateChange : settle }
    /// `settle` starting at a released finger's speed, as a fraction of the remaining distance per second, so what
    /// the finger let go of carries on at its pace.
    static func settle(velocity: Double) -> Animation {
        .interpolatingSpring(Spring(response: 0.32, dampingRatio: 1), initialVelocity: velocity)
    }
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

/// Button press feedback shared by the shell: shrink to `scale` the moment the finger lands, and settle back
/// on release without overshoot (a tap carries no momentum to bounce with). Glass buttons use
/// `GlassButtonStyle`, which leaves the response to the glass on iOS 26.
struct TactileButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.96
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(configuration.isPressed ? .easeOut(duration: 0.05) : CommaMotion.release,
                       value: configuration.isPressed)
    }
}

/// Primary and secondary-gray buttons from the desktop design system (size lg), in the capsule of the app's
/// fields. A press answers the moment the finger lands and settles back without a bounce. `compact` hugs its
/// label, for an action under content rather than across a form.
struct CommaButtonStyle: ButtonStyle {
    enum Hierarchy { case primary, secondary }
    var hierarchy: Hierarchy = .primary
    var compact = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(compact ? .subheadline.weight(.medium) : .body)
            .padding(.horizontal, compact ? 16 : 0)
            .frame(maxWidth: compact ? nil : .infinity, minHeight: compact ? 36 : 44)
            .foregroundStyle(foreground)
            .background(background, in: Capsule())
            .overlay {
                if hierarchy == .secondary { Capsule().strokeBorder(CommaTheme.borderPrimary, lineWidth: 1) }
            }
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(configuration.isPressed ? .easeOut(duration: 0.05) : CommaMotion.release, value: configuration.isPressed)
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
