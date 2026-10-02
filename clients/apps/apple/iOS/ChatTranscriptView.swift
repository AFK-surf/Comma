import SwiftUI
import CommaCore

/// Transcript rows with bubble grouping, avatars and reply connectors, following the desktop thread.
struct ChatTranscriptView: View {
    let rows: [ChatRow]
    let isTask: Bool
    let hasOlderMessages: Bool
    let loadingMore: Bool
    var flight: OutgoingFlightController?
    var onUserScroll: () -> Void
    var loadEarlier: () -> Void
    var retry: (String) -> Void
    var openTask: (String) -> Void
    /// Current summary for a Task referenced in chat, from the loaded task list.
    var taskSummary: (String) -> Conversation? = { _ in nil }
    var openAttachment: (Message, Int, String) -> Void

    /// Rows created after this moment draw their reply connector and play their entrance.
    @State private var openedAt = Date().timeIntervalSince1970
    @State private var followTail = true
    @State private var highlighted: String?
    /// How far the transcript is pulled down past its top edge.
    @State private var pull: CGFloat = 0
    /// Advances on each release that loads earlier messages; it plays the release haptic.
    @State private var pullLoads = 0

    /// Pull distance past the top at which releasing loads earlier messages.
    private static let pullThreshold: CGFloat = 64

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    if hasOlderMessages {
                        PullToLoadIndicator(loading: loadingMore, armed: pull >= Self.pullThreshold)
                            .padding(.bottom, 12)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Load earlier messages")
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { if !loadingMore { loadEarlier() } }
                    }
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        rowView(row, proxy: proxy)
                            .padding(.top, index == 0 ? 0 : spacing(before: row, after: rows[index - 1]))
                            .transition(transition(for: row))
                            .id(row.id)
                    }
                    Color.clear.frame(height: 1).id("tail")
                }
                .overlayPreferenceValue(ChatAnchorKey.self) { anchors in
                    GeometryReader { geometry in
                        ReplyConnectors(lines: connectors(anchors: anchors, geometry: geometry))
                    }
                    .allowsHitTesting(false)
                }
                .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 12)
            }
            .scrollDismissesKeyboard(.immediately)
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
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                max(0, -(geometry.contentOffset.y + geometry.contentInsets.top))
            } action: { _, value in
                pull = value
            }
            .onScrollPhaseChange { old, phase in
                if phase == .interacting { onUserScroll() }
                // Pull down past the top and let go: earlier messages load on the release, not the pull.
                if old == .interacting, phase != .interacting, pull >= Self.pullThreshold,
                   hasOlderMessages, !loadingMore {
                    pullLoads += 1
                    loadEarlier()
                }
            }
            .sensoryFeedback(.impact(weight: .medium), trigger: pullLoads)
            .progressiveTopEdge()
            .defaultScrollAnchor(.bottom)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            // The Task sheet or keyboard can shorten the viewport; keep the latest message in view.
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { _ in
                if followTail { proxy.scrollTo("tail", anchor: .bottom) }
            }
            .onChange(of: rows.last?.id) { _, _ in
                // A send owns its own motion: jump to the end so the reserved slot grows in place.
                if rows.last.map(isPending) == true { proxy.scrollTo("tail", anchor: .bottom) }
                else if followTail { withAnimation(CommaMotion.spatialMove) { proxy.scrollTo("tail", anchor: .bottom) } }
            }
            .onChange(of: rows.last?.text) { _, _ in
                if followTail { proxy.scrollTo("tail", anchor: .bottom) }
            }
        }
    }

    /// Above the oldest loaded message: a hint to pull, which turns once the pull is far enough to load.
    private struct PullToLoadIndicator: View {
        let loading: Bool
        let armed: Bool

        var body: some View {
            HStack(spacing: 6) {
                if loading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 12, weight: .semibold))
                        .rotationEffect(.degrees(armed ? 180 : 0))
                }
                Text(loading ? "Loading earlier messages…" : armed ? "Release to load earlier messages" : "Pull down to load earlier messages")
                    .contentTransition(.opacity)
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(CommaTheme.textTertiary)
            .frame(height: 32)
            .animation(CommaMotion.stateChange, value: armed)
            .animation(CommaMotion.stateChange, value: loading)
        }
    }

    private struct TailPosition: Equatable {
        let distance: CGFloat
        let container: CGFloat
        let content: CGFloat
    }

    // MARK: Rows

    @ViewBuilder private func rowView(_ row: ChatRow, proxy: ScrollViewProxy) -> some View {
        if row.isUser {
            HStack(spacing: 0) {
                Spacer(minLength: 42)
                VStack(alignment: .trailing, spacing: 6) {
                    if let message = row.message {
                        MessageExtras(message: message, taskSummary: taskSummary, openTask: openTask) { openAttachment(message, $0, $1) }
                    }
                    if !row.text.isEmpty {
                        Group {
                            if let flight {
                                OutgoingSlot(controller: flight, id: row.id) {
                                    MessageBubbles(text: row.text, isUser: true, tail: row.bubbleTail)
                                }
                            } else {
                                MessageBubbles(text: row.text, isUser: true, tail: row.bubbleTail)
                            }
                        }
                        .anchorPreference(key: ChatAnchorKey.self, value: .bounds) { [ChatAnchorID(row: row.id, part: .content): $0] }
                    }
                    if case .pending(_, let attachments, let failed, let attemptID) = row.content {
                        if !attachments.isEmpty {
                            Label("\(attachments.count) attachment(s)", systemImage: "paperclip")
                                .font(.system(size: 12)).foregroundStyle(CommaTheme.textQuaternary)
                        }
                        if failed {
                            Button { retry(attemptID) } label: {
                                Label("Not delivered · Retry", systemImage: "exclamationmark.circle")
                                    .font(.system(size: 12, weight: .medium)).foregroundStyle(CommaTheme.errorPrimary)
                            }
                            .transition(.opacity)
                        }
                    }
                }
            }
            .background(highlight(row))
        } else {
            HStack(alignment: .bottom, spacing: 0) {
                if showsIdentity(row) {
                    ZStack(alignment: .bottomLeading) {
                        Color.clear
                        if row.groupLast, let role = row.actorRole {
                            AgentAvatar(role: role).padding(4)
                                .anchorPreference(key: ChatAnchorKey.self, value: .bounds) { [ChatAnchorID(row: row.id, part: .avatar): $0] }
                        }
                    }
                    .frame(width: CommaTheme.avatarGutter)
                }
                VStack(alignment: .leading, spacing: 6) {
                    if let reply = row.reply, reply.presentation == .preview {
                        ReplyPreview(target: rows.first { $0.id == reply.targetID }) {
                            reveal(reply.targetID, proxy: proxy)
                        }
                        .anchorPreference(key: ChatAnchorKey.self, value: .bounds) { [ChatAnchorID(row: row.id, part: .preview): $0] }
                        .padding(.bottom, 6)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        if showsIdentity(row), row.groupFirst {
                            Text(row.actorRole == .router ? "Comma" : "Worker")
                                .font(.system(size: 12)).foregroundStyle(CommaTheme.textTertiary)
                                .padding(.leading, 13)
                        }
                        if row.isDraft && row.text.isEmpty {
                            ThinkingBubble(label: row.activityLabel ?? String(localized: "Thinking…"))
                        } else if !row.text.isEmpty {
                            // The tail marks the end of the message, so a following card or attachment takes it over.
                            MessageBubbles(text: row.text, isUser: false,
                                           tail: row.bubbleTail && !showsIdentity(row) && !(row.message.map(MessageExtras.hasContent) ?? false))
                        }
                        if let message = row.message {
                            MessageExtras(message: message, taskSummary: taskSummary, openTask: openTask) { openAttachment(message, $0, $1) }
                        }
                    }
                    .anchorPreference(key: ChatAnchorKey.self, value: .bounds) { [ChatAnchorID(row: row.id, part: .content): $0] }
                }
                Spacer(minLength: 42)
            }
            .background(highlight(row))
        }
    }

    private func highlight(_ row: ChatRow) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(CommaTheme.brandSolid.opacity(highlighted == row.id ? 0.1 : 0))
            .padding(-6)
            .animation(.easeOut(duration: 0.14), value: highlighted)
    }

    private func reveal(_ id: String, proxy: ScrollViewProxy) {
        guard rows.contains(where: { $0.id == id }) else {
            if hasOlderMessages { loadEarlier() }
            return
        }
        withAnimation(CommaMotion.spatialMove) { proxy.scrollTo(id, anchor: .center) }
        highlighted = id
        Task {
            try? await Task.sleep(for: .milliseconds(900))
            if highlighted == id { withAnimation(.linear(duration: 0.4)) { highlighted = nil } }
        }
    }

    /// Router identity is implied in Home; Tasks show who wrote each group.
    private func showsIdentity(_ row: ChatRow) -> Bool { isTask && !row.isUser }

    /// Same sender 6pt, a reply under its prompt 12pt, a new turn 20pt.
    private func spacing(before row: ChatRow, after previous: ChatRow) -> CGFloat {
        if row.isUser == previous.isUser { return row.groupFirst && !row.isUser && isTask ? 12 : 6 }
        return row.isUser ? 20 : 12
    }

    private func isNew(_ row: ChatRow) -> Bool {
        if row.isDraft { return true }
        guard let createdAt = row.createdAt else { return !row.isUser }
        return (createdAt > 100_000_000_000 ? createdAt / 1000 : createdAt) >= openedAt - 1
    }

    private func isPending(_ row: ChatRow) -> Bool {
        if case .pending = row.content { true } else { false }
    }

    private func transition(for row: ChatRow) -> AnyTransition {
        if isPending(row) { return flight == nil ? .outgoingBubble : .identity }
        return !row.isUser && isNew(row) ? .assistantEntry : .identity
    }

    // MARK: Reply connectors

    private struct Point { var x: CGFloat; var y: CGFloat; var radius: CGFloat; var bubbleEdge = false }

    /// Geometry from `MessageReplyLines.tsx`: avatar-to-avatar lines run on the avatar centre line;
    /// a user target gets a short rounded cap; hidden-identity rows connect at their bubble edges.
    private func connectors(anchors: [ChatAnchorID: Anchor<CGRect>], geometry: GeometryProxy) -> [ReplyConnector] {
        let index = Dictionary(rows.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        func rect(_ id: String, _ part: ChatAnchorID.Part) -> CGRect? {
            anchors[ChatAnchorID(row: id, part: part)].map { geometry[$0] }
        }
        func anchor(_ id: String, start: Bool) -> Point? {
            guard let row = index[id].map({ rows[$0] }) else { return nil }
            if !row.isUser && !showsIdentity(row), let content = rect(id, .content) {
                return Point(x: content.minX + 13, y: start ? content.minY - 8 : content.maxY + 8, radius: 0, bubbleEdge: true)
            }
            if let avatar = rect(id, .avatar) {
                return Point(x: avatar.midX, y: avatar.midY, radius: avatar.height / 2 + 4)
            }
            guard let content = rect(id, .content) else { return nil }
            return Point(x: content.minX - 5, y: content.midY, radius: 0)
        }
        var lines: [ReplyConnector] = []
        for row in rows {
            guard let reply = row.reply else { continue }
            let sourceID = showsIdentity(row) ? reply.sourceAnchorID : row.id
            guard let source = anchor(sourceID, start: true) else { continue }
            var target: Point?
            switch reply.presentation {
            case .line:
                target = anchor(reply.targetID, start: false)
                // An unmounted earlier target is above the viewport: reach the top of the content.
                if target == nil, let from = index[reply.targetID], let to = index[row.id], from < to {
                    target = Point(x: source.x, y: 0, radius: 0, bubbleEdge: true)
                }
            case .preview:
                if let preview = rect(row.id, .preview) {
                    target = Point(x: preview.minX + 13, y: preview.maxY, radius: 0, bubbleEdge: true)
                }
            }
            guard let target else { continue }
            let top = target.y + target.radius
            let bottom = source.y - source.radius
            guard bottom > top else { continue }
            var path = Path()
            if target.radius > 0 || target.bubbleEdge {
                path.move(to: CGPoint(x: source.x, y: top))
            } else {
                let bend = min(24, bottom - top)
                path.move(to: CGPoint(x: source.x + 24, y: top))
                path.addLine(to: CGPoint(x: source.x + bend, y: top))
                path.addQuadCurve(to: CGPoint(x: source.x, y: top + bend), control: CGPoint(x: source.x, y: top))
            }
            path.addLine(to: CGPoint(x: source.x, y: bottom))
            // Key by the target so a streaming draft that commits keeps its drawn line.
            let key = reply.presentation == .line ? "line:" + reply.targetID : "preview:" + row.relationshipID
            lines.append(ReplyConnector(id: key, path: path, animate: isNew(row)))
        }
        return lines
    }
}

// MARK: - Anchors

struct ChatAnchorID: Hashable {
    enum Part: Hashable { case content, avatar, preview }
    let row: String
    let part: Part
}

struct ChatAnchorKey: PreferenceKey {
    static let defaultValue: [ChatAnchorID: Anchor<CGRect>] = [:]
    static func reduce(value: inout [ChatAnchorID: Anchor<CGRect>], nextValue: () -> [ChatAnchorID: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, next in next }
    }
}

// MARK: - Connectors

struct ReplyConnector: Identifiable {
    let id: String
    let path: Path
    let animate: Bool
}

private struct ReplyConnectors: View {
    let lines: [ReplyConnector]
    var body: some View {
        ZStack {
            ForEach(lines) { line in ReplyLine(path: line.path, animate: line.animate) }
        }
    }
}

/// A 2.5pt round-capped stroke revealed from the earlier message down to the reply over 600ms, once.
private struct ReplyLine: View {
    let path: Path
    @State private var progress: CGFloat
    private let animate: Bool

    init(path: Path, animate: Bool) {
        self.path = path
        self.animate = animate
        _progress = State(initialValue: animate ? 0 : 1)
    }

    var body: some View {
        PathShape(path: path)
            .trim(from: 0, to: progress)
            .stroke(CommaTheme.borderPrimary, style: StrokeStyle(lineWidth: CommaTheme.replyLineWidth, lineCap: .round, lineJoin: .round))
            .onAppear {
                guard animate, progress < 1 else { return }
                withAnimation(.linear(duration: CommaMotion.replyDraw)) { progress = 1 }
            }
    }
}

private struct PathShape: Shape {
    let path: Path
    func path(in rect: CGRect) -> Path { path }
}

// MARK: - Reply preview

/// Quoted target shown above a reply whose thread was interrupted by another connector.
private struct ReplyPreview: View {
    let target: ChatRow?
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 13)).foregroundStyle(CommaTheme.textTertiary)
                .lineLimit(2).multilineTextAlignment(.leading)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(CommaTheme.borderPrimary, lineWidth: 1))
                .opacity(0.7)
        }
        .buttonStyle(TactileButtonStyle(scale: 0.98))
        .accessibilityLabel(Text("View replied message: \(text)"))
    }
    private var text: String {
        guard let target else { return String(localized: "Load earlier message") }
        let flat = target.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.isEmpty ? String(localized: "Attachment") : String(flat.prefix(180))
    }
}

// MARK: - Transitions

private struct OutgoingBubbleModifier: ViewModifier {
    let progress: CGFloat
    func body(content: Content) -> some View {
        content
            .scaleEffect(x: 0.86 + 0.14 * progress, y: 0.9 + 0.1 * progress, anchor: .bottomTrailing)
            .offset(y: 72 * (1 - progress))
            .opacity(Double(min(1, progress * 3)))
    }
}

private struct AssistantEntryModifier: ViewModifier {
    let progress: CGFloat
    func body(content: Content) -> some View {
        content.opacity(0.58 + 0.42 * progress).offset(y: 2 * (1 - progress))
    }
}

extension AnyTransition {
    /// The sent bubble rises out of the composer and widens into place (desktop outgoing flight springs).
    static var outgoingBubble: AnyTransition {
        .asymmetric(insertion: .modifier(active: OutgoingBubbleModifier(progress: 0), identity: OutgoingBubbleModifier(progress: 1))
                        .animation(CommaMotion.sendPosition),
                    removal: .identity)
    }
    static var assistantEntry: AnyTransition {
        .asymmetric(insertion: .modifier(active: AssistantEntryModifier(progress: 0), identity: AssistantEntryModifier(progress: 1))
                        .animation(CommaMotion.assistantEntry),
                    removal: .identity)
    }
}

// MARK: - Header edge

extension View {
    /// The transcript scrolls under a transparent header that blurs it progressively, like the desktop
    /// `ScrollArea edgeEffect="blur"`. iOS 26 provides the soft scroll edge; earlier systems get a matching
    /// material that fades out below the bar.
    @ViewBuilder func progressiveTopEdge() -> some View {
        if #available(iOS 26.0, *) {
            self.scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self.overlay(alignment: .top) {
                GeometryReader { geometry in
                    Rectangle().fill(.ultraThinMaterial)
                        .mask(LinearGradient(stops: [.init(color: .black, location: 0),
                                                     .init(color: .black, location: 0.45),
                                                     .init(color: .clear, location: 1)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(height: geometry.safeAreaInsets.top + 28)
                        .offset(y: -geometry.safeAreaInsets.top)
                }
                .allowsHitTesting(false)
            }
        }
    }
}
