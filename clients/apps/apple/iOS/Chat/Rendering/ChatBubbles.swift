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

/// A person's message that came in from a chat platform takes that platform's bubble colour, the same values the
/// desktop and Android draw (`clients/packages/app/src/components/chat/MessagePlatformBadge.tsx`). A message typed in
/// a Comma app keeps the brand bubble.
enum PlatformBubble {
    /// `text` is nil where the default white reads on the fill.
    struct Colors { let fill: Color; let text: Color? }

    static func colors(_ platform: String?) -> Colors? {
        switch platform {
        case "wechat": Colors(fill: Color(hex: 0x9DF29F), text: Color(hex: 0x082D07))
        case "telegram": Colors(fill: Color(hex: 0xB8EAF7), text: Color(hex: 0x082B3A))
        case "signal": Colors(fill: Color(hex: 0x3B6DE3), text: nil)
        case "slack": Colors(fill: Color(hex: 0x611F69), text: nil)
        case "feishu", "lark": Colors(fill: Color(hex: 0x2C61E8), text: nil)
        // Messages green differs by theme.
        case "imessage": Colors(fill: CommaTheme.dynamic(light: 0x4BDE70, dark: 0x30D65B), text: nil)
        case "discord": Colors(fill: Color(hex: 0x5865F2), text: nil)
        default: nil
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
    /// The chat platform a person's message came in from.
    var platform: String? = nil
    /// Another person's words in a Task together: on the left, in the incoming bubble.
    var incoming = false

    var body: some View {
        if isUser && incoming {
            ChatBubbleSurface(fill: CommaTheme.bubbleAssistant, tail: tail ? .leading : .none, radius: radius) {
                Text(Self.inline(text)).font(font).foregroundStyle(CommaTheme.textPrimary)
                    .padding(padding)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .selectableMessageText()
        } else if isUser {
            let colors = PlatformBubble.colors(platform)
            ChatBubbleSurface(fill: colors?.fill ?? CommaTheme.brandSolid, tail: tail ? .trailing : .none, radius: radius) {
                Text(Self.inline(text)).font(font).foregroundStyle(colors?.text ?? .white)
                    .tint(colors?.text ?? .white)
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
