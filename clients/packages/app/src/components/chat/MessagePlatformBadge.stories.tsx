import type { Meta, StoryObj } from "@storybook/react-vite";
import { expect, waitFor, within } from "storybook/test";
import "../../styles.css";
import { ConversationThread } from "./thread/ConversationThread";
import type { ChatMessage } from "@comma/core/chat";
import { getMessagePlatformBubbleStyle } from "./MessagePlatformBadge";
import { MessageCopyAction } from "./thread/rows/MessageCopyAction";
import { UserMessageBubble } from "./thread/rows/user/UserMessageBubble";

function message(
  messageId: string,
  role: "user" | "assistant",
  text: string,
  platformSource?: string
): ChatMessage {
  return {
    messageId,
    role,
    text,
    platformSource,
    actorRole: role === "assistant" ? "router" : undefined,
    parts: [{ kind: "markdown", text }],
    attachments: [],
    refs: [],
    delivery: "sent",
    source: "server",
    status: "completed",
  };
}

const meta = {
  // Asserts badge geometry and the computed opacity on focus.
  tags: ["browser"],
  title: "App components/Chat/Platform messages",
  component: ConversationThread,
  parameters: { layout: "fullscreen" },
  args: {
    defaultAssistantActorRole: "router",
    groupId: "storybook-platform-group",
    workspaceId: "storybook-platform-workspace",
    onDiscard: () => {},
    onRetry: () => {},
    messages: [
      message("home-question", "user", "Keep my conversations in one place."),
      message("wechat-question", "user", "今晚七点的餐厅订好了吗？", "wechat"),
      message("wechat-answer", "assistant", "订好了，今晚七点，两位。", "wechat"),
      message("telegram-question", "user", "Send me the meeting notes.", "telegram"),
      message(
        "telegram-answer",
        "assistant",
        "The notes are ready to review.",
        "telegram"
      ),
      message("signal-question", "user", "Are we still on for tomorrow?", "signal"),
      message("signal-answer", "assistant", "Yes, tomorrow at 10 works.", "signal"),
    ],
  },
  decorators: [
    (Story) => (
      <div style={{ height: 860, maxWidth: 760, margin: "auto", display: "flex" }}>
        <Story />
      </div>
    ),
  ],
} satisfies Meta<typeof ConversationThread>;

export default meta;
type Story = StoryObj<typeof meta>;

// Focusing Copy reveals the actions; each source badge sits just before it.
async function expectBadgesBesideCopy(
  canvasElement: HTMLElement,
  lastText: string,
  names: string[]
) {
  const canvas = within(canvasElement);
  await canvas.findByText(lastText);
  const articles: HTMLElement[] = [];
  for (const name of names) {
    const badge = canvas.getByTitle(name);
    const article = badge.closest("article")!;
    const copy = within(article).getByRole("button", { name: "Copy message" });
    copy.focus();
    await waitFor(() => {
      expect(getComputedStyle(badge.parentElement!).opacity).toBe("1");
    });
    expect(badge.getBoundingClientRect().right).toBeLessThanOrEqual(
      copy.getBoundingClientRect().left
    );
    articles.push(article);
  }
  return articles;
}

export const MixedPlatforms: Story = {
  play: async ({ canvasElement }) => {
    await expectBadgesBesideCopy(canvasElement, "The notes are ready to review.", [
      "WeChat",
      "Telegram",
      "Signal",
    ]);
  },
};

export const Dark: Story = { ...MixedPlatforms, globals: { theme: "dark" } };

export const OtherCommaApps: Story = {
  args: {
    messages: [
      {
        ...message("iphone-question", "user", "Remind me at six."),
        clientSource: "iphone",
      },
      message("iphone-answer", "assistant", "I'll remind you at six."),
      {
        ...message("watch-question", "user", "What's next today?"),
        clientSource: "watch",
      },
      message("watch-answer", "assistant", "A design review at four."),
      {
        ...message("android-question", "user", "Call me a ride."),
        clientSource: "android",
      },
      message("android-answer", "assistant", "A car arrives in five minutes."),
      {
        ...message("windows-question", "user", "Open the budget sheet."),
        clientSource: "windows",
      },
      message("windows-answer", "assistant", "The sheet is open."),
      {
        ...message("web-question", "user", "Draft the reply."),
        clientSource: "web",
      },
      message("web-answer", "assistant", "The draft is ready."),
    ],
  },
  play: async ({ canvasElement }) => {
    const articles = await expectBadgesBesideCopy(
      canvasElement,
      "The draft is ready.",
      ["iPhone", "Apple Watch", "Android", "Windows"]
    );
    for (const article of articles) {
      // The app the user typed in is not a chat platform: the bubble keeps
      // the default Comma colour.
      expect(
        article
          .querySelector<HTMLElement>(".comma-chat-user-bubble")
          ?.style.getPropertyValue("--comma-chat-user-bubble-background") ?? ""
      ).toBe("");
    }
    // Storybook runs as the web app: a message sent from the web is this app's own.
    expect(within(canvasElement).queryByTitle("Web")).toBeNull();
  },
};

export const IMessageAndDiscord: Story = {
  args: {
    messages: [
      message("imessage-question", "user", "I'll arrive at six.", "imessage"),
      message("imessage-answer", "assistant", "See you then!", "imessage"),
      message("discord-question", "user", "Is the game night still on?", "discord"),
      message(
        "discord-answer",
        "assistant",
        "Yes, we're starting at eight.",
        "discord"
      ),
    ],
  },
};

export const AllPlatformBubbles: Story = {
  render: () => (
    <div
      data-testid="platform-bubble-gallery"
      style={{
        width: "100%",
        alignSelf: "flex-start",
        padding: 24,
        display: "grid",
        gridTemplateColumns: "repeat(2, minmax(0, 1fr))",
        alignContent: "start",
        gap: 20,
      }}
    >
      {(
        [
          ["wechat", "WeChat"],
          ["telegram", "Telegram"],
          ["signal", "Signal"],
          ["slack", "Slack"],
          ["feishu", "Feishu"],
          ["lark", "Lark"],
          ["imessage", "iMessage"],
          ["discord", "Discord"],
        ] as const
      ).map(([platform, name]) => {
        const colors = getMessagePlatformBubbleStyle(platform) as Record<
          string,
          string
        >;
        const body = "重启了一下好了";
        return (
          <section
            key={platform}
            style={{
              padding: 20,
              borderRadius: 16,
              background: "var(--color-bg-secondary)",
            }}
          >
            <div style={{ display: "flex", justifyContent: "space-between", gap: 8 }}>
              <strong>{name}</strong>
              <span style={{ color: "var(--color-text-tertiary)", fontSize: 12 }}>
                {colors["--comma-chat-user-bubble-background"]!.toUpperCase()}
              </span>
            </div>
            <div className="comma-chat-thread" style={{ marginTop: 32 }}>
              <article className="comma-chat-message-user" data-bubble-tail="right">
                <div className="comma-chat-user-bubble-row">
                  <UserMessageBubble platform={platform} text={body} />
                  <MessageCopyAction
                    ariaLabel="Copy message"
                    copyText={body}
                    messageId={`preview-${platform}`}
                    platform={platform}
                  />
                </div>
              </article>
            </div>
          </section>
        );
      })}
    </div>
  ),
};
