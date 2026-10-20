import SwiftUI
import CommaCore

// MARK: - Bubble

enum BubbleTail { case none, leading, trailing }

/// A chat bubble with the desktop's 20pt radius and optional message tail.
/// The tail uses the same vector as `message-tail.svg`: 16×10, 8pt in from the edge, hanging 7pt below.
struct ChatBubbleSurface<Label: View>: View {
    var fill: Color
    var tail: BubbleTail = .none
    var radius: CGFloat = CommaTheme.bubbleRadius
    @ViewBuilder var label: Label

    var body: some View {
        label
            .background(alignment: tail == .leading ? .bottomLeading : .bottomTrailing) {
                ZStack(alignment: tail == .leading ? .bottomLeading : .bottomTrailing) {
                    RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill)
                    if tail != .none {
                        Image("MessageTail").renderingMode(.template).resizable()
                            .foregroundStyle(fill)
                            .frame(width: 16, height: 10)
                            .scaleEffect(x: tail == .leading ? -1 : 1, y: 1)
                            .offset(x: tail == .leading ? 8 : -8, y: 7)
                    }
                }
            }
    }
}

/// Text bubbles for one message: one bubble per Markdown block for assistants (from the tree the core parsed), one
/// bubble for users.
struct MessageBubbles: View {
    let text: String
    let isUser: Bool
    let tail: Bool
    var compact = false
    /// An agent's message as the core parsed it, and the parts its Task chips name.
    var markdown: CoreJSON? = nil
    var parts: [ChatPart] = []

    var body: some View {
        if isUser {
            ChatBubbleSurface(fill: CommaTheme.brandSolid, tail: tail ? .trailing : .none, radius: radius) {
                Text(Self.inline(text)).font(font).foregroundStyle(.white)
                    .tint(.white)
                    .padding(padding)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .selectableMessageText()
        } else {
            if let tree = markdown?.array {
                MarkdownBubbles(tree: tree, parts: parts, tail: tail, compact: compact)
            } else {
                MarkdownBubbles(text: text, tail: tail, compact: compact)
            }
        }
    }

    private var font: Font { CommaTheme.messageFont }
    private var radius: CGFloat { compact ? 16 : CommaTheme.bubbleRadius }
    private var padding: EdgeInsets {
        compact ? EdgeInsets(top: 7, leading: 10, bottom: 7, trailing: 10) : CommaTheme.bubblePadding
    }

    /// A user message's inline Markdown, as its bubble and the send flight draw it. A Task mention's
    /// `[Title](comma:task/<id>)` reads `@Title`, as the composer showed it, in semibold so it stands out from the
    /// message as the desktop's mention does, and its link opens the Task (desktop `userMessageContentWithMentions`).
    /// A model mention's `[GPT 5.5 · high](comma:model/<id>?effort=high)` reads `@GPT 5.5 · high` the same way, and
    /// opens nothing (desktop `modelMentionsAsWords`).
    static func inline(_ value: String) -> AttributedString {
        let parsed = (try? AttributedString(markdown: value, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(value)
        guard value.contains("](comma:task/") || value.contains("](" + ModelMention.linkPrefix) else { return parsed }
        var result = AttributedString()
        for (link, range) in parsed.runs[\.link] {
            guard let link, TaskMention.conversationID(from: link) != nil || ModelMention.isLink(link),
                  let first = parsed[range].runs.first else {
                result += parsed[range]
                continue
            }
            var mention = AttributedString("@", attributes: first.attributes) + AttributedString(parsed[range])
            mention.font = CommaTheme.messageFont.weight(.semibold)
            if ModelMention.isLink(link) { mention.link = nil }
            result += mention
        }
        return result
    }
}

/// Agent avatar: the Comma mark for the Router and a sparkle on the worker colour for Workers.
struct AgentAvatar: View {
    let role: ChatActorRole
    var size: CGFloat = 16
    var body: some View {
        Group {
            switch role {
            case .router:
                CommaMark(size: size).foregroundStyle(CommaTheme.textPrimary)
            case .worker:
                CentralIcon("central-sparkles-two", size: size * 0.7)
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(CommaTheme.agentAvatar, in: Circle())
                    .overlay(Circle().strokeBorder(CommaTheme.borderPrimary, lineWidth: 0.5))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
