import SwiftUI

/// The task section's title, which names the statuses shown, and one glass capsule holding the filters, with
/// how many narrow the list besides status, and the archive. The title is the app's one section-header
/// style (`.subheadline` semibold in the quaternary text colour), shared with the filter sheet's captions.
struct HomeTaskHeader: View {
    let query: HomeTaskQuery
    /// Its `pending` status names the section while the strip of pages is on its way there.
    let pager: HomeTaskPager
    let openFilters: () -> Void
    let openArchive: () -> Void

    var body: some View {
        HStack {
            // The name changes at once: a crossfade between two names leaves a ghost of the old one.
            Text(pager.pending.map { String(localized: $0.label) } ?? query.title)
                .font(.subheadline.weight(.semibold)).foregroundStyle(CommaTheme.textQuaternary)
                .contentTransition(.identity)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 12)
            HStack(spacing: 0) {
                Button(action: openFilters) {
                    HStack(spacing: 4) {
                        CentralIcon("icon-filter")
                        if query.appliedCount > 0 {
                            Text(query.appliedCount, format: .number).font(.body.weight(.medium).monospacedDigit())
                                .contentTransition(.numericText())
                        }
                    }
                    .padding(.leading, 12).padding(.trailing, 8).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                }
                .accessibilityLabel("Filters")
                .accessibilityValue(query.appliedCount > 0 ? Text("\(query.appliedCount) applied") : Text(verbatim: ""))
                .accessibilityShowsLargeContentViewer { Label("Filters", image: "icon-filter") }
                .accessibilityIdentifier("openTaskFilters")
                Button(action: openArchive) {
                    CentralIcon("icon-archive")
                        .padding(.leading, 8).padding(.trailing, 12).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                }
                .accessibilityLabel("Archived tasks")
                .accessibilityShowsLargeContentViewer { Label("Archived tasks", image: "icon-archive") }
                .accessibilityIdentifier("openArchivedTasks")
            }
            // Each button answers its own touch. Plain glass, as the status switcher's: the interactive kind would
            // light the whole capsule under either button.
            .buttonStyle(TactileButtonStyle(scale: 0.92))
            .foregroundStyle(CommaTheme.textPrimary)
            .commaGlass(in: Capsule())
            .animation(CommaMotion.stateChange, value: query.appliedCount)
        }
        .padding(.leading, 20).padding(.trailing, 16).padding(.top, 12).padding(.bottom, 4)
    }
}
