import SwiftUI
import CommaCore

/// Filters for a Task list, drawn after the reference sheets: a search capsule, the applied filters as
/// rounded sentence rows, then every field in one group. A field opens its options as a second sheet stacked
/// on this one. Changes apply live to `filter`, which the list behind and the status switcher share.
/// `leading` adds rows above the applied filters, such as the Inbox's "Unread only" toggle; lay each one out
/// like `FilterOptionRow` (`surfaceRowFrame`), pressed with `SurfaceRowButtonStyle`.
struct TaskFilterSheet<Leading: View>: View {
    @Binding var filter: TaskListFilter
    let fields: [TaskListFilter.Field]
    let tasks: [TaskSummary]
    let labelCatalog: TaskLabelCatalog?
    let leading: Leading
    /// Opens large, as in the reference, so a field's options can stack over it with this sheet showing behind.
    @State private var detent: PresentationDetent = .large
    @State private var query = ""
    @State private var page: FieldPage?
    /// Counts toggles made from search results, so only the member's changes play the selection haptic.
    @State private var toggles = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(filter: Binding<TaskListFilter>, fields: [TaskListFilter.Field], tasks: [TaskSummary],
         labelCatalog: TaskLabelCatalog?, @ViewBuilder leading: () -> Leading) {
        _filter = filter
        self.fields = fields
        self.tasks = tasks
        self.labelCatalog = labelCatalog
        self.leading = leading()
    }

    var body: some View {
        let choices = TaskFilterChoices(tasks: tasks, labelCatalog: labelCatalog)
        // A field with nothing to choose from (no labels yet, no platforms) stays hidden.
        let available = fields.filter { !choices.options($0, in: filter).isEmpty }
        VStack(spacing: 0) {
            FilterSearchField(prompt: "Search all filters", text: $query) { if $0 { detent = .large } }
                .padding(.horizontal, GroupedSurface.margin).padding(.top, GroupedSurface.margin)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if query.isEmpty {
                        browsing(available, choices: choices)
                    } else {
                        results(available, choices: choices)
                    }
                }
                .padding(.horizontal, GroupedSurface.margin).padding(.bottom, 24)
                // Every edit, from here, the stacked options or the switcher, moves the rows the same way.
                .animation(CommaMotion.settle(reduced: reduceMotion), value: filter)
            }
            // Centred in the room under the search field and above the keyboard, which the scroll view fills even
            // with no rows to size it.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay { if !query.isEmpty, matchesNothing(available, choices: choices) { FilterNoResults() } }
        }
        .sheet(item: $page) { page in
            TaskFilterOptionsPage(field: page.field, filter: $filter, choices: choices)
        }
        .filterSheet(detent: $detent)
        .sensoryFeedback(.selection, trigger: toggles)
    }

    /// The leading rows, the applied filters and every field.
    @ViewBuilder
    private func browsing(_ available: [TaskListFilter.Field], choices: TaskFilterChoices) -> some View {
        if Leading.self != EmptyView.self {
            SurfaceGroup { leading }.padding(.top, GroupedSurface.margin)
        }
        let applied = filter.narrowedFields.filter(fields.contains)
        if !applied.isEmpty {
            VStack(spacing: 0) {
                FilterCaption(title: Text("Applied filters")) {
                    if applied.count > 1 { clearAll }
                }
                VStack(spacing: GroupedSurface.groupSpacing) {
                    ForEach(applied, id: \.self) { field in
                        AppliedFilterRow(field: field, chosen: choices.chosen(field, in: filter),
                                         open: { page = FieldPage(field: field) },
                                         remove: { filter = filter.clearing(field) })
                            .transition(rowTransition)
                    }
                }
            }
            .transition(rowTransition)
        }
        fieldGroup(available)
    }

    /// The fields whose names match the search, then each field's matching options, ready to check.
    @ViewBuilder
    private func results(_ available: [TaskListFilter.Field], choices: TaskFilterChoices) -> some View {
        let named = available.filter { String(localized: $0.title).localizedStandardContains(query) }
        let matching = available.map { field in
            choices.options(field, in: filter).filter { $0.name.localizedStandardContains(query) }
        }
        fieldGroup(named)
        ForEach(Array(zip(available, matching)), id: \.0) { field, options in
            if !options.isEmpty {
                let selected = choices.selected(field, in: filter)
                FilterCaption(Text(field.title))
                SurfaceGroup {
                    ForEach(options) { option in
                        FilterOptionRow(option: option, selected: selected.contains(option.id)) {
                            filter = choices.toggling(option.id, of: field, in: filter)
                            toggles += 1
                        }
                    }
                }
            }
        }
    }

    /// The search names no field and no option of any.
    private func matchesNothing(_ available: [TaskListFilter.Field], choices: TaskFilterChoices) -> Bool {
        !available.contains { field in
            String(localized: field.title).localizedStandardContains(query)
                || choices.options(field, in: filter).contains { $0.name.localizedStandardContains(query) }
        }
    }

    @ViewBuilder
    private func fieldGroup(_ shown: [TaskListFilter.Field]) -> some View {
        if !shown.isEmpty {
            FilterCaption(Text("All filters"))
            SurfaceGroup {
                ForEach(shown, id: \.self) { field in
                    FieldRow(field: field) { page = FieldPage(field: field) }
                }
            }
        }
    }

    private var clearAll: some View {
        Button("Clear all") { filter = TaskListFilter() }
            .foregroundStyle(CommaTheme.textSecondary)
            .contentShape(.interaction, Rectangle().inset(by: -12))
            .accessibilityIdentifier("clearAllFilters")
    }

    /// Applied rows grow in from their top edge. A removed one fades out quickly, before the rows below
    /// have slid into its place, so the two never read on top of each other. Under Reduce Motion rows only fade.
    private var rowTransition: AnyTransition {
        .asymmetric(insertion: reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96, anchor: .top)),
                    removal: .opacity.animation(.easeOut(duration: 0.1)))
    }
}

extension TaskFilterSheet where Leading == EmptyView {
    init(filter: Binding<TaskListFilter>, fields: [TaskListFilter.Field], tasks: [TaskSummary],
         labelCatalog: TaskLabelCatalog?) {
        self.init(filter: filter, fields: fields, tasks: tasks, labelCatalog: labelCatalog) { EmptyView() }
    }
}

/// The field whose options sheet is open.
private struct FieldPage: Identifiable {
    let field: TaskListFilter.Field
    var id: String { field.rawValue }
}

/// A field in the "All filters" group: the desktop's glyph and the field's name. It opens the options.
private struct FieldRow: View {
    let field: TaskListFilter.Field
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                CentralIcon(field.iconName, relativeTo: .body)
                    .foregroundStyle(CommaTheme.textSecondary)
                Text(field.title).font(.body).foregroundStyle(CommaTheme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .surfaceRowFrame(vertical: 0)
        }
        .buttonStyle(SurfaceRowButtonStyle())
        .accessibilityIdentifier("filterField-" + field.rawValue)
    }
}
