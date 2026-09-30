import "@comma/ui/styles.css";
import "../../../../../packages/app/src/styles.css";

import { MarkdownStream } from "@comma/ui";
import {
  RouterProvider,
  createMemoryHistory,
  createRootRoute,
  createRouter,
} from "@tanstack/react-router";
import {
  Children,
  isValidElement,
  StrictMode,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ComponentProps,
} from "react";
import { createRoot } from "react-dom/client";
import type { CommaApiClient } from "../../../../../packages/app/src/api";
import { measureOutgoingBubbleSource } from "../../../../../packages/app/src/components/chat/motion/outgoingBubbleMotion";
import { ParticipantStatusSlot } from "../../../../../packages/app/src/components/chat/thread/activity/ActivityLine";
import {
  ConversationThread,
  type ChatOutgoingLaunch,
} from "../../../../../packages/app/src/components/chat/thread/ConversationThread";
import {
  idleConversationChannelState,
  type ChatAssistantDraft,
  type ChatMessage,
  type ChatParticipantStatus,
  type ConversationChannelState,
  type PendingSend,
} from "../../../../../packages/app/src/components/chat/model/conversationChannel";
import {
  ConversationView,
  type ConversationViewActions,
} from "../../../../../packages/app/src/components/chat/conversation/ConversationView";
import { fixedDraftSource } from "../../../../../packages/app/src/components/chat/composer/conversationDraft";
import { CommaUiThemeProvider } from "../../../../../packages/app/src/components/commaUiTheme";
import type { CommaUiThemeName } from "../../../../../packages/app/src/components/sideChatAppearance";

const introMarkdown = [
  "# Streaming Markdown Fixture",
  "",
  "Comma renders **assistant output** while it is still arriving.",
].join("\n");

const fullMarkdown = [
  "# Streaming Markdown Fixture",
  "",
  "Comma renders **assistant output** while it is still arriving. This covers ~~deleted text~~, ==highlighted text==, ++inserted text++, and `inlineCode()`.",
  "",
  "```tsx",
  "type MarkdownStatus = 'streaming' | 'done'",
  "",
  "export const status: MarkdownStatus = 'streaming'",
  "```",
  "",
  "```mermaid",
  "flowchart TD",
  "  Start[Token] --> Parse[Parse]",
  "  Parse --> Render[Render]",
  "```",
  "",
  "Inline math $E = mc^2$ and display math:",
  "",
  "$$",
  "a^2 + b^2 = c^2",
  "$$",
  "",
  "The final sentinel should stay hidden until the complete blur cursor reaches it.",
].join("\n");

const retargetAMarkdown = [
  "# Stable answer A",
  "",
  "The first answer must remain readable while the same stream is retargeted.",
  "",
  "Alpha context stays on screen without collapsing. ".repeat(8),
  "",
  "RETARGET_A_READY",
].join("\n");

const retargetBMarkdown = [
  "# Replacement answer B",
  "",
  "The replacement begins with unrelated Markdown, so this is not a prefix append.",
  "",
  "Beta context becomes readable in one bounded presentation handoff. ".repeat(8),
  "",
  "RETARGET_B_READY",
].join("\n");

const timestampFixtureStartedAt = (() => {
  const today = new Date();
  today.setHours(12, 0, 0, 0);
  return today.getTime();
})();
const outgoingHistoryUserKeys = Array.from(
  { length: 6 },
  (_, index) => `turn-history-user-${index}`
);

type ScenarioName = "intro" | "full" | "final" | "retarget-a" | "retarget-b";
type ConversationStage = "history" | "sent" | "draft" | "draft-grown" | "final";
type SideChatMotionStage = "idle" | "waiting" | "streaming" | "final";
type DelayedActivityVariant = "route" | "side-chat";
type OutgoingUserStage = "pending" | "failed" | "canonical";
type OutgoingUserEntry = {
  clientRequestId: string;
  createdAt: number;
  ordinal: number;
  stage: OutgoingUserStage;
  text: string;
};

declare global {
  interface Window {
    conversationViewRejectedSendFixture?: {
      prepareQuoteAdmission: () => void;
      reject: () => boolean;
    };
    delayedOutgoingActivityFixture?: {
      route?: {
        reset: () => void;
        start: () => void;
      };
      sideChat?: {
        reset: () => void;
        start: () => void;
      };
    };
    markdownStreamFixture?: {
      getSnapshot: () => {
        animatedCharacters: number;
        hasHighlightedCode: boolean;
        hasMermaidSvg: boolean;
        text: string;
      };
      setContent: (content: string, final?: boolean) => void;
      setConversationStage: (stage: ConversationStage) => void;
      ackOutgoingUser: () => void;
      failOutgoingUser: () => void;
      resetOutgoingUser: () => void;
      setOutgoingHistoryEnabled: (enabled: boolean) => void;
      setOutgoingUserText: (text: string) => void;
      setSideChatMotion: (stage: SideChatMotionStage, text?: string) => void;
      setScenario: (scenario: ScenarioName) => void;
      setTheme: (theme: CommaUiThemeName) => void;
      startOutgoingUser: () => void;
    };
  }
}

// Performance runs mount one scenario so unrelated transcript demos do not rerender.
function FixtureScope({ children, ...props }: ComponentProps<"main">) {
  const selected = new URLSearchParams(window.location.search).get("fixture");
  const visible = selected
    ? Children.toArray(children).filter(
        (child) =>
          isValidElement<{ "data-testid"?: string }>(child) &&
          child.props["data-testid"] === selected
      )
    : children;
  return <main {...props}>{visible}</main>;
}

function MarkdownStreamFixture() {
  const [state, setState] = useState({ content: introMarkdown, final: true });
  const [conversationStage, setConversationStage] =
    useState<ConversationStage>("history");
  const [sideChatMotion, setSideChatMotion] = useState<{
    stage: SideChatMotionStage;
    text: string;
  }>({ stage: "idle", text: "" });
  const [outgoingUserEntries, setOutgoingUserEntries] = useState<
    readonly OutgoingUserEntry[]
  >([]);
  const outgoingUserEntriesRef = useRef<readonly OutgoingUserEntry[]>([]);
  const [outgoingUserText, setOutgoingUserText] = useState(defaultOutgoingUserText);
  const outgoingUserTextRef = useRef(defaultOutgoingUserText);
  const [outgoingLaunches, setOutgoingLaunches] = useState<
    readonly ChatOutgoingLaunch[]
  >([]);
  const [outgoingHistoryEnabled, setOutgoingHistoryEnabled] = useState(false);
  const outgoingLaunchId = useRef(0);
  const [theme, setTheme] = useState<CommaUiThemeName>("Light mode");
  const blurAnimation = useMemo(
    () => ({
      activeCharacters: 80,
      blurRadiusPx: 6,
      characterDelayMs: 1,
      durationMs: 800,
      initialOpacity: 0.28,
      translateYEm: 0.4,
    }),
    []
  );

  useEffect(() => {
    window.markdownStreamFixture = {
      getSnapshot: () => {
        const fixture = document.querySelector(
          "[data-testid='markdown-stream-fixture']"
        );

        return {
          animatedCharacters: document.querySelectorAll(".markdown-stream-char-enter")
            .length,
          hasHighlightedCode: Boolean(
            document.querySelector(
              ".markdown-stream-code-body .code-block-render:not(.hidden)"
            )
          ),
          hasMermaidSvg: Boolean(
            document.querySelector(".markdown-stream-mermaid-svg svg")
          ),
          text: fixture?.textContent ?? "",
        };
      },
      setContent: (content, final = false) => {
        setState({ content, final });
      },
      setConversationStage,
      ackOutgoingUser: () => {
        const latest = outgoingUserEntriesRef.current.at(-1);
        if (!latest) return;
        const next = outgoingUserEntriesRef.current.map((entry) =>
          entry === latest ? { ...entry, stage: "canonical" as const } : entry
        );
        outgoingUserEntriesRef.current = next;
        setOutgoingUserEntries(next);
      },
      failOutgoingUser: () => {
        const latest = outgoingUserEntriesRef.current.at(-1);
        if (!latest) return;
        const next = outgoingUserEntriesRef.current.map((entry) =>
          entry === latest ? { ...entry, stage: "failed" as const } : entry
        );
        outgoingUserEntriesRef.current = next;
        setOutgoingUserEntries(next);
      },
      resetOutgoingUser: () => {
        outgoingLaunchId.current = 0;
        outgoingUserEntriesRef.current = [];
        outgoingUserTextRef.current = defaultOutgoingUserText;
        setOutgoingLaunches([]);
        setOutgoingHistoryEnabled(false);
        setOutgoingUserEntries([]);
        setOutgoingUserText(defaultOutgoingUserText);
      },
      setOutgoingHistoryEnabled,
      setOutgoingUserText: (text) => {
        outgoingUserTextRef.current = text;
        setOutgoingUserText(text);
      },
      setSideChatMotion: (stage, text = "") => {
        setSideChatMotion({ stage, text });
      },
      setScenario: (scenario) => {
        if (scenario === "intro") {
          setState({ content: introMarkdown, final: false });
          return;
        }

        if (scenario === "retarget-a") {
          setState({ content: retargetAMarkdown, final: false });
          return;
        }

        if (scenario === "retarget-b") {
          setState({ content: retargetBMarkdown, final: false });
          return;
        }

        setState({ content: fullMarkdown, final: scenario === "final" });
      },
      setTheme,
      startOutgoingUser: () => {
        const source = document.querySelector<HTMLElement>(
          "[data-testid='outgoing-user-composer-surface']"
        );
        if (!source) {
          throw new Error("Outgoing user source geometry was not ready.");
        }
        const entries = outgoingUserEntriesRef.current;
        const ordinal = entries.length + 1;
        const id = ++outgoingLaunchId.current;
        const clientRequestId =
          ordinal === 1 ? "outgoing-user-request" : `outgoing-user-request-${ordinal}`;
        const text = outgoingUserTextRef.current;
        const nextEntries = [
          ...entries,
          {
            clientRequestId,
            createdAt: timestampFixtureStartedAt + ordinal - 1,
            ordinal,
            stage: "pending" as const,
            text,
          },
        ];
        outgoingUserEntriesRef.current = nextEntries;
        outgoingUserTextRef.current = "";
        setOutgoingLaunches((current) => [
          ...current,
          {
            // A real composer launch snapshots every user turn already present
            // in the thread. Include the opt-in history fixture keys too so
            // presentation matching cannot claim an old historical message.
            existingTurnKeys: new Set([
              ...outgoingHistoryUserKeys,
              ...entries.map((entry) => entry.clientRequestId),
            ]),
            expiresAt: Date.now() + 2_000,
            id,
            sourceFrame: measureOutgoingBubbleSource(source),
            startedFromEmpty: false,
            text,
          },
        ]);
        setOutgoingUserEntries(nextEntries);
        setOutgoingUserText("");
      },
    };

    return () => {
      delete window.markdownStreamFixture;
    };
  }, []);

  const productMessage: ChatMessage = {
    attachments: [],
    blocksKey: undefined,
    clientRequestId: undefined,
    createdAt: 1,
    createdBy: undefined,
    delivery: "sent",
    error: undefined,
    messageId: "product-markdown",
    parts: [{ kind: "markdown", text: state.content }],
    refs: [],
    role: "assistant",
    source: "server",
    status: "completed",
    text: state.content,
  };
  const productUserMessage: ChatMessage = {
    attachments: [],
    blocksKey: undefined,
    clientRequestId: undefined,
    createdAt: 0,
    createdBy: undefined,
    delivery: "sent",
    error: undefined,
    messageId: "product-user-message",
    parts: [{ kind: "markdown", text: "User message typography" }],
    refs: [],
    role: "user",
    source: "server",
    status: "completed",
    text: "User message typography",
  };
  const defaultProductMessage: ChatMessage = {
    ...productMessage,
    messageId: "product-markdown-default",
    parts: [{ kind: "markdown", text: introMarkdown }],
    text: introMarkdown,
  };
  const generatedFileMessage: ChatMessage = {
    ...productMessage,
    attachments: [
      {
        attachmentIndex: 1,
        blockType: "file",
        fileName: "generated-report.pdf",
        mimeType: "application/pdf",
        size: 12,
        title: "generated-report.pdf",
      },
    ],
    messageId: "generated-file-download-contract",
    parts: [{ kind: "markdown", text: "The generated report is ready." }],
    text: "The generated report is ready.",
  };
  const downloadContractApi = useMemo(
    () =>
      ({
        fetchConversationAttachment: async () =>
          new Blob(["report bytes"], { type: "application/pdf" }),
      }) as Partial<CommaApiClient> as CommaApiClient,
    []
  );
  const timestampMessages: ChatMessage[] = [
    {
      ...productUserMessage,
      createdAt: timestampFixtureStartedAt,
      messageId: "timestamp-user-start",
      text: "Start this timestamp interval",
    },
    {
      ...productUserMessage,
      createdAt: timestampFixtureStartedAt + 59_999,
      messageId: "timestamp-user-within",
      text: "Remain inside this timestamp interval",
    },
    {
      ...productUserMessage,
      createdAt: timestampFixtureStartedAt + 60_000,
      messageId: "timestamp-user-next",
      text: "Start the next timestamp interval",
    },
  ];
  const actorAttributionMessages: ChatMessage[] = [
    {
      ...productUserMessage,
      messageId: "actor-attribution-user",
      parts: [{ kind: "markdown", text: "Who is answering this turn?" }],
      text: "Who is answering this turn?",
    },
    {
      ...productMessage,
      messageId: "actor-attribution-plain",
      parts: [{ kind: "markdown", text: "Unattributed assistant typography" }],
      text: "Unattributed assistant typography",
    },
    {
      ...productMessage,
      actorRole: "router",
      messageId: "actor-attribution-router",
      parts: [{ kind: "markdown", text: "Router typography" }],
      text: "Router typography",
    },
    {
      ...productMessage,
      actorId: "actor_worker_1",
      actorRole: "worker",
      messageId: "actor-attribution-worker",
      parts: [{ kind: "markdown", text: "Worker typography" }],
      text: "Worker typography",
    },
  ];
  const outgoingUserMessages: ChatMessage[] = outgoingUserEntries.map((entry) => ({
    ...productUserMessage,
    clientRequestId: entry.clientRequestId,
    createdAt: entry.createdAt,
    delivery:
      entry.stage === "pending"
        ? "sending"
        : entry.stage === "failed"
          ? "failed"
          : "sent",
    error:
      entry.stage === "failed"
        ? "Billing is temporarily unavailable. Try again later."
        : undefined,
    messageId: `${entry.ordinal === 1 ? "outgoing-user" : `outgoing-user-${entry.ordinal}`}-${
      entry.stage === "canonical" ? "canonical" : "pending"
    }`,
    source: entry.stage === "canonical" ? "server" : "pending",
    status: entry.stage === "failed" ? "failed" : "completed",
    text: entry.text,
  }));
  const turnHistory = Array.from({ length: 6 }, (_, index) => [
    {
      ...productUserMessage,
      messageId: `turn-history-user-${index}`,
      text: `Historical question ${index + 1}`,
    },
    {
      ...productMessage,
      messageId: `turn-history-assistant-${index}`,
      parts: [
        {
          kind: "markdown" as const,
          text: `Historical answer ${index + 1} with enough detail to occupy a row.`,
        },
      ],
      text: `Historical answer ${index + 1} with enough detail to occupy a row.`,
    },
  ]).flat();
  const outgoingMotionMessages = outgoingHistoryEnabled
    ? [...turnHistory, ...outgoingUserMessages]
    : outgoingUserMessages;
  const currentTurnUser: ChatMessage = {
    ...productUserMessage,
    clientRequestId: "turn-request",
    delivery: "sending",
    messageId: "turn-user",
    source: "pending",
    text: "Newest user turn",
  };
  const showCurrentTurn = conversationStage !== "history";
  const growingTurnText = `Streaming reply is growing in place. ${"Additional cumulative detail expands the reply while the current user turn remains anchored. ".repeat(12)}Draft growth complete.`;
  const turnFinal: ChatMessage = {
    ...productMessage,
    messageId: "turn-final",
    parts: [
      { kind: "markdown", text: `${growingTurnText} Canonical handoff complete.` },
    ],
    text: `${growingTurnText} Canonical handoff complete.`,
  };
  const turnMessages = showCurrentTurn
    ? [
        ...turnHistory,
        currentTurnUser,
        ...(conversationStage === "final" ? [turnFinal] : []),
      ]
    : turnHistory;
  const turnDraft =
    conversationStage === "draft" || conversationStage === "draft-grown"
      ? {
          conversationId: "turn-layout-e2e",
          draftId: "turn-draft",
          responseKey: "turn-response",
          sourceMessageIds: ["turn-user"],
          status: "streaming" as const,
          text:
            conversationStage === "draft-grown"
              ? growingTurnText
              : "Streaming reply is growing in place.",
        }
      : undefined;
  const sideChatMotionUser: ChatMessage = {
    ...productUserMessage,
    messageId: "side-chat-motion-user",
    text: "Stream this answer without jank",
  };
  const sideChatMotionAwaiting = ["waiting", "streaming"].includes(
    sideChatMotion.stage
  );
  const sideChatMotionDraft: ChatAssistantDraft | undefined =
    sideChatMotion.stage === "streaming"
      ? {
          conversationId: "side-chat-motion-e2e",
          draftId: "side-chat-motion-draft",
          responseKey: "side-chat-motion-response",
          sourceMessageIds: [sideChatMotionUser.messageId],
          status: "streaming",
          text: sideChatMotion.text,
        }
      : undefined;
  // The two notices a failed turn can print, in the order the chat prints them:
  // the send that never left, and the model that could not be reached. They are
  // one card, and the parity test holds them to it.
  const noticeParityMessage: ChatMessage = {
    attachments: [],
    blocksKey: undefined,
    clientRequestId: "notice-parity-request",
    createdAt: 0,
    createdBy: undefined,
    delivery: "failed",
    error: "Billing is temporarily unavailable. Try again later.",
    messageId: "notice-parity-message",
    parts: [{ kind: "markdown", text: "Review the fix and give feedback" }],
    refs: [],
    role: "user",
    source: "pending",
    status: "failed",
    text: "Review the fix and give feedback",
  };
  const noticeParityStatus: ChatParticipantStatus = {
    conversationId: "notice-parity-e2e",
    issue: "model_connection_failed",
    participantId: "notice-parity-participant",
    state: "error",
    status: "",
    updatedAt: 1,
  };
  const sideChatMotionParticipantStatus: ChatParticipantStatus | undefined =
    sideChatMotionAwaiting
      ? {
          conversationId: "side-chat-motion-e2e",
          participantId: "side-chat-motion-participant",
          state: "active",
          status:
            sideChatMotion.stage === "streaming"
              ? "is composing a message..."
              : "is thinking...",
          updatedAt: sideChatMotion.stage === "streaming" ? 2 : 1,
        }
      : undefined;
  const sideChatMotionMessages: ChatMessage[] =
    sideChatMotion.stage === "final"
      ? [
          sideChatMotionUser,
          {
            ...productMessage,
            messageId: "side-chat-motion-final",
            parts: [{ kind: "markdown", text: sideChatMotion.text }],
            text: sideChatMotion.text,
          },
        ]
      : [sideChatMotionUser];

  return (
    <CommaUiThemeProvider theme={theme}>
      <FixtureScope
        data-theme={theme}
        style={{
          background: "var(--color-bg-primary)",
          color: "var(--color-text-primary)",
          display: "grid",
          gap: 32,
          minHeight: "100vh",
          padding: 32,
        }}
      >
        <section
          aria-label="Conversation turn positioning"
          className="comma-chat-route"
          data-variant="route"
          data-testid="conversation-turn-fixture"
          style={{
            border: "1px solid var(--color-border-primary)",
            borderRadius: 12,
            display: "flex",
            flexDirection: "column",
            height: 360,
            margin: "0 auto",
            maxWidth: 960,
            overflow: "hidden",
            width: "calc(100vw - 64px)",
          }}
        >
          <ConversationThread
            afterMessages={<ParticipantStatusSlot participantStatus={undefined} />}
            assistantDraft={turnDraft}
            groupId="grp-markdown-e2e"
            messages={turnMessages}
            onDiscard={() => undefined}
            onRetry={() => undefined}
            workspaceId="turn-layout-e2e"
          />
        </section>

        <section
          aria-label="Production conversation Markdown"
          className="comma-chat-route"
          data-variant="side-chat"
          data-testid="conversation-markdown-fixture"
          style={{
            border: "1px solid var(--color-border-primary)",
            borderRadius: 12,
            display: "flex",
            flexDirection: "column",
            height: 480,
            margin: "0 auto",
            maxWidth: 960,
            overflow: "hidden",
            padding: 24,
            width: "calc(100vw - 64px)",
          }}
        >
          <ConversationThread
            afterMessages={<ParticipantStatusSlot participantStatus={undefined} />}
            groupId="grp-markdown-e2e"
            messages={[productUserMessage, productMessage]}
            onDiscard={() => undefined}
            onRetry={() => undefined}
            variant="side-chat"
            workspaceId="markdown-e2e"
          />
        </section>

        <section
          aria-label="Failure notices"
          className="comma-chat-route"
          data-variant="route"
          data-testid="notice-parity-fixture"
          style={{
            border: "1px solid var(--color-border-primary)",
            borderRadius: 12,
            display: "flex",
            flexDirection: "column",
            height: 260,
            margin: "0 auto",
            maxWidth: 960,
            overflow: "hidden",
            padding: 24,
            width: "calc(100vw - 64px)",
          }}
        >
          <ConversationThread
            afterMessages={
              <ParticipantStatusSlot participantStatus={noticeParityStatus} />
            }
            groupId="grp-markdown-e2e"
            messages={[noticeParityMessage]}
            onDiscard={() => undefined}
            onRetry={() => undefined}
            workspaceId="notice-parity-e2e"
          />
        </section>

        <section
          aria-label="Default conversation typography"
          className="comma-chat-route"
          data-variant="route"
          data-testid="conversation-default-fixture"
          style={{
            border: "1px solid var(--color-border-primary)",
            borderRadius: 12,
            margin: "0 auto",
            maxWidth: 960,
            minHeight: 320,
            padding: 24,
            width: "calc(100vw - 64px)",
          }}
        >
          <ConversationThread
            afterMessages={<ParticipantStatusSlot participantStatus={undefined} />}
            groupId="grp-markdown-e2e"
            messages={[productUserMessage, defaultProductMessage]}
            onDiscard={() => undefined}
            onRetry={() => undefined}
            workspaceId="markdown-e2e-default"
          />
        </section>

        <section
          aria-label="Main conversation generated-file download contract"
          className="comma-chat-route"
          data-variant="route"
          data-testid="generated-file-download-main-fixture"
          style={{
            border: "1px solid var(--color-border-primary)",
            borderRadius: 12,
            margin: "0 auto",
            maxWidth: 960,
            minHeight: 240,
            padding: 24,
            width: "calc(100vw - 64px)",
          }}
        >
          <ConversationThread
            api={downloadContractApi}
            conversationId="generated-file-main"
            groupId="grp-markdown-e2e"
            messages={[generatedFileMessage]}
            onDiscard={() => undefined}
            onRetry={() => undefined}
            workspaceId="generated-file-main"
          />
        </section>

        <section
          aria-label="Side Chat generated-file download contract"
          className="comma-chat-route comma-side-chat-host"
          data-variant="side-chat"
          data-testid="generated-file-download-side-chat-fixture"
          style={{
            border: "1px solid var(--color-border-primary)",
            borderRadius: 12,
            margin: "0 auto",
            maxWidth: 960,
            minHeight: 240,
            padding: 24,
            width: "calc(100vw - 64px)",
          }}
        >
          <ConversationThread
            api={downloadContractApi}
            conversationId="generated-file-side-chat"
            groupId="grp-markdown-e2e"
            messages={[generatedFileMessage]}
            onDiscard={() => undefined}
            onRetry={() => undefined}
            variant="side-chat"
            workspaceId="generated-file-side-chat"
          />
        </section>

        <section
          aria-label="Conversation timestamps"
          className="comma-chat-route"
          data-variant="route"
          data-testid="conversation-timestamp-fixture"
          style={{
            border: "1px solid var(--color-border-primary)",
            borderRadius: 12,
            margin: "0 auto",
            maxWidth: 960,
            minHeight: 320,
            padding: 24,
            width: "calc(100vw - 64px)",
          }}
        >
          <ConversationThread
            groupId="grp-markdown-e2e"
            messages={timestampMessages}
            onDiscard={() => undefined}
            onRetry={() => undefined}
            workspaceId="timestamp-e2e"
          />
        </section>

        {/* Router and Worker replies are attributed, but they read in the same
            type as an unattributed assistant reply; the activity line below
            them keeps its own separation from the content it reports on. */}
        <section
          aria-label="Actor attribution"
          className="comma-chat-route"
          data-variant="route"
          data-testid="actor-attribution-fixture"
          style={{
            border: "1px solid var(--color-border-primary)",
            borderRadius: 12,
            margin: "0 auto",
            maxWidth: 960,
            minHeight: 320,
            padding: 24,
            width: "calc(100vw - 64px)",
          }}
        >
          <ConversationThread
            afterMessages={
              <ParticipantStatusSlot
                reserveSpace
                participantStatus={{
                  conversationId: "actor-attribution",
                  participantId: "actor-attribution-participant",
                  state: "active",
                  status: "is thinking...",
                  updatedAt: 1,
                }}
              />
            }
            groupId="grp-markdown-e2e"
            messages={actorAttributionMessages}
            onDiscard={() => undefined}
            onRetry={() => undefined}
            workspaceId="actor-attribution-e2e"
          />
        </section>

        <section
          aria-label="Outgoing user spring motion"
          className="comma-chat-route"
          data-variant="route"
          data-testid="outgoing-user-motion-fixture"
          style={{
            border: "1px solid var(--color-border-primary)",
            borderRadius: 12,
            display: "flex",
            flexDirection: "column",
            height: 720,
            margin: "0 auto",
            maxWidth: 960,
            overflow: "hidden",
            width: "calc(100vw - 64px)",
          }}
        >
          <ConversationThread
            afterMessages={
              <div data-testid="outgoing-agent-feedback">is thinking...</div>
            }
            groupId="grp-markdown-e2e"
            messages={outgoingMotionMessages}
            onDiscard={() => undefined}
            onOutgoingAnimationComplete={(launchId) => {
              setOutgoingLaunches((current) =>
                current.filter((launch) => launch.id !== launchId)
              );
            }}
            onRetry={() => undefined}
            outgoingLaunches={outgoingLaunches}
            workspaceId="outgoing-user-motion-e2e"
          />
          <div
            data-empty={outgoingUserText.length === 0 ? "true" : "false"}
            data-ready="true"
            data-testid="outgoing-user-composer"
            style={{
              display: "flex",
              flex: "none",
              justifyContent: "center",
              padding: "0 72px 20px 24px",
            }}
          >
            <div
              data-testid="outgoing-user-composer-surface"
              style={{
                alignItems: "center",
                background: "var(--color-markdown-bg-message)",
                borderRadius: 16,
                display: "flex",
                height: 56,
                maxWidth: 744,
                padding: "0 18px",
                position: "relative",
                width: "100%",
              }}
            >
              <input
                aria-label="Reusable message composer"
                onChange={() => undefined}
                style={{
                  background: "transparent",
                  border: 0,
                  inset: 0,
                  opacity: 0,
                  position: "absolute",
                }}
                value={outgoingUserText}
              />
              <span data-testid="outgoing-user-composer-copy">{outgoingUserText}</span>
            </div>
          </div>
        </section>

        <section
          aria-label="ConversationView rejected send motion"
          className="comma-side-chat-host"
          data-testid="conversation-view-rejected-send-fixture"
          style={{
            border: "1px solid var(--color-border-primary)",
            borderRadius: 12,
            display: "flex",
            flexDirection: "column",
            height: 420,
            margin: "0 auto",
            maxWidth: 960,
            overflow: "hidden",
            position: "relative",
            width: "calc(100vw - 64px)",
          }}
        >
          <PlainPromiseRejectedSendFixture />
        </section>

        <DelayedActivityOutgoingFixture variant="route" />
        <DelayedActivityOutgoingFixture variant="side-chat" />

        <section
          data-testid="markdown-stream-fixture"
          style={{
            border: "1px solid var(--color-border-primary)",
            borderRadius: 12,
            margin: "0 auto",
            maxWidth: 960,
            padding: 24,
            width: "calc(100vw - 64px)",
          }}
        >
          <MarkdownStream
            animation="blur"
            blurAnimation={blurAnimation}
            content={state.content}
            ensureBlurAnimation
            final={state.final}
            isDark={theme === "Dark mode"}
            maxAnimatedCharacters={220}
            streamId="markdown-stream-e2e"
          />
        </section>

        <section
          data-final={state.final ? "true" : "false"}
          data-testid="markdown-stream-layout-fixture"
          style={{
            border: "1px solid var(--color-border-primary)",
            borderRadius: 12,
            margin: "0 auto",
            maxWidth: 960,
            padding: 24,
            width: "calc(100vw - 64px)",
          }}
        >
          <MarkdownStream
            animation="none"
            content={state.content}
            final={state.final}
            isDark={theme === "Dark mode"}
            streamId="markdown-stream-layout-e2e"
          />
        </section>

        <section
          aria-label="Side Chat streaming motion"
          className="comma-chat-route comma-side-chat-host"
          data-variant="side-chat"
          data-testid="side-chat-motion-fixture"
          style={{
            border: "1px solid var(--color-border-primary)",
            borderRadius: 12,
            bottom: 0,
            display: "flex",
            flexDirection: "column",
            height: 280,
            left: 0,
            margin: "0 auto",
            maxWidth: 960,
            overflow: "hidden",
            padding: 24,
            position: "relative",
            width: "calc(100vw - 64px)",
          }}
        >
          <ConversationThread
            afterMessages={
              sideChatMotionAwaiting ? (
                <ParticipantStatusSlot
                  participantStatus={sideChatMotionParticipantStatus}
                />
              ) : undefined
            }
            assistantDraft={sideChatMotionDraft}
            groupId="grp-markdown-e2e"
            messages={sideChatMotionMessages}
            onDiscard={() => undefined}
            onRetry={() => undefined}
            variant="side-chat"
            workspaceId="side-chat-motion-e2e"
          />
        </section>
      </FixtureScope>
    </CommaUiThemeProvider>
  );
}

const defaultOutgoingUserText =
  "请将这段较长的消息作为同一个气泡内容发送，飞行和回摆期间文字始终保持在气泡内部，并在目标位置与最终消息准确对齐。";

const delayedActivityOutgoingText = Array.from({ length: 400 }, () => "行").join("\n");
const delayedActivityDelayMs = 1_000;

const delayedActivityRouteRoot = createRootRoute({
  component: () => <DelayedActivityConversationView variant="route" />,
});
const delayedActivityRouteRouter = createRouter({
  history: createMemoryHistory({ initialEntries: ["/"] }),
  routeTree: delayedActivityRouteRoot,
});
const delayedActivitySideChatRoot = createRootRoute({
  component: () => <DelayedActivityConversationView variant="side-chat" />,
});
const delayedActivitySideChatRouter = createRouter({
  history: createMemoryHistory({ initialEntries: ["/"] }),
  routeTree: delayedActivitySideChatRoot,
});

function DelayedActivityOutgoingFixture({
  variant,
}: {
  variant: DelayedActivityVariant;
}) {
  return variant === "side-chat" ? (
    <RouterProvider router={delayedActivitySideChatRouter} />
  ) : (
    <RouterProvider router={delayedActivityRouteRouter} />
  );
}

function DelayedActivityConversationView({
  variant,
}: {
  variant: DelayedActivityVariant;
}) {
  const activityTimerRef = useRef<number | undefined>(undefined);
  const turnKey = `delayed-activity-${variant}-request`;
  const [viewState, setViewState] = useState<ConversationChannelState>(() =>
    delayedActivityInitialState(variant)
  );
  const draftSource = useMemo(
    () => fixedDraftSource(viewState.draft),
    [viewState.draft]
  );

  useEffect(() => {
    const reset = () => {
      if (activityTimerRef.current !== undefined) {
        window.clearTimeout(activityTimerRef.current);
        activityTimerRef.current = undefined;
      }
      setViewState(delayedActivityInitialState(variant));
    };
    const start = () => {
      const root = document.querySelector<HTMLElement>(
        `[data-testid='delayed-activity-outgoing-${variant}-fixture']`
      );
      const sendButton = root?.querySelector<HTMLButtonElement>(
        'button[aria-label="Send message"]'
      );
      if (!sendButton || sendButton.disabled) {
        throw new Error(`Delayed ${variant} ConversationView send was not ready.`);
      }
      sendButton.click();
    };
    const controller = { reset, start };
    const key = variant === "side-chat" ? "sideChat" : "route";
    const fixture = window.delayedOutgoingActivityFixture ?? {};
    fixture[key] = controller;
    window.delayedOutgoingActivityFixture = fixture;

    return () => {
      if (activityTimerRef.current !== undefined) {
        window.clearTimeout(activityTimerRef.current);
        activityTimerRef.current = undefined;
      }
      if (fixture[key] === controller) delete fixture[key];
      if (!fixture.route && !fixture.sideChat) {
        delete window.delayedOutgoingActivityFixture;
      }
    };
  }, [turnKey, variant]);

  const actions = useMemo<ConversationViewActions>(
    () => ({
      attachFiles: () => undefined,
      discard: () => undefined,
      refresh: () => undefined,
      removeAttachment: () => undefined,
      retry: () => undefined,
      retryAttachment: () => undefined,
      send: (text) => {
        const createdAt = Date.now();
        const pending: PendingSend = {
          clientRequestId: turnKey,
          createdAt,
          error: undefined,
          skills: undefined,
          status: "sending",
          text,
        };
        setViewState((current) => ({
          ...current,
          awaitingReply: false,
          awaitingSince: undefined,
          awaitingTurnKey: undefined,
          draft: "",
          messages: [...current.messages, delayedActivityMessage(variant, pending)],
          pending: [pending],
        }));
        if (activityTimerRef.current !== undefined) {
          window.clearTimeout(activityTimerRef.current);
        }
        activityTimerRef.current = window.setTimeout(() => {
          activityTimerRef.current = undefined;
          setViewState((current) => ({
            ...current,
            participantStatus: delayedParticipantStatus(variant),
          }));
        }, delayedActivityDelayMs);
      },
      setDraft: (draft) => {
        setViewState((current) => ({ ...current, draft }));
      },
    }),
    [turnKey, variant]
  );

  return (
    <section
      aria-label={`Delayed ${variant} outgoing activity`}
      className={variant === "side-chat" ? "comma-side-chat-host" : undefined}
      data-draft-id={viewState.assistantDraft?.draftId ?? ""}
      data-participant-id={viewState.participantStatus?.participantId ?? ""}
      data-variant={variant}
      data-testid={`delayed-activity-outgoing-${variant}-fixture`}
      style={{
        border: "1px solid var(--color-border-primary)",
        borderRadius: 12,
        display: "flex",
        flexDirection: "column",
        height: 720,
        margin: "0 auto",
        maxWidth: 960,
        overflow: "hidden",
        position: "relative",
        width: "calc(100vw - 64px)",
      }}
    >
      <ConversationView
        actions={actions}
        draftSource={draftSource}
        groupId="grp-markdown-e2e"
        state={viewState}
        variant={variant === "side-chat" ? "side-chat" : "route"}
        workspaceId={`delayed-activity-${variant}-e2e`}
      />
    </section>
  );
}

function delayedActivityInitialState(
  variant: DelayedActivityVariant
): ConversationChannelState {
  return {
    ...idleConversationChannelState,
    connection: "live",
    conversation: {
      group_id: "grp-markdown-e2e",
      id: `delayed-activity-${variant}`,
      kind: "agent_task",
      status: "completed",
      title: "Delayed Activity spring",
    },
    draft: delayedActivityOutgoingText,
    messages: delayedActivityHistory(variant),
    status: "ready",
  };
}

function delayedActivityHistory(variant: DelayedActivityVariant): ChatMessage[] {
  const params = new URLSearchParams(window.location.search);
  const count = params.has("compactHistory")
    ? 2
    : params.has("extendedHistory")
      ? 40
      : 10;
  return Array.from({ length: count }, (_, index) => {
    const userId = `delayed-activity-${variant}-history-user-${index}`;
    return [
      {
        attachments: [],
        blocksKey: undefined,
        clientRequestId: undefined,
        createdAt: timestampFixtureStartedAt + index * 1_000,
        createdBy: undefined,
        delivery: "sent" as const,
        error: undefined,
        messageId: userId,
        refs: [],
        role: "user" as const,
        source: "server" as const,
        status: "completed" as const,
        text: `History request ${index + 1}`,
      },
      {
        attachments: [],
        blocksKey: undefined,
        clientRequestId: undefined,
        createdAt: timestampFixtureStartedAt + index * 1_000 + 1,
        createdBy: undefined,
        delivery: "sent" as const,
        error: undefined,
        messageId: `delayed-activity-${variant}-history-assistant-${index}`,
        refs: [],
        role: "assistant" as const,
        source: "server" as const,
        status: "completed" as const,
        text: `History response ${index + 1} keeps the owning viewport genuinely overflowed before the next send.`,
      },
    ];
  }).flat();
}

function delayedActivityMessage(
  variant: DelayedActivityVariant,
  pending: PendingSend
): ChatMessage {
  return {
    attachments: [],
    blocksKey: undefined,
    clientRequestId: pending.clientRequestId,
    createdAt: pending.createdAt,
    createdBy: undefined,
    delivery: "sending",
    error: undefined,
    messageId: `delayed-activity-${variant}-pending`,
    refs: [],
    role: "user",
    source: "pending",
    status: "completed",
    text: pending.text,
  };
}

function delayedParticipantStatus(
  variant: DelayedActivityVariant
): ChatParticipantStatus {
  return {
    conversationId: `delayed-activity-${variant}`,
    participantId: `delayed-activity-${variant}-participant`,
    state: "active",
    status: "is thinking...",
    updatedAt: Date.now(),
  };
}

const rejectedSendClientRequestId = "conversation-view-plain-rejection";
const rejectedSendMessageId = `pending:${rejectedSendClientRequestId}`;
const rejectedSendText =
  "Keep this user bubble on its natural spring path when completion fails.";
const rejectedQuoteAdmissionSourceText =
  "Preserve this quoted passage when admission fails.";

function PlainPromiseRejectedSendFixture() {
  const deferredFailureRef = useRef<(() => void) | undefined>(undefined);
  const sendModeRef = useRef<"admission" | "completion">("completion");
  const [viewState, setViewState] = useState<ConversationChannelState>({
    ...idleConversationChannelState,
    connection: "live",
    conversation: {
      group_id: "grp-markdown-e2e",
      id: "conversation-view-rejected-send",
      kind: "user_chat",
      status: "completed",
      title: "Rejected send spring",
    },
    draft: rejectedSendText,
    status: "ready",
  });
  const draftSource = useMemo(
    () => fixedDraftSource(viewState.draft),
    [viewState.draft]
  );

  useEffect(() => {
    const controller = {
      prepareQuoteAdmission: () => {
        deferredFailureRef.current = undefined;
        sendModeRef.current = "admission";
        setViewState(rejectedQuoteAdmissionState());
      },
      reject: () => {
        const rejectPendingSend = deferredFailureRef.current;
        if (!rejectPendingSend) return false;
        deferredFailureRef.current = undefined;
        rejectPendingSend();
        return true;
      },
    };
    window.conversationViewRejectedSendFixture = controller;
    return () => {
      deferredFailureRef.current = undefined;
      if (window.conversationViewRejectedSendFixture === controller) {
        delete window.conversationViewRejectedSendFixture;
      }
    };
  }, []);

  const actions = useMemo<ConversationViewActions>(
    () => ({
      attachFiles: () => undefined,
      discard: () => undefined,
      refresh: () => undefined,
      removeAttachment: () => undefined,
      retry: () => undefined,
      retryAttachment: () => undefined,
      send: (text) => {
        if (sendModeRef.current === "admission") {
          let rejectAccepted!: (error: Error) => void;
          const accepted = new Promise<void>((_resolve, reject) => {
            rejectAccepted = reject;
          });
          const completion = accepted.then(() => undefined);
          void completion.catch(() => undefined);
          deferredFailureRef.current = () => {
            rejectAccepted(new Error("attachment_admission_failed"));
          };
          return Object.assign(completion, { accepted });
        }

        const pending: PendingSend = {
          clientRequestId: rejectedSendClientRequestId,
          createdAt: Date.now(),
          error: undefined,
          skills: undefined,
          status: "sending",
          text,
        };
        setViewState((current) => ({
          ...current,
          awaitingReply: true,
          awaitingSince: pending.createdAt,
          awaitingTurnKey: pending.clientRequestId,
          draft: "",
          messages: [rejectedSendMessage(pending)],
          pending: [pending],
        }));

        let rejectCompletion!: (error: Error) => void;
        const completion = new Promise<never>((_resolve, reject) => {
          rejectCompletion = reject;
        });
        // The real web action owns logging for its completion promise. Attach a
        // no-op observer here so the fixture reproduces a handled transport
        // failure without turning it into an unhandled browser rejection.
        void completion.catch(() => undefined);
        deferredFailureRef.current = () => {
          const failed: PendingSend = {
            ...pending,
            error: "Billing is temporarily unavailable. Try again later.",
            status: "failed",
          };
          setViewState((current) => ({
            ...current,
            awaitingReply: false,
            awaitingSince: undefined,
            messages: [rejectedSendMessage(failed)],
            pending: [failed],
          }));
          rejectCompletion(new Error("billing_unavailable"));
        };
        return completion;
      },
      setDraft: (draft) => {
        setViewState((current) => ({ ...current, draft }));
      },
    }),
    []
  );

  return (
    <ConversationView
      actions={actions}
      draftSource={draftSource}
      state={viewState}
      variant="side-chat"
      workspaceId="markdown-e2e"
    />
  );
}

function rejectedQuoteAdmissionState(): ConversationChannelState {
  return {
    ...idleConversationChannelState,
    connection: "live",
    conversation: {
      group_id: "grp-markdown-e2e",
      id: "conversation-view-rejected-quote-admission",
      kind: "user_chat",
      status: "completed",
      title: "Rejected quote admission",
    },
    draft: "Retry this message with its quote.",
    messages: [
      {
        attachments: [],
        blocksKey: undefined,
        clientRequestId: undefined,
        createdAt: timestampFixtureStartedAt,
        createdBy: undefined,
        delivery: "sent",
        error: undefined,
        messageId: "rejected-quote-admission-source",
        refs: [],
        role: "assistant",
        source: "server",
        status: "completed",
        text: rejectedQuoteAdmissionSourceText,
      },
    ],
    status: "ready",
  };
}

function rejectedSendMessage(pending: PendingSend): ChatMessage {
  const failed = pending.status === "failed";
  return {
    attachments: [],
    blocksKey: undefined,
    clientRequestId: pending.clientRequestId,
    createdAt: pending.createdAt,
    createdBy: undefined,
    delivery: failed ? "failed" : "sending",
    error: pending.error,
    messageId: rejectedSendMessageId,
    refs: [],
    role: "user",
    source: "pending",
    status: failed ? "failed" : "completed",
    text: pending.text,
  };
}

createRoot(document.getElementById("root") as HTMLElement).render(
  <StrictMode>
    <MarkdownStreamFixture />
  </StrictMode>
);
