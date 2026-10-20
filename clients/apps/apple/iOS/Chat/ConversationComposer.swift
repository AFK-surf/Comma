import SwiftUI
import CommaCore

/// The composer: attach button, growing field and Send, and while typing the @ and / menus. It is a view of its
/// own, so typing, the field growing a line and a finger on the + update only the composer, never the transcript
/// above it; the caret and the menus update only their own views.
struct ConversationComposer: View {
    let store: CommaStore
    let pane: ConversationPane
    let focus: FocusState<Bool>.Binding
    let flight: OutgoingFlightController
    /// Picked photos or files are still being read: the + shows progress until they reach the tray.
    let preparing: Bool
    /// The + button's card. Its surface lives on the model rather than in the conversation view, so opening and
    /// closing the card updates only the composer and the overlay.
    let button: AttachmentModel
    @State private var fieldHeight: CGFloat = 0
    /// A pre-task's prompt is playing its fill wave over the field, which hides its own text meanwhile.
    @State private var fillHidesText = false
    @State private var menu = TriggerMenuModel()
    /// VoiceOver returns here after a menu pick, instead of jumping from the row that went away.
    @AccessibilityFocusState private var fieldA11yFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var canAttach: Bool { !preparing && pane.target != nil && pane.attachmentRoom > 0 }

    /// Send waits for every attachment to upload; a failed one is retried or removed first.
    private var canSubmit: Bool {
        pane.canSend && !preparing && !pane.attachmentsBlockSend &&
            !(pane.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !hasDrafts)
    }

    /// Liquid Glass input: a separate attach button beside a field that grows line by line.
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Collapsed, the + sits beside a one-line field. Typing, the field grows into one card around it, as in
            // ChatGPT: the text takes a row of its own above the + and Send, which stay where they were.
            ZStack(alignment: .bottomLeading) {
                field
                plus
            }
            .commaGlassGroup(spacing: 8)
            .animation(CommaMotion.composerExpand, value: expanded)
        }
        .triggerMenu(store: store, pane: pane, model: menu, enabled: expanded && button.surface == nil,
                     returnFocus: { fieldA11yFocused = true })
        .animation(CommaMotion.stateChange, value: hasDrafts)
        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 8)
        // The composer never gives up its height: where the conversation has less room than it needs (an empty one
        // in landscape with the keyboard up), the conversation gives way, not the field and its row of buttons.
        .fixedSize(horizontal: false, vertical: true)
        // A panel takes the keyboard's place.
        .onChange(of: button.surface) { _, surface in
            if surface == .camera || surface == .photos { focus.wrappedValue = false }
        }
        // The router keeps this composer across conversations; a caret from the last one never fits the next.
        .onChange(of: ObjectIdentifier(pane)) { _, _ in menu.reset() }
        // Skills are read as the keyboard comes up, so the / menu opens on a loaded list.
        .onChange(of: expanded) { _, now in if now { Task { await store.skills.loadIfStale(store: store) } } }
    }

    /// Held, the + shows its press, and the menu grows out of it on release, as from any button.
    private var plus: some View {
        Button(action: openAttachments) {
            Group {
                if preparing { ProgressView().controlSize(.small) }
                else { CentralIcon("icon-plus", size: 22) }
            }
            .foregroundStyle(CommaTheme.textPrimary)
            .frame(width: 44, height: 44)
            // Expanded, the + is a glyph inside the card, mirroring Send in the opposite corner, so its own glass
            // melts into the card's. Not interactive glass: its touch tracking takes the touch from the button, so
            // the press shows and the menu never opens. `PlusButtonStyle` draws the press instead.
            .commaGlass(in: Circle(), shown: !expanded)
            .contentShape(Circle())
        }
        .buttonStyle(PlusButtonStyle(onGlass: !expanded))
        .disabled(!canAttach)
        .onChange(of: canAttach, initial: true) { _, now in button.canAttach = now }
        .opacity(canAttach ? 1 : 0.5)
        // While the card is out it is this button's glass grown into the menu; the two cross-fade on one spring.
        .opacity(button.surface == nil ? 1 : 0)
        .animation(reduceMotion ? AttachmentMotion.reduced : AttachmentMotion.morph, value: button.surface == nil)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            button.liveFrame = frame
            if button.surface != nil { button.pinAnchor() }
        }
        .accessibilityLabel("Add attachment")
    }

    private func openAttachments() {
        button.pinAnchor()
        button.surface = .menu
    }

    /// The composer is expanded while the keyboard is up, and while attachments or Routine items wait in it, which
    /// it holds above the text as ChatGPT's does.
    private var expanded: Bool { focus.wrappedValue || hasDrafts }
    private var hasDrafts: Bool { !pane.drafts.isEmpty || !pane.draftTexts.isEmpty }
    /// Expanded in a compact height (an iPhone in landscape, where the keyboard leaves about 200pt), the card keeps
    /// to one row, as Messages does there: the text runs between the + and Send, at most two lines, and the
    /// conversation keeps room above it. A menu could not open in that room, so @ and / stay out of the row.
    /// Attachments always stack, since their tiles need the card's height.
    private var inline: Bool { expanded && verticalSizeClass == .compact && !hasDrafts }
    /// Expanded in a regular height, the card stacks the text over a row of buttons.
    private var stacked: Bool { expanded && !inline }
    private var fieldRadius: CGFloat { expanded ? 24 : 22 }

    /// The text and Send on one glass surface. Stacked it measures 92pt with one line, like ChatGPT's: 16pt
    /// above the text, and a 44pt row below it for the + (laid over it), @, / and Send.
    private var field: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(alignment: .leading, spacing: 0) {
                if hasDrafts {
                    AttachmentTray(pane: pane)
                        .padding(.top, 10)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9, anchor: .topLeading)))
                }
                TextField("", text: menu.textBinding(for: pane), selection: menu.selectionBinding(for: pane),
                          prompt: Text(pane.replyThread != nil ? "Reply in thread"
                                       : pane.isTask ? "Reply to this task" : "Message Comma")
                            .foregroundStyle(CommaTheme.textPlaceholder),
                          axis: .vertical)
                    .font(.body).foregroundStyle(fillHidesText ? Color.clear : CommaTheme.textPrimary)
                    .autocorrectionDisabled()
                    .lineLimit(inline ? 1...2 : 1...6).focused(focus)
                    .accessibilityFocused($fieldA11yFocused)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGPoint.self) { $0.frame(in: .chat).origin } action: { flight.composerTextOrigin = $0 }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        // The field follows each added or removed line on a short spring instead of jumping.
                        if fieldHeight == 0 { fieldHeight = height }
                        else if abs(height - fieldHeight) > 0.5 { withAnimation(CommaMotion.composerLines) { fieldHeight = height } }
                    }
                    .frame(height: fieldHeight > 0 ? fieldHeight : nil, alignment: .top)
                    .clipped()
                    .draftFillReveal(pane: pane, active: expanded, visibleHeight: fieldHeight, hidesText: $fillHidesText,
                                     landed: { menu.placeCaretAtEnd(of: pane) })
                    .padding(.top, stacked ? (hasDrafts ? 12 : 16) : 11).padding(.bottom, stacked ? 54 : 11)
                    .padding(.leading, inline ? 44 : stacked ? 14 : 16).padding(.trailing, stacked ? 14 : 44)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("chatComposer")
            }
            // A picked Task, command or skill reads in the brand colour, as what goes as a pick.
            .pickTint(text: pane.draftText, ranges: pane.pickRanges(in: pane.draftText), hidden: fillHidesText,
                      rangesIn: { pane.pickRanges(in: $0) })
            Button(action: send) {
                CentralIcon("central-arrow-up", size: 18)
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(canSubmit ? CommaTheme.brandSolid : CommaTheme.textPlaceholder, in: Circle())
                    .scaleEffect(canSubmit ? 1 : 0.92)
                    .animation(CommaMotion.stateChange, value: canSubmit)
                    // The visible circle is 32pt; the touch target is the full 44pt corner.
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(TactileButtonStyle(scale: 0.9))
            .disabled(!canSubmit)
            .accessibilityLabel("Send message").accessibilityIdentifier("sendMessage")
        }
        .frame(minHeight: 44)
        // Typing, @ and / join the + in the bottom row: glyphs on the card's glass, like Send, so the glass draws
        // under them rather than over them.
        .overlay(alignment: .bottomLeading) {
            if stacked {
                TriggerButtons(pane: pane, menu: menu, cardOpen: button.surface != nil)
                    .padding(.leading, 44)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.85, anchor: .leading)))
            }
        }
        // Collapsed, the field is the button that starts a message, and its glass answers the touch. Expanded, it is
        // a card of controls: +, @, / and Send each answer their own touch, and the card stays still under them
        // rather than swelling for every tap (interactive glass answers any touch inside its shape).
        .commaGlass(in: RoundedRectangle(cornerRadius: fieldRadius, style: .continuous), interactive: !expanded)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .chat) } action: { flight.composerFrame = $0 }
        // Collapsed, the + stands outside the glass: its 44pt and the 8pt between them.
        .padding(.leading, expanded ? 0 : 52)
    }

    /// The composer surface lifts off as the sent bubble; delivery runs underneath it.
    private func send() {
        guard canSubmit, let attempt = pane.enqueueSend() else { return }
        if !reduceMotion, !attempt.text.isEmpty { flight.launch(id: attempt.id, text: attempt.text, radius: fieldRadius) }
        Task { await pane.deliver(attempt) }
    }
}

/// The +'s press. On its own glass it lights the glass and swells it, as interactive glass does; as a glyph on the
/// expanded card it presses in, like Send.
private struct PlusButtonStyle: ButtonStyle {
    let onGlass: Bool

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .overlay { Circle().fill(Color.white.opacity(pressed && onGlass ? 0.22 : 0)).blendMode(.plusLighter) }
            .scaleEffect(pressed ? (onGlass ? 1.15 : 0.9) : 1)
            .animation(pressed ? .spring(response: 0.2, dampingFraction: 0.7) : .spring(response: 0.35, dampingFraction: 0.6),
                       value: pressed)
    }
}
