import SwiftUI
import CommaCore

/// The Inbox tab: Tasks that finished or need the member's review, newest first by day. Read, unread and
/// cleared are this device's marks, as on the desktop. A row opens its Task, swipes read, clear or archive
/// it, and the toolbar filters the list or acts on every row it shows. Tapping the tab again scrolls to
/// the top.
struct InboxView: View {
    let store: CommaStore
    @Environment(InboxModel.self) private var inbox
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var filtersOpen = false
    @State private var confirmingClearAll = false
    @State private var undo: InboxUndo?
    @State private var renaming: TaskSummary?
    @State private var sharing: TaskSummary?

    var body: some View {
        let rows = inbox.rows(tasks: store.tasks)
        let days = InboxProjection.days(rows, calendar: .current)
        let actions = InboxActions(store: store, inbox: inbox) { undo = $0 }
        NavigationStack {
            ScrollViewReader { scroller in
                List {
                    // Day headers scroll with their rows: pinned plain-list headers have no surface of their own
                    // on iOS 26, so rows passing under one would show through it.
                    ForEach(days) { day in
                        dayHeader(day.id).id(day.id)
                        ForEach(day.tasks) { task in row(task, actions: actions) }
                    }
                    footer
                }
                .listStyle(.plain)
                // Rows keep their own 44pt minimum, as on Home.
                .environment(\.defaultMinListRowHeight, 44)
                .scrollContentBackground(.hidden)
                .background(CommaTheme.bgPrimary)
                .animation(CommaMotion.settle(reduced: reduceMotion), value: inbox.filter)
                .animation(CommaMotion.settle(reduced: reduceMotion), value: inbox.unreadOnly)
                // Rows that arrive or leave by themselves (an archive, a refresh, Undo) settle rather than jump.
                .animation(CommaMotion.settle(reduced: reduceMotion), value: rows.map(\.id))
                // Centred in the page rather than placed as a row, so it stands where the rows would be.
                .overlay { if showsEmpty(rows) { empty } }
                .refreshable { await store.refresh() }
                .onChange(of: navigation.reselect[.inbox]) { _, _ in
                    guard let first = days.first?.id else { return }
                    withAnimation(CommaMotion.spatialMove) { scroller.scrollTo(first, anchor: .top) }
                }
            }
            .pageTitle("Inbox")
            .toolbar { toolbar(rows: rows, actions: actions) }
        }
        .sheet(isPresented: $filtersOpen) { filters }
        .taskActionSheets(store: store, renaming: $renaming, sharing: $sharing)
        .inboxUndoToast($undo, perform: actions.undo)
    }

    private func row(_ task: TaskSummary, actions: InboxActions) -> some View {
        let unread = inbox.isUnread(task)
        return InboxRow(task: task, unread: unread, pinned: store.pinnedTaskIDs.contains(task.id)) { actions.open(task) }
            .inboxRowActions(task, unread: unread, actions: actions, rename: { renaming = task }, share: { sharing = task })
            .commaListRow(.task)
    }

    /// Today, Yesterday, then the date; the year only when it is not this year's.
    private func dayHeader(_ day: Date) -> some View {
        let calendar = Calendar.current
        let title = calendar.isDateInToday(day) ? String(localized: "Today")
            : calendar.isDateInYesterday(day) ? String(localized: "Yesterday")
            : calendar.isDate(day, equalTo: .now, toGranularity: .year)
                ? day.formatted(.dateTime.month(.abbreviated).day())
                : day.formatted(.dateTime.month(.abbreviated).day().year())
        // 16 + 8 around the 20pt line fills the 44pt row minimum, so the header sits where its padding puts it.
        return Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(CommaTheme.textQuaternary)
            .accessibilityAddTraits(.isHeader)
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .commaListRow()
    }

    /// While more Tasks exist it reads the next page; a page can hold no Inbox rows, so it keeps reading for
    /// as long as it shows on the Inbox on screen.
    @ViewBuilder private var footer: some View {
        if isLoading {
            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 12)
                .task(whileShowing: .inbox, id: store.tasks.count) {
                    if store.hasMoreTasks { await store.loadMoreTasks() }
                }
                .commaListRow()
        }
    }

    private var isLoading: Bool { store.hasMoreTasks || !store.tasksLoaded }

    private func showsEmpty(_ rows: [TaskSummary]) -> Bool { rows.isEmpty && !isLoading }

    /// Why there are no rows, and the way out: a list that could not be read says so, with the way to read it again.
    @ViewBuilder private var empty: some View {
        if store.taskListFailed, store.tasks.isEmpty {
            TaskListFailedState(store: store).transition(.opacity)
        } else {
            emptyInbox
        }
    }

    private var emptyInbox: some View {
        InboxEmptyView(state: inbox.emptyState(tasks: store.tasks), hidesRead: inbox.hidesRead(tasks: store.tasks),
                       notifications: store.taskNotifications,
                       clearFilters: { withAnimation(CommaMotion.settle(reduced: reduceMotion)) { inbox.clearFilters() } })
            .transition(.opacity)
    }

    /// The filter with how many filters differ from the default Inbox, and the actions on every row shown.
    @ToolbarContentBuilder
    private func toolbar(rows: [TaskSummary], actions: InboxActions) -> some ToolbarContent {
        let read = rows.filter { !inbox.isUnread($0) }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { filtersOpen = true } label: {
                HStack(spacing: 4) {
                    CentralIcon("icon-filter")
                    if inbox.appliedCount > 0 { Text(inbox.appliedCount, format: .number).font(.body.monospacedDigit()) }
                }
                .foregroundStyle(CommaTheme.textPrimary)
            }
            .accessibilityLabel("Filters")
            .accessibilityValue(inbox.appliedCount > 0 ? Text("\(inbox.appliedCount) applied") : Text(verbatim: ""))
            .accessibilityIdentifier("openInboxFilters")
            Menu {
                Button { inbox.markRead(rows) } label: { Label("Mark all as read", image: "inbox-mark-unread") }
                    .disabled(read.count == rows.count)
                Button { actions.clear(read) } label: { Label("Clear read", image: "inbox-clear") }
                    .disabled(read.isEmpty)
                Button(role: .destructive) { confirmingClearAll = true } label: {
                    Label { Text("Clear all") } icon: { MenuIcon.destructive("inbox-clear", enabled: !rows.isEmpty) }
                }
                .disabled(rows.isEmpty)
            } label: {
                CentralIcon("inbox-actions").foregroundStyle(CommaTheme.textPrimary)
            }
            .accessibilityLabel("Inbox actions")
            .accessibilityIdentifier("inboxActions")
            // Anchored to the button that asked, so its popover points at it rather than at the page.
            .confirmationDialog("Clear all notifications?", isPresented: $confirmingClearAll, titleVisibility: .visible) {
                Button("Clear all", role: .destructive) { actions.clear(rows) }
            } message: {
                Text("They come back when their tasks update.")
            }
        }
    }

    /// Status, Loops and Platform, with Unread only above them. Changes apply to the list behind as they are made.
    private var filters: some View {
        @Bindable var inbox = inbox
        return TaskFilterSheet(filter: $inbox.filter, fields: [.status, .schedule, .platform],
                               tasks: inbox.listed(tasks: store.tasks), labelCatalog: nil) {
            // Drawn like the sheet's option rows: the checkbox, the glyph, then the name.
            Button { inbox.unreadOnly.toggle() } label: {
                HStack(spacing: 0) {
                    FilterCheckbox(on: inbox.unreadOnly)
                    CentralIcon("inbox-mark-unread", size: 18, relativeTo: .body)
                        .foregroundStyle(CommaTheme.textSecondary).padding(.leading, 12)
                    Text("Unread only").font(.body).foregroundStyle(CommaTheme.textPrimary)
                        .multilineTextAlignment(.leading).padding(.leading, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .surfaceRowFrame(vertical: 6)
            }
            .buttonStyle(SurfaceRowButtonStyle())
            .sensoryFeedback(.selection, trigger: inbox.unreadOnly)
            .accessibilityAddTraits(inbox.unreadOnly ? .isSelected : [])
            .accessibilityIdentifier("inboxUnreadOnly")
        }
    }
}
