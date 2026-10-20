import SwiftUI
import CommaCore

/// One field's options, as a sheet stacked over the filters: the options chosen when it opens lead in their
/// own group and the rest follow in a second one. Checkboxes apply as they are tapped, and the order holds
/// while the sheet is open, so a row never moves under the finger.
struct TaskFilterOptionsPage: View {
    let field: TaskListFilter.Field
    @Binding var filter: TaskListFilter
    let choices: TaskFilterChoices
    @State private var detent: PresentationDetent = .large
    @State private var query = ""
    /// The options chosen when the sheet opened.
    @State private var leading: Set<String>?
    /// Counts the member's toggles, so only their changes play the selection haptic.
    @State private var toggles = 0

    var body: some View {
        let options = choices.options(field, in: filter)
        let selected = choices.selected(field, in: filter)
        let counts = choices.counts(field)
        let first = leading ?? selected
        let visible = options.filter { query.isEmpty || $0.name.localizedStandardContains(query) }
        VStack(spacing: 0) {
            FilterSearchField(prompt: "Filter…", text: $query) { if $0 { detent = .large } }
                .padding(.horizontal, GroupedSurface.margin).padding(.top, GroupedSurface.margin)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    FilterCaption(Text(field.title))
                    VStack(spacing: GroupedSurface.groupSpacing) {
                        ForEach([true, false], id: \.self) { leads in
                            let rows = visible.filter { first.contains($0.id) == leads }
                            if !rows.isEmpty {
                                SurfaceGroup {
                                    ForEach(rows) { option in
                                        FilterOptionRow(option: option, selected: selected.contains(option.id),
                                                        count: counts[option.id] ?? 0) { toggle(option.id) }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, GroupedSurface.margin).padding(.bottom, 24)
            }
            // Centred in the room under the search field and above the keyboard.
            .overlay { if visible.isEmpty { FilterNoResults() } }
        }
        .filterSheet(detent: $detent)
        .sensoryFeedback(.selection, trigger: toggles)
        .onAppear { if leading == nil { leading = selected } }
    }

    private func toggle(_ id: String) {
        filter = choices.toggling(id, of: field, in: filter)
        toggles += 1
    }
}
