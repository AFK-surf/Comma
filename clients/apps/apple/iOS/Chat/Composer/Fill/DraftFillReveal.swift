import SwiftUI

extension View {
    /// Reveals a pre-task's prompt (`ConversationPane.draftFill`) as it lands in the composer's field: once the
    /// keyboard is up and the card has settled at its typing width, a copy of the draft laid out as the field lays
    /// out its text plays the fill wave over the field, whose own text is hidden meanwhile; the caret stays. Apply
    /// it to the field's text frame. Typing, a send, the keyboard going down or another conversation ends it at once.
    /// `landed` runs as the field takes the filled draft, to put the caret after the filled text.
    func draftFillReveal(pane: ConversationPane, active: Bool, visibleHeight: CGFloat, hidesText: Binding<Bool>,
                         landed: @escaping () -> Void) -> some View {
        modifier(DraftFillReveal(pane: pane, active: active, visibleHeight: visibleHeight, hidesText: hidesText,
                                 landed: landed))
    }
}

/// When the field's frame last changed.
private final class FieldMotion {
    var movedAt = ContinuousClock.now
}

/// One reveal: the draft as it was filled, and where the filled text starts.
private struct DraftFillPlayback: Equatable {
    let id: UUID
    let draft: String
    let prefix: String
    let inserted: String

    init(_ fill: DraftFill, draft: String) {
        id = fill.id
        self.draft = draft
        inserted = fill.inserted
        prefix = String(draft.dropLast(fill.inserted.count))
    }
}

private struct DraftFillReveal: ViewModifier {
    let pane: ConversationPane
    let active: Bool
    let visibleHeight: CGFloat
    @Binding var hidesText: Bool
    let landed: () -> Void
    @State private var playback: DraftFillPlayback?
    @State private var motion = FieldMotion()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The card opens into its typing width as the keyboard rises, and the copy has to sit on the text where it
    /// settles: the reveal starts once the field has held still this long.
    private static let stillness: Duration = .milliseconds(120)
    /// It gives up waiting after this long, as the fill goes stale.
    private static let settleLimit: Duration = .milliseconds(1500)

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topLeading) {
                if let playback {
                    DraftFillCopy(playback: playback, visibleHeight: visibleHeight, reduced: reduceMotion,
                                  reveal: { hidesText = true }, finish: stop)
                        .id(playback.id)
                }
            }
            // Plain bookkeeping, not state: following the field's frame never updates a view.
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { _ in motion.movedAt = .now }
            .task(id: active ? pane.draftFill?.id : nil) { await start() }
            .onChange(of: pane.draftText) { _, text in if let playback, text != playback.draft { stop() } }
            .onChange(of: active) { _, now in if !now { stop() } }
            .onChange(of: ObjectIdentifier(pane)) { _, _ in stop() }
    }

    private func start() async {
        guard active, let fill = pane.draftFill else { return }
        if fill.applies(to: pane.draftText) { landed() }
        let deadline = ContinuousClock.now + Self.settleLimit
        repeat {
            try? await Task.sleep(for: .milliseconds(40))
        } while !Task.isCancelled && .now - motion.movedAt < Self.stillness && .now < deadline
        guard !Task.isCancelled, active, pane.draftFill == fill else { return }
        pane.draftFill = nil
        guard fill.applies(to: pane.draftText) else { return }
        playback = DraftFillPlayback(fill, draft: pane.draftText)
    }

    /// Back to the field's own text, in the same frame as the copy goes.
    private func stop() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            playback = nil
            hidesText = false
        }
    }
}

/// The draft drawn over the field with the fill wave. It is measured before it shows: where the draft is taller
/// than the field shows (the field scrolls past six lines), the copy could not sit on the field's text, and the
/// reveal ends without showing.
private struct DraftFillCopy: View {
    let playback: DraftFillPlayback
    let visibleHeight: CGFloat
    let reduced: Bool
    let reveal: () -> Void
    let finish: () -> Void
    @State private var shown = false
    @State private var progress = 0.0
    @ScaledMetric(relativeTo: .body) private var em: CGFloat = 17

    var body: some View {
        text
            .font(.body).foregroundStyle(CommaTheme.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .textRenderer(DraftFillRenderer(progress: progress, em: em, reduced: reduced, tint: CommaTheme.brandSolid))
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                guard !shown else { return }
                guard height <= visibleHeight + 1 else { return finish() }
                shown = true
                reveal()
                withAnimation(.linear(duration: reduced ? DraftFillWave.fadeDuration : DraftFillWave.duration)) {
                    progress = 1
                } completion: { finish() }
            }
    }

    /// The draft as one Text with the filled part marked. The key is built at run time, not from a literal, so it
    /// is no entry for the string catalog; its format is just the two parts.
    private var text: Text {
        var parts = LocalizedStringKey.StringInterpolation(literalCapacity: 0, interpolationCount: 2)
        parts.appendInterpolation(Text(verbatim: playback.prefix))
        parts.appendInterpolation(Text(verbatim: playback.inserted).customAttribute(DraftFillMark()))
        return Text(LocalizedStringKey(stringInterpolation: parts))
    }
}
