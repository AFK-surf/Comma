import SwiftUI
import CommaCore

extension View {
    /// The composer's @ and / menu, drawn over the conversation directly above this view, which it measures to
    /// keep the menu clear of the top of the conversation as it shows (`conversationViewport`). It takes no layout
    /// space: the transcript inset, the blur band and the send flight never move for it. `enabled` is false while
    /// the composer is collapsed or the + card is out; the menu also stays closed where a header and a row do not
    /// fit above the composer.
    func triggerMenu(store: CommaStore, pane: ConversationPane, model: TriggerMenuModel, enabled: Bool,
                     returnFocus: @escaping () -> Void) -> some View {
        modifier(TriggerMenuAnchor(model: model) {
            TriggerMenuLayer(store: store, pane: pane, model: model, enabled: enabled, returnFocus: returnFocus)
        })
    }
}

extension EnvironmentValues {
    /// The name of the coordinate space whose top is the top of the conversation as it shows, which the composer's
    /// menu never rises past; nil for the conversation's own (`.chat`). A host that shows less of the conversation
    /// than it lays out names its own frame for it, as the Task dock does: there an empty conversation in landscape
    /// grows up under the header.
    @Entry var conversationViewport: String?
}

/// Hangs the menu above the composer and measures the room it has there.
private struct TriggerMenuAnchor<Menu: View>: ViewModifier {
    let model: TriggerMenuModel
    @ViewBuilder let menu: Menu
    @Environment(\.conversationViewport) private var viewport

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) { menu.alignmentGuide(.top) { $0[.bottom] } }
            .onGeometryChange(for: CGFloat.self) { [viewport] proxy in
                proxy.frame(in: viewport.map { NamedCoordinateSpace.named($0) } ?? .chat).minY.rounded()
            } action: { model.spaceAbove = $0 }
    }
}

/// Opens the menu for the trigger before the caret and closes it when there is none. Only this view and the
/// buttons read the caret, and only this view the Tasks and skills, so a caret move or a catalog refresh re-renders
/// nothing else.
private struct TriggerMenuLayer: View {
    let store: CommaStore
    let pane: ConversationPane
    let model: TriggerMenuModel
    let enabled: Bool
    let returnFocus: () -> Void
    /// The row and header heights, kept on the view so they follow Dynamic Type.
    var metrics = TriggerMenuMetrics()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shown = enabled ? model.shown(in: pane.draftText, metrics: metrics) : nil
        let match = shown?.match
        ZStack(alignment: .bottom) {
            if let match, let cap = shown?.cap {
                let isRouter = pane.kind == .router
                let input = TriggerMenuInput(tasks: store.tasks, tasksLoading: !store.tasksLoaded, skills: store.skills.catalog,
                                             skillsLoading: store.skills.loading, models: isRouter ? store.mentionModels.catalog : [],
                                             modelsLoading: isRouter && store.mentionModels.loading, isRouter: isRouter,
                                             excludedTaskID: pane.taskID, text: pane.draftText)
                // A model's efforts in place of the list, while the menu stays the one they were opened from.
                let efforts = model.effortsShown(in: pane.draftText).flatMap { id in input.models.first { $0.id == id } }
                TriggerMenuPanel(match: match,
                                 sections: efforts.map(TriggerMenuSources.effortSections)
                                     ?? TriggerMenuSources.sections(for: match, input: input),
                                 label: TriggerMenuSources.label(for: match.trigger, isRouter: input.isRouter),
                                 cap: cap, metrics: metrics,
                                 back: efforts.map { TriggerMenuBack(title: $0.name) { model.closeEfforts() } },
                                 choose: { item in
                                     model.choose(item, pane: pane)
                                     returnFocus()
                                 },
                                 browse: { item in model.showEfforts(of: item, in: pane.draftText) },
                                 dismiss: { model.dismiss(in: pane.draftText) })
                    .padding(.bottom, 8)
                    .transition(TriggerMenuMotion.transition(reduced: reduceMotion))
            }
        }
        // A send replaces the draft from outside the field and the + card disables the menu: both close it at
        // once, so it never lingers under the rising bubble or the growing card. Any close of the person's own
        // (a trigger taken away, even the draft's only character, a pick, Escape) plays the exit.
        .animation(TriggerMenuMotion.animation(open: match != nil, instant: !enabled || model.isFromOutside(pane.draftText),
                                               reduced: reduceMotion), value: match != nil)
        .onChange(of: pane.draftText) { old, new in model.textDidChange(from: old, to: new, pane: pane) }
        .onChange(of: match?.trigger) { _, trigger in
            if trigger == .skill { Task { await store.skills.loadIfStale(store: store) } }
            // The models are read the first time the router's @ menu opens, as on the desktop.
            if trigger == .mention, pane.kind == .router { store.mentionModels.follow(store: store) }
        }
    }
}
