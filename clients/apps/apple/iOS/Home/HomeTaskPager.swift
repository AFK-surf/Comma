import SwiftUI
import Observation
import CommaCore

/// Home's task rows as a strip of pages, one per status in the switcher's order, turned by the status switcher.
/// While the finger scrubs along the switcher the strip goes with it for a small share of each page and gives less
/// and less past either end; each status the switcher chooses on the way springs the rest, with its pill and its tick.
/// Letting go springs the chosen status's page into place at the finger's speed, and a tap turns to its status on
/// the same spring. The strip's place has two parts: `base`, which the finger moves without animation, and `slack`,
/// which only springs move. A spring still running when the finger takes hold carries on in its own part, so the
/// strip neither jumps nor trails the finger.
/// While the strip moves it is drawn by `HomeTaskPages` over the list's own rows, which wait unseen. The status it
/// shows is `pending` until the strip comes to rest (`arrivals`); only then does the list take it, so the list's
/// work of changing its rows never holds up the strip, and the strip makes way once the list has drawn them.
@MainActor @Observable
final class HomeTaskPager {
    /// The strip's place is `base + slack`, in pages: 0 shows the first status's page, 1 the second's.
    private(set) var base: CGFloat = 0
    private(set) var slack: CGFloat = 0
    /// Whether the strip is on screen, over the list's rows.
    private(set) var moving = false
    /// The status the strip shows or is turning to, which the switcher and the title show too.
    private(set) var pending: TaskBucket?
    /// Advances when a tap has put the strip on the old page, for the view to turn it an update later.
    private(set) var turns = 0
    /// Advances when the strip comes to rest on `pending`'s page, for the view to hand that status to the list.
    private(set) var arrivals = 0
    /// The top of the rows in global coordinates, where the strip is drawn. Not observed: it moves with every
    /// scroll, and is only read while the strip moves.
    @ObservationIgnored var rowsTop: CGFloat = 0
    /// The heights of the list's rows above the Tasks (the greeting, the platform cards, the section title), which
    /// do not change as the list scrolls.
    @ObservationIgnored var rowsAbove: [CGFloat] = [0, 0, 0]
    /// The height the list shows content in: inside its insets and above the switcher.
    @ObservationIgnored var visibleHeight: CGFloat = 0
    /// The room between the section title and the switcher while the list rests at its top, where an empty or failed
    /// list centres what it says. A row is never shorter than the list's 44pt minimum.
    var emptyHeight: CGFloat { max(0, visibleHeight - rowsAbove.reduce(0) { $0 + max($1, 44) }) }
    @ObservationIgnored private var tracking = false
    /// The finger's part of the strip lately, for its speed as the finger lets go.
    @ObservationIgnored private var trail: [(time: CFTimeInterval, place: CGFloat)] = []
    /// Advances with each settle, so only the latest one hands its status over and puts the list's rows back.
    @ObservationIgnored private var settles = 0

    static let order = TaskBucket.homeStatuses
    /// The share of a page the finger turns itself as it goes from one status to the next; a page following the
    /// finger all the way swings several times as far as the finger moves.
    private static let follow: CGFloat = 0.15

    /// The finger at `position` along the switcher, in statuses, where `shown`'s page is when it takes hold.
    func track(_ position: CGFloat, from shown: TaskBucket?) {
        if !tracking {
            tracking = true
            trail = []
            settles += 1
            if pending == nil { pending = shown }
            if !moving, let page = Self.page(of: shown) { instantly { base = page; slack = 0; moving = true } }
        }
        let chosen = Self.page(of: pending) ?? position.rounded()
        // `slack` already holds where its springs are taking it, so the strip comes to rest where the finger says.
        instantly { base = Self.resisting(chosen + Self.follow * (position - chosen)) - slack }
        let now = CACurrentMediaTime()
        trail = trail.filter { now - $0.time < 0.1 } + [(now, base)]
    }

    /// A status chosen mid-scrub: the strip springs the share of the page the finger does not turn. False when no
    /// scrub is under way.
    func scrub(to bucket: TaskBucket) -> Bool {
        guard tracking else { return false }
        if let from = Self.page(of: pending), let to = Self.page(of: bucket) {
            withAnimation(CommaMotion.settle) { slack += (1 - Self.follow) * (to - from) }
        }
        pending = bucket
        return true
    }

    /// The finger let go: the strip settles on the page of the status the switcher shows chosen.
    func release() {
        guard tracking else { return }
        tracking = false
        settle(to: Self.page(of: pending) ?? (base + slack).rounded(), speed: fingerSpeed)
    }

    /// A tap from `old` to `new`: the strip shows the old page until the view, an update later, has it `turn()`
    /// to the new one. False when there is no page to turn from, and the list should take `new` at once.
    @discardableResult func turn(from old: TaskBucket?, to new: TaskBucket) -> Bool {
        guard !tracking, let from = Self.page(of: old), Self.page(of: new) != nil else { return false }
        if !moving { instantly { base = from; slack = 0; moving = true } }
        pending = new
        turns += 1
        return true
    }

    /// Turns the strip to the page of the status a tap chose.
    func turn() {
        guard let page = Self.page(of: pending) else { return }
        settle(to: page, speed: 0)
    }

    /// The list has taken `pending`: the strip, at rest over it, makes way once the list has drawn its new rows,
    /// which it does a frame or so after everything else.
    func rest() {
        let settle = settles
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard let self, self.settles == settle, !self.tracking else { return }
            self.instantly { self.moving = false; self.pending = nil }
        }
    }

    /// Springs the strip to `page`, starting at `speed` pages per second, and once it rests hands its status over.
    private func settle(to page: CGFloat, speed: CGFloat) {
        let base = base
        let remaining = page - base - slack
        settles += 1
        let settle = settles
        let spring = CommaMotion.settle(velocity: abs(remaining) > 0.001 ? Double(speed / remaining) : 0)
        withAnimation(spring, completionCriteria: .removed) { slack = page - base } completion: { [weak self] in
            guard let self, self.settles == settle, !self.tracking else { return }
            self.instantly { self.base = page; self.slack = 0 }
            self.arrivals += 1
        }
    }

    /// The finger's own part of the strip over the last tenth of a second, in pages per second; none once the finger
    /// has rested before letting go.
    private var fingerSpeed: CGFloat {
        let now = CACurrentMediaTime()
        guard let last = trail.last, let first = trail.first, now - last.time < 0.05,
              last.time - first.time > 0.008 else { return 0 }
        return (last.place - first.place) / CGFloat(last.time - first.time)
    }

    private static func page(of bucket: TaskBucket?) -> CGFloat? {
        bucket.flatMap { order.firstIndex(of: $0) }.map { CGFloat($0) }
    }

    /// Past the first or last page the strip gives less the farther it is pulled, as a scroll view does past its
    /// end, and never as much as a quarter page: the finger reaches the switcher's end half a status past the last.
    private static func resisting(_ place: CGFloat) -> CGFloat {
        let last = CGFloat(order.count - 1)
        func give(_ over: CGFloat) -> CGFloat { over * 0.25 * 0.55 / (0.25 + 0.55 * over) }
        if place < 0 { return -give(-place) }
        if place > last { return last + give(place - last) }
        return place
    }

    private func instantly(_ change: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, change)
    }
}

/// The moving strip: each status's rows drawn where the list draws its own, side by side in the switcher's order,
/// the chosen status's alone visible. A picture only; the list's rows take over when the strip settles.
struct HomeTaskPages: View {
    let store: CommaStore
    let query: HomeTaskQuery
    let pager: HomeTaskPager
    /// The list's `emptyHeight`, so a page with nothing to show centres it as the list does.
    let emptyHeight: CGFloat

    var body: some View {
        GeometryReader { proxy in
            if pager.moving {
                // Toward the trailing edge: right to left, the layout mirrors these offsets and the pages run leftward.
                let step = proxy.size.width
                ZStack(alignment: .topLeading) {
                    ForEach(Array(HomeTaskPager.order.enumerated()), id: \.element) { index, bucket in
                        HomeTaskPage(store: store, query: query, bucket: bucket, emptyHeight: emptyHeight)
                            .frame(width: step, alignment: .top)
                            // Only the chosen status's rows show: a finger resting off its middle never shows the
                            // next status's rows beside them, and the page left behind fades as it slides away.
                            .opacity(bucket == pager.pending ? 1 : 0)
                            .animation(CommaMotion.settle, value: pager.pending)
                            .offset(x: CGFloat(index) * step)
                    }
                }
                .offset(y: pager.rowsTop - proxy.frame(in: .global).minY)
                // The finger's part, then the springs'.
                .offset(x: -pager.base * step)
                .offset(x: -pager.slack * step)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// One status's rows on the strip. Its own view, so the strip moving does not read the rows again.
private struct HomeTaskPage: View {
    let store: CommaStore
    let query: HomeTaskQuery
    let bucket: TaskBucket
    let emptyHeight: CGFloat

    /// Enough rows to fill the screen below the section title.
    private static let rowLimit = 16

    var body: some View {
        let rows = query.rows(for: bucket, tasks: store.tasks, pinned: store.pinnedTaskIDs, order: store.taskBoardOrder)
        VStack(spacing: 0) {
            if !store.tasksLoaded {
                TaskSkeletonRows()
            } else if store.taskListFailed, store.tasks.isEmpty {
                TaskListFailedState(store: store, minHeight: emptyHeight)
            } else if rows.isEmpty {
                HomeTaskEmptyState(reason: query.appliedCount > 0 ? .filtered : .status(bucket),
                                   messageComma: {}, clearFilters: {}, minHeight: emptyHeight)
            } else {
                ForEach(rows.prefix(Self.rowLimit)) { task in
                    TaskListRow(task: task, pinned: store.pinnedTaskIDs.contains(task.id)) {}
                        .padding(ListRowInset.task.edges)
                }
            }
        }
    }
}
