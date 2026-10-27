import SwiftUI
import CommaCore

/// Transcript rows with bubble grouping, avatars and reply connectors, following the desktop thread.
struct ChatTranscriptView: View {
    let rows: [ChatRow]
    /// The conversation the rows belong to. Rows load earlier history, retry sends and report what is on
    /// screen through it, and open Tasks and read their summaries through the store.
    let pane: ConversationPane
    let store: CommaStore
    let isTask: Bool
    let hasOlderMessages: Bool
    let loadingMore: Bool
    var flight: OutgoingFlightController?
    /// The composer has the keyboard. Taking it brings the latest message into view, as in Messages.
    var composerFocused = false
    var onUserScroll: () -> Void
    var openAttachment: (ChatItem, ChatAttachment) -> Void
    /// The thread gathered over the transcript for a reply, if one is open.
    var replyThread: ReplyThreadSelection? = nil
    /// A reply thread opened from a row: the composer takes the keyboard.
    var onReplyOpened: () -> Void = {}

    /// Rows created after this moment draw their reply connector and play their entrance.
    @State var openedAt = Date().timeIntervalSince1970
    @State private var followTail = true
    /// The rows of a long conversation that are laid out: the newest, or those the reader scrolled or went to.
    @State private var window = TranscriptWindow()
    @State var highlighted: String?
    @State private var scroll = TranscriptScroll()
    /// Advances on each release that loads earlier messages; it plays the release haptic.
    @State private var pullLoads = 0
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    /// Visible transcript row positions, kept outside the layout of the flying reply copies.
    @State var replyFrames = ReplyFlightFrames()

    /// Pull distance past the top at which releasing loads earlier messages.
    private static let pullThreshold: CGFloat = 64

    var body: some View {
        ZStack {
            transcript
            if let replyThread {
                threadLayer(replyThread).transition(replyLayerTransition)
            }
        }
    }

    @ViewBuilder private var transcript: some View {
        let tail = TailRows(last: rows.last?.id,
                            send: rows.last(where: \.isUser).flatMap { isPending($0) ? $0.id : nil })
        let shown = window.range(in: rows)
        // Rows above the window come before any the server still has.
        let hasEarlier = shown.lowerBound > 0 || hasOlderMessages
        ScrollViewReader { proxy in
            ScrollView {
                // A transcript shorter than the screen fills it, its rows at the bottom. Left to the scroll view's
                // bottom anchor, the rows rode a top inset the scroll view set for them, and each change in their height
                // pushed them under the composer by that inset once more for a frame or two: a first send's rows
                // vanished and its bubble dropped back into the composer.
                ZStack(alignment: .bottom) {
                    Color.clear.containerRelativeFrame(.vertical)
                    // Not lazy: the window's rows are all laid out, so the content's height is theirs and not an
                    // estimate (`TranscriptWindow`). Typing in the composer leaves the transcript as it is.
                    VStack(spacing: 0) {
                        if hasEarlier {
                            PullToLoadIndicator(loading: loadingMore, scroll: scroll)
                                .padding(.bottom, 12)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("Load earlier messages")
                                .accessibilityAddTraits(.isButton)
                                .accessibilityAction { if !loadingMore { loadEarlier() } }
                        }
                        ForEach(Array(rows[shown].enumerated()), id: \.element.id) { offset, row in
                            rowView(row, proxy: proxy)
                                // While its thread is open, the row's copy stands in for it over the transcript.
                                .opacity(inOpenThread(row) ? 0 : 1)
                                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                                    replyFrames.current[row.id] = frame
                                }
                                .onDisappear { replyFrames.current[row.id] = nil }
                                .padding(.top, offset == 0 ? 0 : spacing(before: row, after: rows[shown.lowerBound + offset - 1]))
                                .transition(transition(for: row))
                                .id(row.id)
                                .onScrollVisibilityChange(threshold: 0.1) { visible in
                                    if visible { scroll.visibleRows.insert(row.id) } else { scroll.visibleRows.remove(row.id) }
                                    if let message = row.message { messageVisibilityChanged(message.id, visible) }
                                }
                                // A streamed draft becomes its committed reply in the same row, which never leaves the
                                // screen to report again: a row in view reports the message it now holds.
                                .onChange(of: row.message?.id) { old, new in
                                    guard scroll.visibleRows.contains(row.id) else { return }
                                    if let old { messageVisibilityChanged(old, false) }
                                    if let new { messageVisibilityChanged(new, true) }
                                }
                        }
                        // A request the Agent waits on before its reply has come: the newest turn's, when the window
                        // reaches it.
                        let waiting = pane.requestPlacement.waiting
                        if !waiting.isEmpty, shown.upperBound == rows.count {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(waiting) { request in AgentRequestCard(request: request, pane: pane) }
                            }
                            .frame(maxWidth: 560, alignment: .leading)
                            .padding(.leading, isTask ? CommaTheme.avatarGutter : 0)
                            .padding(.trailing, 42)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, rows.isEmpty ? 0 : 12)
                        }
                        // The end, and the space below the last row: scrolling to it shows the whole stack.
                        Color.clear.frame(height: 12).id("tail")
                    }
                    // Each row at its own height, as a lazy stack lays them out. Offered a height, the stack shares it
                    // out: a Task's rows stretch with their avatar column, and a question card squeezed to make room
                    // drew its choices over each other.
                    .fixedSize(horizontal: false, vertical: true)
                    .overlayPreferenceValue(ChatAnchorKey.self) { anchors in
                        GeometryReader { geometry in
                            ReplyConnectors(lines: connectors(anchors: anchors, geometry: geometry))
                        }
                        .allowsHitTesting(false)
                    }
                    .padding(.horizontal, 16).padding(.top, 16)
                }
                .overlay(alignment: .top) { ScrollMark(scroll: scroll, proxy: proxy) }
            }
            .scrollDismissesKeyboard(.immediately)
            // A sent mention's `comma:task/<id>` link opens that Task; every other link opens as it always has.
            .environment(\.inlineTaskStore, store)
            .environment(\.openURL, OpenURLAction { url in
                guard let id = TaskMention.conversationID(from: url) else { return .systemAction }
                openTask(id)
                return .handled
            })
            // Follow the tail only while the reader is at the end. A stack's onAppear fires once, not per
            // scroll, so the position is read from the scroll geometry (`TranscriptTail`).
            .onScrollGeometryChange(for: TranscriptTail.self) { geometry in
                TranscriptTail(distance: geometry.contentSize.height - geometry.visibleRect.maxY,
                               container: geometry.containerSize.height, content: geometry.contentSize.height,
                               inset: geometry.contentInsets.bottom)
            } action: { old, new in
                // A scroll to a view, as for the follow: a scroll position set after the reader has scrolled is not
                // applied (iOS 26).
                if new.pastEnd(readerScrolling: scroll.readerScrolling) { proxy.scrollTo("tail", anchor: .bottom) }
                // A window away from the end has no tail to follow until it reaches the end again.
                if let follow = new.follows(after: old, readerScrolling: scroll.readerScrolling) { followTail = follow && window.live }
            }
            // Only crossing the threshold reports, and only the indicator reads it, not every row.
            .onScrollGeometryChange(for: Bool.self) { geometry in
                -(geometry.contentOffset.y + geometry.contentInsets.top) >= Self.pullThreshold
            } action: { _, armed in
                scroll.pullArmed = armed
            }
            .onScrollGeometryChange(for: WindowEnds.self) { geometry in
                WindowEnds(top: geometry.contentOffset.y + geometry.contentInsets.top < geometry.containerSize.height * 2,
                           bottom: geometry.contentSize.height - geometry.visibleRect.maxY < geometry.containerSize.height * 2)
            } action: { _, near in
                scroll.near = near
            }
            .onScrollPhaseChange { old, phase in
                scroll.moving = phase != .idle
                scroll.readerScrolling = phase == .interacting || phase == .decelerating
                if phase == .interacting {
                    // The reader's own scroll ends a hold, and a reveal still waiting for its rows.
                    scroll.held = nil
                    scroll.mark = nil
                    scroll.revealing = nil
                    onUserScroll()
                }
                // Pull down past the top and let go: earlier messages load on the release, not the pull.
                if old == .interacting, phase != .interacting, scroll.pullArmed, hasEarlier, !loadingMore {
                    pullLoads += 1
                    loadEarlier()
                } else if phase == .idle, old == .interacting || old == .decelerating {
                    // Not during the reader's scroll, whose finger or momentum the hold would fight, and not after a
                    // reveal's own scroll.
                    settleWindow()
                }
            }
            // Earlier rows join the window above what the reader is looking at, which stays where it is: the offset
            // grows by what was added (or shrinks by what left). A scroll view keeps its offset when content grows
            // above it, so without this the reader is carried to the top of the new rows. The place is held briefly,
            // as the rows settle their heights, and until the reader scrolls again.
            .onScrollGeometryChange(for: ContentPlace.self) { [first = rows[shown].first?.id] geometry in
                ContentPlace(first: first, offset: geometry.contentOffset.y, inset: geometry.contentInsets.top,
                             height: geometry.contentSize.height)
            } action: { old, new in
                if new.height != old.height { scroll.beforeGrowth = old }
                scroll.place = new
                // A row revealed above the window is scrolled to once the rows that joined with it are laid out.
                if let target = scroll.revealing, new.height != old.height {
                    scroll.revealing = nil
                    return show(target, proxy: proxy)
                }
                holdPlace(in: new)
            }
            // An earlier page the reader asked the server for joins above the rows shown, a budget's worth of it, and
            // the reader stays where they were when it landed. Only from then: while the page is on its way, a reply
            // growing below must not move them.
            .onChange(of: EarlierPage(first: rows.first?.id, loading: loadingMore)) { old, new in
                if let asked = scroll.earlierFrom, let first = old.first, new.first != first,
                   rows.contains(where: { $0.id == first }), let place = scroll.place {
                    scroll.earlierFrom = nil
                    // The place before the page landed: the last one laid out, or the one before it when the window
                    // took in rows of the page straight away and they are laid out.
                    let before = place.first == asked ? place : scroll.beforeGrowth ?? place
                    scroll.held = before
                    window.expandUp(rows)
                    holdPlace(in: place)
                    releaseHold(before)
                }
                // The read ended, with a page or without one.
                if old.loading, !new.loading { scroll.earlierFrom = nil }
            }
            .onAppear { window.pin(rows) }
            .sensoryFeedback(.impact(weight: .medium), trigger: pullLoads)
            .progressiveTopEdge()
            .defaultScrollAnchor(.bottom)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            // The Task sheet or keyboard can shorten the viewport; keep the latest message in view.
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { _ in
                if followTail { proxy.scrollTo("tail", anchor: .bottom) }
            }
            // The Task dock instead raises the transcript's bottom inset with the keyboard, which leaves its size as
            // it was; the latest message stays in view above the keyboard there too.
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentInsets.bottom } action: { _, _ in
                if followTail, !scroll.moving { proxy.scrollTo("tail", anchor: .bottom) }
            }
            // Rows settle their heights after the anchor has placed the end: a send's slot growing, or its delivery
            // note, would otherwise settle under the composer. A streamed reply growing follows the same way. Never
            // while the reader is moving the transcript, and a finger on the transcript is never fought.
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _, _ in
                if followTail, !scroll.moving { proxy.scrollTo("tail", anchor: .bottom) }
            }
            .onChange(of: tail) { old, new in
                if let send = new.send, send != old.send {
                    // A send owns its own motion: jump to the end, wherever the reader was, so the reserved slot grows
                    // in place where the composer's surface lands. The reply's Thinking… row comes in the same update,
                    // and a Worker's Working… row is already there, so the send is never the last row.
                    followTail = true
                    if !window.live { window.reset(rows) }
                    proxy.scrollTo("tail", anchor: .bottom)
                } else if new.last != old.last, followTail {
                    // At the end, the rows past the window's limit leave it above.
                    if !scroll.moving { window.shed(rows, above: true) }
                    withAnimation(reduceMotion ? nil : CommaMotion.spatialMove) { proxy.scrollTo("tail", anchor: .bottom) }
                }
            }
            // Taking the composer means writing next, so the transcript goes to the latest message as the keyboard
            // rises, as Messages does, on the curve the composer's card opens on; the follow keeps it there.
            .onChange(of: composerFocused) { _, focused in
                guard focused, !followTail else { return }
                scroll.held = nil
                followTail = true
                if !window.live { window.reset(rows) }
                withAnimation(reduceMotion ? nil : CommaMotion.composerExpand) { proxy.scrollTo("tail", anchor: .bottom) }
            }
        }
    }

    /// Makes a change to the window above the reader, whose place holds: from where they are now, as the rows that
    /// joined or left are laid out and settle their heights. Only the rows laid out straight away are measured
    /// against the hold; a reply growing below later must not move the reader.
    private func holdingPlace(_ change: () -> Bool) {
        guard let before = scroll.place, change() else { return }
        scroll.held = before
        releaseHold(before)
    }

    /// Lets the hold go once the rows laid out straight away have settled.
    private func releaseHold(_ before: ContentPlace) {
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            if scroll.held == before { scroll.held = nil; scroll.mark = nil }
        }
    }

    /// Keeps the reader where they were before earlier messages landed. Measured from that place rather than from
    /// the last change, so a growth the geometry action never saw still counts.
    private func holdPlace(in place: ContentPlace) {
        guard let held = scroll.held, place.height != held.height else { return }
        let target = held.offset + place.height - held.height
        // The mark is where the visible top goes, in content coordinates: the content offset counts the top inset.
        if abs(place.offset - target) > 0.5 { scroll.mark = target + place.inset }
    }

    /// The rows above the window first; once all are shown, the page before them from the server.
    func loadEarlier() {
        let shown = window.range(in: rows)
        if shown.lowerBound > 0 { return holdingPlace { window.expandUp(rows) } }
        scroll.earlierFrom = rows[shown].first?.id
        Task { await pane.loadEarlierMessages() }
    }

    /// The reader's scroll came to rest: the rows past the end of the window they rest near join it, or, once it holds
    /// more than its limit, rows leave it at the end away from them.
    private func settleWindow() {
        let shown = window.range(in: rows)
        if scroll.near.top, shown.lowerBound > 0 {
            holdingPlace { window.expandUp(rows) }
        } else if scroll.near.bottom, !window.live {
            window.expandDown(rows)
        } else if let place = scroll.place, place.offset > place.height / 2 {
            holdingPlace { window.shed(rows, above: true) }
        } else {
            window.shed(rows, above: false)
        }
    }

    /// Scrolls to a row and marks it briefly; the window first moves to one outside it, and it is scrolled to once the
    /// window is laid out.
    func reveal(_ id: String, proxy: ScrollViewProxy) {
        guard rows.contains(where: { $0.id == id }) else {
            if hasOlderMessages { Task { await pane.loadEarlierMessages() } }
            return
        }
        // The reader goes to the earlier message, away from the end: neither the rows joining above nor a reply
        // below may pull them back.
        followTail = false
        if window.reveal(id, in: rows) { scroll.revealing = id } else { show(id, proxy: proxy) }
    }

    private func show(_ id: String, proxy: ScrollViewProxy) {
        withAnimation(reduceMotion ? nil : CommaMotion.spatialMove) { proxy.scrollTo(id, anchor: .center) }
        highlighted = id
        Task {
            try? await Task.sleep(for: .milliseconds(900))
            if highlighted == id { withAnimation(.linear(duration: 0.4)) { highlighted = nil } }
        }
    }

    func retry(_ clientRequestID: String) {
        Task { await pane.retry(clientRequestID) }
    }

    func openTask(_ id: String) { Task { await store.openTask(id: id) } }

    /// The router counts what the member has seen of its replies; a Task's transcript reports nothing.
    private func messageVisibilityChanged(_ id: String, _ visible: Bool) {
        if !pane.isTask { store.router.messageVisibilityChanged(id: id, visible: visible) }
    }

    /// What the scroll view reports between renders. Only the pull indicator reads the pull, only the scroll mark
    /// reads the mark, and only the scroll and visibility actions read the motion and the rows in view, so none of it
    /// re-renders the rows.
    @MainActor @Observable fileprivate final class TranscriptScroll {
        /// Pulled down past the top far enough that letting go loads earlier messages.
        var pullArmed = false
        /// Where in the content a held place puts the top of the viewport (`ScrollMark`).
        var mark: CGFloat?
        /// Within two screens of the top or the bottom of the rows shown.
        @ObservationIgnored var near = WindowEnds(top: false, bottom: true)
        /// The first row shown when the reader asked the server for the page before it, until the read ends.
        @ObservationIgnored var earlierFrom: String?
        /// A row outside the window being revealed, scrolled to once the window has moved to it.
        @ObservationIgnored var revealing: String?
        /// The transcript is moving: the reader drags it, it decelerates, or a scroll animates it.
        @ObservationIgnored var moving = false
        /// The reader is dragging the transcript or it is still decelerating from their drag.
        @ObservationIgnored var readerScrolling = false
        /// Where the reader is held while rows join or leave the window above them; nil once they scroll.
        @ObservationIgnored var held: ContentPlace?
        /// The scroll offset and content height as last laid out, and as they were before the content last grew.
        @ObservationIgnored var place: ContentPlace?
        @ObservationIgnored var beforeGrowth: ContentPlace?
        /// The rows in the viewport, by row id.
        @ObservationIgnored var visibleRows: Set<String> = []
    }

    /// A point in the content that a held place goes to: laid out there, then scrolled to the top of the viewport. A
    /// scroll position set after the reader has scrolled is not applied (iOS 26); a scroll to a view is. Only it reads
    /// the mark, so a hold re-renders it and not the rows.
    private struct ScrollMark: View {
        let scroll: TranscriptScroll
        let proxy: ScrollViewProxy
        private static let id = "scrollMark"

        var body: some View {
            let mark = scroll.mark
            Color.clear.frame(height: 1).id(Self.id).padding(.top, mark ?? 0)
                .allowsHitTesting(false)
                .onChange(of: mark) { _, mark in
                    if mark != nil { proxy.scrollTo(Self.id, anchor: .top) }
                }
        }
    }

    /// Above the oldest loaded message: a hint to pull, which turns once the pull is far enough to load.
    private struct PullToLoadIndicator: View {
        let loading: Bool
        let scroll: TranscriptScroll

        var body: some View {
            let armed = scroll.pullArmed
            HStack(spacing: 6) {
                if loading {
                    ProgressView().controlSize(.small)
                } else {
                    // Points down while pulling, and up once letting go loads.
                    CentralIcon("central-arrow-up", size: 14, relativeTo: .footnote)
                        .rotationEffect(.degrees(armed ? 0 : 180))
                }
                Text(loading ? "Loading earlier messages…" : armed ? "Release to load earlier messages" : "Pull down to load earlier messages")
                    .contentTransition(.opacity)
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(CommaTheme.textTertiary)
            .frame(minHeight: 32)
            .animation(CommaMotion.stateChange, value: armed)
            .animation(CommaMotion.stateChange, value: loading)
        }
    }

    fileprivate struct ContentPlace: Equatable {
        /// The first row shown.
        let first: String?
        let offset: CGFloat
        let inset: CGFloat
        let height: CGFloat
    }

    fileprivate struct WindowEnds: Equatable {
        let top: Bool
        let bottom: Bool
    }

    /// The oldest row, and whether a read of earlier messages is under way.
    private struct EarlierPage: Equatable {
        let first: String?
        let loading: Bool
    }

    /// The last row, and the member's newest row while it is a send on its way.
    private struct TailRows: Equatable {
        let last: String?
        let send: String?
    }
}

/// The conversation view re-renders for its own state too (the + card opening, an upload, a preview). The
/// transcript then keeps its rows as they are: it updates only for its inputs. Its two closures come from
/// that same conversation view and are left out.
extension ChatTranscriptView: Equatable {
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.pane === rhs.pane && lhs.store === rhs.store && lhs.flight === rhs.flight && lhs.isTask == rhs.isTask
            && lhs.composerFocused == rhs.composerFocused
            && lhs.hasOlderMessages == rhs.hasOlderMessages && lhs.loadingMore == rhs.loadingMore && lhs.rows == rhs.rows
            && lhs.replyThread == rhs.replyThread
    }
}

/// Where the transcript's end is against its viewport: how far the content runs below the visible rect (negative
/// once the visible rect reaches past it, by the bottom inset at rest at the end), and the sizes that frame was
/// laid out at.
struct TranscriptTail: Equatable {
    let distance: CGFloat
    let container: CGFloat
    let content: CGFloat
    let inset: CGFloat

    /// Whether the follow changes in this frame, and to what: only the reader's own scroll, in a frame that is a
    /// pure scroll, decides it. A resize (Task sheet, keyboard, a growing reply) must not flip it before the follow
    /// runs, and neither may the lazy stack settling its estimated heights, which moves the offset in frames of its
    /// own. That turned the follow off with nobody scrolling, and the next estimate that shrank the content left
    /// the offset past its end: a blank transcript until a touch brought the rows back.
    func follows(after old: TranscriptTail, readerScrolling: Bool) -> Bool? {
        guard readerScrolling, old.container == container, old.content == content else { return nil }
        return distance < 48
    }

    /// The offset outlived content that shrank under it as the stack measured its rows, and nobody is moving it.
    /// The scroll view does not pull it back by itself; the rows stayed above the screen until a touch.
    func pastEnd(readerScrolling: Bool) -> Bool { !readerScrolling && distance < -inset - 1 }
}
