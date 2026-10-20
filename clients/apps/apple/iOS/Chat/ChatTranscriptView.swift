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
    @State var highlighted: String?
    @State private var scroll = TranscriptScroll()
    /// Set only to hold the reader's place when earlier messages land above it.
    @State private var position = ScrollPosition()
    /// Advances on each release that loads earlier messages; it plays the release haptic.
    @State private var pullLoads = 0
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    /// Pairs each row in the transcript with its copy in an open reply thread, so it flies between the two.
    @Namespace var threadSpace

    /// Pull distance past the top at which releasing loads earlier messages.
    private static let pullThreshold: CGFloat = 64

    var body: some View {
        ZStack {
            transcript
            if let replyThread {
                threadLayer(replyThread).transition(.opacity)
            }
        }
    }

    @ViewBuilder private var transcript: some View {
        let tail = TailRows(last: rows.last?.id,
                            send: rows.last(where: \.isUser).flatMap { isPending($0) ? $0.id : nil })
        ScrollViewReader { proxy in
            ScrollView {
                // A transcript shorter than the screen fills it, its rows at the bottom. Left to the scroll view's
                // bottom anchor, the rows rode a top inset the scroll view set for them, and each change in their height
                // pushed them under the composer by that inset once more for a frame or two: a first send's rows
                // vanished and its bubble dropped back into the composer.
                ZStack(alignment: .bottom) {
                    Color.clear.containerRelativeFrame(.vertical)
                    // Lazy: only the rows on screen are built and laid out, so typing in the composer below never
                    // lays out the whole history again. Reveals (scrollTo by id) and the reply connectors (which reach
                    // the top for a target not yet built) work with rows that are not built.
                    LazyVStack(spacing: 0) {
                        if hasOlderMessages {
                            PullToLoadIndicator(loading: loadingMore, scroll: scroll)
                                .padding(.bottom, 12)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("Load earlier messages")
                                .accessibilityAddTraits(.isButton)
                                .accessibilityAction { if !loadingMore { loadEarlier() } }
                        }
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            rowView(row, proxy: proxy)
                                // While its thread is open, the row's copy stands in for it over the transcript.
                                .opacity(inOpenThread(row) ? 0 : 1)
                                .matchedGeometryEffect(id: row.id, in: threadSpace, isSource: !inOpenThread(row))
                                .padding(.top, index == 0 ? 0 : spacing(before: row, after: rows[index - 1]))
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
                        // The end, and the space below the last row: scrolling to it shows the whole stack.
                        Color.clear.frame(height: 12).id("tail")
                    }
                    .overlayPreferenceValue(ChatAnchorKey.self) { anchors in
                        GeometryReader { geometry in
                            ReplyConnectors(lines: connectors(anchors: anchors, geometry: geometry))
                        }
                        .allowsHitTesting(false)
                    }
                    .padding(.horizontal, 16).padding(.top, 16)
                }
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
            // scroll, so the position is read from the scroll geometry. Only a pure scroll updates it: a
            // resize (Task sheet, keyboard, a growing reply) must not flip it before the follow runs.
            .onScrollGeometryChange(for: TailPosition.self) { geometry in
                TailPosition(distance: geometry.contentSize.height - geometry.visibleRect.maxY,
                             container: geometry.containerSize.height, content: geometry.contentSize.height)
            } action: { old, new in
                guard old.container == new.container, old.content == new.content else { return }
                followTail = new.distance < 48
            }
            // Only crossing the threshold reports, and only the indicator reads it, not every row.
            .onScrollGeometryChange(for: Bool.self) { geometry in
                -(geometry.contentOffset.y + geometry.contentInsets.top) >= Self.pullThreshold
            } action: { _, armed in
                scroll.pullArmed = armed
            }
            .onScrollPhaseChange { old, phase in
                scroll.moving = phase != .idle
                if phase == .interacting { scroll.held = nil; onUserScroll() }
                // Pull down past the top and let go: earlier messages load on the release, not the pull.
                if old == .interacting, phase != .interacting, scroll.pullArmed, hasOlderMessages, !loadingMore {
                    pullLoads += 1
                    loadEarlier()
                }
            }
            // Earlier messages land above what the reader is looking at, which stays where it is: the offset grows
            // by what was added. A scroll view keeps its offset when content grows above it, so without this the
            // reader is carried to the top of the new page. The new rows are measured as they come into view, all
            // above the reader, so the place is held through that too, briefly and until the reader scrolls again.
            .onScrollGeometryChange(for: ContentPlace.self) { [first = rows.first?.id] geometry in
                ContentPlace(first: first, offset: geometry.contentOffset.y, inset: geometry.contentInsets.top,
                             height: geometry.contentSize.height)
            } action: { old, new in
                if new.height != old.height { scroll.beforeGrowth = old }
                scroll.place = new
                holdPlace(in: new)
            }
            .onChange(of: rows.first?.id) { old, new in
                // Rows arrived above the old first row, which is still there: earlier history, not a new conversation.
                guard let old, rows.contains(where: { $0.id == old }), let place = scroll.place else { return }
                // The place before the rows landed: the last one laid out, or the one before it when they are laid out.
                let before = place.first == new ? scroll.beforeGrowth ?? place : place
                scroll.held = before
                holdPlace(in: place)
                // Only the rows built straight away are measured against the hold; a reply growing below later
                // must not move the reader.
                Task {
                    try? await Task.sleep(for: .milliseconds(600))
                    if scroll.held == before { scroll.held = nil }
                }
            }
            .scrollPosition($position)
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
            // A lazy stack learns its rows' heights as it builds them, after the anchor has placed the end: a send's
            // slot growing, or its delivery note, would otherwise settle under the composer. A streamed reply
            // growing follows the same way. Never while the reader is moving the transcript, as rows built during a
            // scroll change the height too, and a finger on the transcript is never fought.
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _, _ in
                if followTail, !scroll.moving { proxy.scrollTo("tail", anchor: .bottom) }
            }
            .onChange(of: tail) { old, new in
                if let send = new.send, send != old.send {
                    // A send owns its own motion: jump to the end, wherever the reader was, so the reserved slot grows
                    // in place where the composer's surface lands. The reply's Thinking… row comes in the same update,
                    // and a Worker's Working… row is already there, so the send is never the last row.
                    followTail = true
                    proxy.scrollTo("tail", anchor: .bottom)
                } else if new.last != old.last, followTail {
                    withAnimation(reduceMotion ? nil : CommaMotion.spatialMove) { proxy.scrollTo("tail", anchor: .bottom) }
                }
            }
            // Taking the composer means writing next, so the transcript goes to the latest message as the keyboard
            // rises, as Messages does, on the curve the composer's card opens on; the follow keeps it there.
            .onChange(of: composerFocused) { _, focused in
                guard focused, !followTail else { return }
                scroll.held = nil
                followTail = true
                withAnimation(reduceMotion ? nil : CommaMotion.composerExpand) { proxy.scrollTo("tail", anchor: .bottom) }
            }
        }
    }

    /// Keeps the reader where they were before earlier messages landed. Measured from that place rather than from
    /// the last change, so a growth the geometry action never saw still counts.
    private func holdPlace(in place: ContentPlace) {
        guard let held = scroll.held, place.height != held.height else { return }
        let target = held.offset + place.height - held.height
        // A scroll position's y leaves out the top inset that the content offset counts.
        if abs(place.offset - target) > 0.5 { position.scrollTo(y: target + place.inset) }
    }

    func loadEarlier() { Task { await pane.loadEarlierMessages() } }

    func retry(_ clientRequestID: String) {
        Task { await pane.retry(clientRequestID) }
    }

    func openTask(_ id: String) { Task { await store.openTask(id: id) } }

    /// The router counts what the member has seen of its replies; a Task's transcript reports nothing.
    private func messageVisibilityChanged(_ id: String, _ visible: Bool) {
        if !pane.isTask { store.router.messageVisibilityChanged(id: id, visible: visible) }
    }

    /// What the scroll view reports between renders. Only the pull indicator reads the pull, and only the
    /// scroll and visibility actions read the motion and the rows in view, so none of it re-renders the rows.
    @MainActor @Observable fileprivate final class TranscriptScroll {
        /// Pulled down past the top far enough that letting go loads earlier messages.
        var pullArmed = false
        /// The reader is dragging the transcript or it is still decelerating.
        @ObservationIgnored var moving = false
        /// Where the reader is held while earlier messages land and are measured above them; nil once they scroll.
        @ObservationIgnored var held: ContentPlace?
        /// The scroll offset and content height as last laid out, and as they were before the content last grew.
        @ObservationIgnored var place: ContentPlace?
        @ObservationIgnored var beforeGrowth: ContentPlace?
        /// The rows in the viewport, by row id.
        @ObservationIgnored var visibleRows: Set<String> = []
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
        let first: String?
        let offset: CGFloat
        let inset: CGFloat
        let height: CGFloat
    }

    /// The last row, and the member's newest row while it is a send on its way.
    private struct TailRows: Equatable {
        let last: String?
        let send: String?
    }

    private struct TailPosition: Equatable {
        let distance: CGFloat
        let container: CGFloat
        let content: CGFloat
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
