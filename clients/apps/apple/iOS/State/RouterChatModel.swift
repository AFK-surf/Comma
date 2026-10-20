import Foundation
import Observation

/// The router chat ("Comma"): its pane, whether the member can actually see it, and its unread replies.
/// A reply counts as read only while the router surface is shown, nothing covers it and the message
/// itself is in the transcript's viewport.
@MainActor @Observable
final class RouterChatModel {
    private(set) var pane: ConversationPane?
    private(set) var isVisible = false
    private(set) var visibleMessageIDs: Set<String> = []
    /// Advances when a notification tap asks to show the router chat.
    private(set) var revealRequest = 0
    /// Router replies the member has not seen, from the router-notifications read model.
    private(set) var unreadCount = 0
    @ObservationIgnored private var surfaceVisible = false
    /// Surfaces covering the router chat; only an open Task ("task") today.
    @ObservationIgnored private var obscurers: Set<String> = []
    @ObservationIgnored var onVisibilityChanged: (() -> Void)?
    /// A scroll moves many rows in and out of view; the badge hears once the reply in view has settled.
    @ObservationIgnored private var scrollNotice: Task<Void, Never>?
    static let scrollSettle: Duration = .milliseconds(400)

    /// The newest router reply the member is looking at, if any.
    var displayedReplyID: String? {
        guard isVisible else { return nil }
        return pane?.messages.last(where: { visibleMessageIDs.contains($0.id) && !$0.isUser && $0.actorType == "agent" })?.id
    }

    /// A new pane for the selected Workspace; nothing of the previous transcript counts as seen.
    func install(_ pane: ConversationPane) {
        self.pane = pane
        visibleMessageIDs = []
    }

    func setSurfaceVisible(_ visible: Bool) {
        surfaceVisible = visible
        updateVisibility()
    }

    func setObscured(_ reason: String, _ obscured: Bool) {
        if obscured { obscurers.insert(reason) } else { obscurers.remove(reason) }
        updateVisibility()
    }

    /// Called by the transcript's viewport visibility callback, never by a network read. Only a change of the
    /// reply in view matters to the badge, and it is told once the scroll settles.
    func messageVisibilityChanged(id: String, visible: Bool) {
        guard visibleMessageIDs.contains(id) != visible else { return }
        let shown = displayedReplyID
        if visible { visibleMessageIDs.insert(id) } else { visibleMessageIDs.remove(id) }
        guard isVisible, displayedReplyID != shown else { return }
        scrollNotice?.cancel()
        scrollNotice = Task { [weak self] in
            try? await Task.sleep(for: Self.scrollSettle)
            guard let self, !Task.isCancelled else { return }
            self.scrollNotice = nil
            if self.isVisible { self.onVisibilityChanged?() }
        }
    }

    /// Waits for a pending scroll notice, so a caller sees the badge work it starts.
    func settleScrollNotice() async { await scrollNotice?.value }

    func requestReveal() { revealRequest += 1 }

    func reportUnread(_ count: Int) { unreadCount = max(0, count) }

    func reset() {
        pane = nil
        isVisible = false
        visibleMessageIDs = []
        surfaceVisible = false
        obscurers = []
        unreadCount = 0
        scrollNotice?.cancel(); scrollNotice = nil
    }

    private func updateVisibility() {
        let visible = surfaceVisible && obscurers.isEmpty
        guard isVisible != visible else { return }
        isVisible = visible
        // This notice reads the current reply in view, so a pending scroll notice has nothing left to say.
        scrollNotice?.cancel(); scrollNotice = nil
        onVisibilityChanged?()
    }
}
