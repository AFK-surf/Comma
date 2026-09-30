import type { Meta, StoryObj } from "@storybook/react-vite";
import { useLayoutEffect, useRef, useState } from "react";
import { expect, userEvent, within } from "storybook/test";
import { ScrollArea } from "../scroll-area";
import {
  SideChatCardsPanel,
  SideChatComposer,
  SideChatDiagnostics,
  SideChatPanel,
  SideChatStatus,
  SideChatSurface,
  type SideChatTask,
} from "./SideChat";

type StoryArgs = {
  backgroundMock: boolean;
  messageCount: number;
};

const meta = {
  title: "Side Chat/Overview",
  args: { backgroundMock: false, messageCount: 7 },
  argTypes: {
    backgroundMock: {
      control: "boolean",
      description: "Place a desktop wallpaper behind Side Chat",
      name: "Background image mock",
    },
    messageCount: {
      control: { max: 12, min: 2, step: 1, type: "range" },
      description: "Increase until the conversation genuinely needs to scroll",
      name: "Message count",
    },
  },
  parameters: { layout: "fullscreen" },
} satisfies Meta<StoryArgs>;

export default meta;
type Story = StoryObj<StoryArgs>;

const tasks: SideChatTask[] = [
  {
    activityStatus: "running_tests",
    conversationId: "cnv-task-1",
    createdAt: 1_784_200_000,
    groupId: "grp-story",
    id: "task-1",
    lastMessage: { content: "Renderer wiring is ready" },
    statusBucket: "in_progress",
    title: "Implement native bridge",
    workspaceId: "wsp-story",
  },
  {
    activityStatus: "idle",
    conversationId: "cnv-task-2",
    createdAt: 1_784_200_100,
    groupId: "grp-story",
    id: "task-2",
    statusBucket: "backlog",
    title: "Audit blur parity",
    workspaceId: "wsp-story",
  },
];

function DesktopCanvas({
  backgroundMock,
  children,
}: {
  backgroundMock: boolean;
  children: React.ReactNode;
}) {
  const [showBackground, setShowBackground] = useState(backgroundMock);
  const [sideChatVisible, setSideChatVisible] = useState(true);
  return (
    <div className="side-chat-story-desktop" data-background-mock={showBackground}>
      <div className="side-chat-story-controls">
        <button
          aria-pressed={sideChatVisible}
          className="side-chat-story-toggle"
          onClick={() => setSideChatVisible((visible) => !visible)}
          type="button"
        >
          Side Chat: {sideChatVisible ? "shown" : "hidden"}
        </button>
        <button
          aria-pressed={showBackground}
          className="side-chat-story-toggle"
          onClick={() => setShowBackground((visible) => !visible)}
          type="button"
        >
          Background mock: {showBackground ? "on" : "off"}
        </button>
      </div>
      <SideChatSurface
        data-story-layout="fill-available-height"
        data-story-visible={sideChatVisible}
        phase={sideChatVisible ? "open" : "closed"}
        progress={sideChatVisible ? 1 : 0}
        style={{ bottom: 12, left: 12, top: 12, width: 400 }}
      >
        {children}
      </SideChatSurface>
    </div>
  );
}

const conversationMessages = [
  { id: "1", role: "assistant", text: "I found two tasks that need attention." },
  { id: "2", role: "user", text: "Show me the active one." },
  {
    id: "3",
    role: "assistant",
    text: "The native bridge task is active. Renderer wiring is complete and the focused tests are passing.",
  },
  { id: "4", role: "user", text: "What is left before we can merge it?" },
  {
    id: "5",
    role: "assistant",
    text: "I still need to verify the signed-out state, the diagnostic window transition, and the layout over a busy desktop background.",
  },
  {
    id: "6",
    role: "user",
    text: "Keep the panel anchored to the bottom while you check all of that.",
  },
  {
    id: "7",
    role: "assistant",
    text: "Done. The latest messages stay beside the composer and older messages remain available by scrolling.",
  },
  {
    id: "8",
    role: "user",
    text: "Now add enough history to cross the visible boundary.",
  },
  {
    id: "9",
    role: "assistant",
    text: "The panel is full now, so this is the point where scrolling should begin.",
  },
  { id: "10", role: "user", text: "Keep the newest response visible." },
  {
    id: "11",
    role: "assistant",
    text: "The viewport remains anchored to the latest message while older content moves above it.",
  },
  {
    id: "12",
    role: "user",
    text: "Perfect — scrolling only after the available height is used.",
  },
] as const;

function ConversationHistory({ messageCount }: { messageCount: number }) {
  const areaRef = useRef<HTMLDivElement | null>(null);
  const scrollToLatest = () => {
    const viewport = areaRef.current?.querySelector<HTMLElement>(
      ".comma-scroll-area__viewport"
    );
    if (viewport) viewport.scrollTop = viewport.scrollHeight;
  };
  useLayoutEffect(scrollToLatest, []);

  return (
    <ScrollArea
      className="side-chat-story-history"
      contentClassName="side-chat-story-history-list"
      edgeEffect="none"
      onContentResize={scrollToLatest}
      orientation="vertical"
      ref={areaRef}
    >
      {conversationMessages.slice(0, messageCount).map((message) => (
        <div className={`side-chat-story-${message.role}`} key={message.id}>
          {message.text}
        </div>
      ))}
    </ScrollArea>
  );
}

function InteractivePanel({
  backgroundMock,
  cardsVisible = false,
  messageCount,
}: StoryArgs & { cardsVisible?: boolean }) {
  const [draft, setDraft] = useState("");
  return (
    <DesktopCanvas backgroundMock={backgroundMock}>
      <SideChatPanel
        cards={<SideChatCardsPanel capability={{ status: "ready", tasks }} />}
        cardsVisible={cardsVisible}
      >
        <div className="side-chat-story-conversation">
          <ConversationHistory messageCount={messageCount} />
          <SideChatComposer
            onSubmit={() => setDraft("")}
            onValueChange={setDraft}
            value={draft}
          />
        </div>
      </SideChatPanel>
    </DesktopCanvas>
  );
}

export const Conversation: Story = {
  args: { backgroundMock: true, messageCount: 7 },
  render: (args) => <InteractivePanel {...args} />,
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement);
    const visibilityToggle = canvas.getByRole("button", {
      name: "Side Chat: shown",
    });
    const sideChat = canvasElement.querySelector(".comma-side-chat-host");

    await userEvent.click(visibilityToggle);
    expect(sideChat).toHaveAttribute("data-story-visible", "false");

    await userEvent.click(canvas.getByRole("button", { name: "Side Chat: hidden" }));
    expect(sideChat).toHaveAttribute("data-story-visible", "true");
  },
};
export const TaskCards: Story = {
  render: (args) => <InteractivePanel {...args} cardsVisible />,
};

export const SignedOut: Story = {
  render: (args) => (
    <DesktopCanvas backgroundMock={args.backgroundMock}>
      <SideChatPanel>
        <div className="side-chat-story-fallback">
          <SideChatStatus
            action={
              <button className="side-chat-story-link" type="button">
                Sign in
              </button>
            }
            detail="Use the Comma main window to sign in. Side Chat will reconnect automatically."
            title="Sign in to use Side Chat"
          />
          <SideChatComposer
            disabled
            onSubmit={() => undefined}
            onValueChange={() => undefined}
            value=""
          />
        </div>
      </SideChatPanel>
    </DesktopCanvas>
  ),
};

export const Connecting: Story = {
  render: (args) => (
    <DesktopCanvas backgroundMock={args.backgroundMock}>
      <SideChatPanel>
        <SideChatStatus title="Connecting to Comma…" />
      </SideChatPanel>
    </DesktopCanvas>
  ),
};

export const Diagnostics: Story = {
  render: (args) => (
    <div className="side-chat-story-desktop" data-background-mock={args.backgroundMock}>
      <SideChatDiagnostics
        contentVisible
        expanded
        metrics={{
          devicePixelRatio: 2,
          devicePixelSize: { height: 960, width: 1440 },
          presentation: {
            displayId: 1,
            offsetX: -539,
            phase: "open",
            progress: 1,
            revision: 18,
          },
          viewportSize: { height: 480, width: 720 },
        }}
        onDismiss={() => undefined}
        onRefresh={() => undefined}
        sourceFrame={{ height: 30, width: 30, x: 220, y: 420 }}
      />
    </div>
  ),
};
