import SwiftUI
import CommaCore

extension ChatTranscriptView {
    // MARK: Reply connectors

    private struct Point { var x: CGFloat; var y: CGFloat; var radius: CGFloat; var bubbleEdge = false }

    /// Geometry from `MessageReplyLines.tsx`: avatar-to-avatar lines run on the avatar centre line;
    /// a user target gets a short rounded cap; hidden-identity rows connect at their bubble edges.
    func connectors(anchors: [ChatAnchorID: Anchor<CGRect>], geometry: GeometryProxy) -> [ReplyConnector] {
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
            // A member's reply sits on the other side: the line drops from under the message it answers and turns
            // toward the reply at its height in a short arm, the mirror of an Agent's hook to a member's prompt.
            if row.isUser {
                guard let content = rect(row.id, .content) else { continue }
                let y = content.midY
                guard y > top else { continue }
                let bend = min(24, y - top)
                var path = Path()
                path.move(to: CGPoint(x: target.x, y: top))
                path.addLine(to: CGPoint(x: target.x, y: y - bend))
                path.addQuadCurve(to: CGPoint(x: target.x + bend, y: y), control: CGPoint(x: target.x, y: y))
                path.addLine(to: CGPoint(x: target.x + 24, y: y))
                lines.append(ReplyConnector(id: "line:" + reply.targetID, path: path, animate: isNew(row)))
                continue
            }
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

struct ReplyConnectors: View {
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
