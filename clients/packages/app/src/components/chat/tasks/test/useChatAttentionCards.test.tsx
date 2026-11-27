import type { ChatQuestionPart } from "@comma/chat-contract";
import type { AgentRequest } from "@comma/core-client";
import type { CommaTaskLabelCatalog } from "@comma/core/api-schemas";
import type { ChatMessage } from "@comma/core/chat";
import { initializeCommaI18n } from "@comma/i18n";
import { act, renderHook } from "@comma/test-utils/render";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { useChatAttentionCards } from "../useChatAttentionCards";

const NOW = 1_760_000_000_000;

function chatMessage(
  messageId: string,
  role: string,
  text: string,
  overrides: Partial<ChatMessage> = {}
): ChatMessage {
  return {
    attachments: [],
    blocksKey: undefined,
    clientRequestId: undefined,
    createdAt: NOW,
    createdBy: undefined,
    delivery: "sent",
    error: undefined,
    messageId,
    parts: [{ kind: "markdown", text }],
    refs: [],
    role,
    source: "server",
    status: "completed",
    text,
    ...overrides,
  };
}

function questionPart(
  messageId: string,
  prompt: string,
  status: ChatQuestionPart["state"]["status"] = "open"
): ChatQuestionPart {
  return {
    allowOther: true,
    choices: [{ id: "a", label: "Option A" }],
    kind: "question",
    messageId,
    multiSelect: false,
    prompt,
    state: status === "failed" ? { status: "failed", error: "Retry" } : { status },
  };
}

describe("useChatAttentionCards", () => {
  beforeEach(() => {
    vi.setSystemTime(NOW);
    initializeCommaI18n(["en"]);
  });

  it("collects open and failed question cards and excludes answered ones", () => {
    const messages = [
      chatMessage("u1", "user", "Deploy staging"),
      chatMessage("a1", "assistant", "Choose mode", {
        parts: [questionPart("a1", "Rolling or exclusive?", "open")],
      }),
      chatMessage("a2", "assistant", "Done question", {
        parts: [questionPart("a2", "Already answered", "replied")],
      }),
      chatMessage("a3", "assistant", "Failed question", {
        parts: [questionPart("a3", "Retry this choice?", "failed")],
      }),
    ];

    const { result } = renderHook(() =>
      useChatAttentionCards({
        conversationId: "cnv_1",
        labelCatalog: undefined,
        messages,
        requests: [],
      })
    );

    expect(result.current.map((card) => ({ id: card.id, title: card.title }))).toEqual([
      { id: "question:a3", title: "Retry this choice?" },
      { id: "question:a1", title: "Rolling or exclusive?" },
    ]);
    expect(result.current[0]).toMatchObject({
      actionLabel: "Answer",
      kind: "question",
      kindLabel: "Question",
      messageId: "a3",
      turnKey: "u1",
    });
  });

  it("prioritizes expiring requests ahead of questions and drops them once expired", () => {
    const messages = [
      chatMessage("u1", "user", "Run billing tests"),
      chatMessage("a1", "assistant", "Need choice", {
        parts: [questionPart("a1", "Which mode?", "open")],
      }),
    ];
    const requests: AgentRequest[] = [
      {
        createdAt: NOW,
        expiresAt: NOW + 15_000,
        id: "req_secret",
        oauth: {
          alias: "stripe",
          label: "Stripe test key",
          provider: "secret",
          reason: "Run billing regression",
          scopes: [],
        },
        outcome: null,
        sourceMessageId: "u1",
        status: "pending",
        type: "oauth_authorization",
      },
      {
        createdAt: NOW,
        expiresAt: null,
        id: "req_done",
        outcome: "shared",
        sourceMessageId: "u1",
        status: "completed",
        location: { reason: "Weather" },
        type: "location",
      },
    ];

    const { result } = renderHook(() =>
      useChatAttentionCards({
        conversationId: "cnv_1",
        labelCatalog: undefined,
        messages,
        requests,
      })
    );

    expect(result.current.map((card) => card.id)).toEqual([
      "request:req_secret",
      "question:a1",
    ]);
    expect(result.current[0]).toMatchObject({
      actionLabel: "Fill in",
      kind: "secret",
      kindLabel: "Secret",
      messageId: "a1",
      title: "Fill in Stripe test key",
    });

    act(() => {
      vi.advanceTimersByTime(15_100);
    });
    expect(result.current.map((card) => card.id)).toEqual(["question:a1"]);
  });

  it("includes pending label proposals grouped by anchor and skips settled ones", () => {
    const messages = [
      chatMessage("u1", "user", "Organize tasks", { createdAt: NOW - 2_000 }),
      chatMessage("a1", "assistant", "Proposed labels", { createdAt: NOW - 1_000 }),
    ];
    const labelCatalog: CommaTaskLabelCatalog = {
      approval_policy: "ask",
      colors: [],
      labels: [],
      proposals: [
        {
          created_at: NOW - 900,
          id: "prop_1",
          op: "create",
          payload: { labels: [{ color: "blue", description: "", name: "billing" }] },
          source_conversation_id: "cnv_1",
          status: "pending",
        },
        {
          created_at: NOW - 850,
          id: "prop_2",
          op: "create",
          payload: { labels: [{ color: "red", description: "", name: "p0" }] },
          source_conversation_id: "cnv_1",
          status: "pending",
        },
        {
          created_at: NOW - 800,
          id: "prop_done",
          op: "create",
          payload: { labels: [{ color: "green", description: "", name: "done" }] },
          source_conversation_id: "cnv_1",
          status: "approved",
        },
      ],
    };

    const { result } = renderHook(() =>
      useChatAttentionCards({
        conversationId: "cnv_1",
        labelCatalog,
        messages,
        requests: [],
      })
    );

    expect(result.current).toHaveLength(1);
    expect(result.current[0]).toMatchObject({
      actionLabel: "Review",
      id: "labels:a1",
      kind: "labels",
      kindLabel: "Labels",
      messageId: "a1",
      title: "2 label changes: billing, p0",
    });
  });

  it("keeps array and item references stable across unrelated new messages", () => {
    const initialMessages = [
      chatMessage("u1", "user", "Start"),
      chatMessage("a1", "assistant", "Pick one", {
        parts: [questionPart("a1", "Confirm?", "open")],
      }),
    ];

    const { rerender, result } = renderHook(
      ({ messages }) =>
        useChatAttentionCards({
          conversationId: "cnv_1",
          labelCatalog: undefined,
          messages,
          requests: [],
        }),
      { initialProps: { messages: initialMessages } }
    );

    const first = result.current;
    rerender({
      messages: [
        ...initialMessages,
        chatMessage("a2", "assistant", "Unrelated follow-up"),
      ],
    });
    expect(result.current).toBe(first);
  });
});
