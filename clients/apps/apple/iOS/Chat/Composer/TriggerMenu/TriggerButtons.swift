import SwiftUI
import CommaCore

/// The @ and / buttons beside the +, in the expanded composer's bottom row. Each puts its trigger at the caret,
/// which opens its menu as a typed one would; the selected button closes it again. They are glyphs on the field's
/// glass, like the + and Send there, and each answers its own touch with the tactile press while the card under
/// them stays still. They hide under the + card on the card's own spring, and leave the row where a menu would
/// have no room to open.
struct TriggerButtons: View {
    let pane: ConversationPane
    let menu: TriggerMenuModel
    /// The + card is out over this row: the buttons fade under it and take no touches.
    let cardOpen: Bool
    /// The menu's heights, to know whether it fits.
    var metrics = TriggerMenuMetrics()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let fits = menu.fits(metrics)
        ZStack {
            if fits {
                let open = cardOpen ? nil : menu.shown(in: pane.draftText, metrics: metrics)?.match.trigger
                HStack(spacing: 0) {
                    button(.mention, open: open)
                    button(.skill, open: open)
                }
                .transition(.opacity)
            }
        }
        .animation(CommaMotion.stateChange, value: fits)
        .opacity(cardOpen ? 0 : 1)
        .allowsHitTesting(!cardOpen)
        .accessibilityHidden(cardOpen)
        .animation(reduceMotion ? AttachmentMotion.reduced : AttachmentMotion.morph, value: cardOpen)
    }

    /// The @'s size for both. The slash is drawn over the @'s 18-unit span of the grid, so at this size it stands
    /// as tall as the @ and the + beside them and takes the @'s stroke, one weight with the glyph it matches.
    private static let glyph: CGFloat = 20

    private func button(_ trigger: ComposerTrigger, open: ComposerTrigger?) -> some View {
        let selected = open == trigger
        return Button { menu.tap(trigger, pane: pane) } label: {
            CentralIcon(trigger.icon, size: Self.glyph)
                .foregroundStyle(CommaTheme.textPrimary)
                .frame(width: 32, height: 32)
                // While its menu is open, the button holds the grey of a selection on glass.
                .background(CommaTheme.glassSelection.opacity(selected ? 1 : 0), in: Circle())
                .animation(CommaMotion.stateChange, value: selected)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(TactileButtonStyle(scale: 0.9))
        .accessibilityLabel(Text(trigger.label))
        .accessibilityIdentifier(trigger.identifier)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityShowsLargeContentViewer {
            CentralIcon(trigger.icon, size: Self.glyph)
            Text(trigger.label)
        }
    }
}

private extension ComposerTrigger {
    /// The @ is Central's IconAt; Central has no slash, so / is drawn on its grid, stroke and caps.
    var icon: String {
        switch self {
        case .mention: "central-at"
        case .skill: "composer-slash"
        }
    }

    var label: LocalizedStringResource {
        switch self {
        case .mention: "Mention a task"
        case .skill: "Use a skill"
        }
    }

    var identifier: String {
        switch self {
        case .mention: "composerMention"
        case .skill: "composerSkill"
        }
    }
}
