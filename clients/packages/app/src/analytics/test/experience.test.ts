import { afterEach, beforeEach, expect, it, vi } from "vitest";
import {
  idleConversationChannelState,
  type ConversationChannelState,
} from "../../components/chat/model/conversationChannel";
import { createConversationAnalytics } from "../experience";

const analytics = vi.hoisted(() => ({ capture: vi.fn(), identity: "user-a" }));
vi.mock("../client", () => ({
  captureCommaExperience: analytics.capture,
  commaAnalyticsIdentity: () => analytics.identity,
}));
let now = 0;
beforeEach(() => {
  now = 0;
  analytics.identity = "user-a";
  vi.clearAllMocks();
  vi.spyOn(performance, "now").mockImplementation(() => now);
});
afterEach(() => vi.restoreAllMocks());
function state(
  overrides: Partial<ConversationChannelState> = {}
): ConversationChannelState {
  return {
    ...idleConversationChannelState,
    status: "ready",
    connection: "live",
    ...overrides,
  };
}
function draft(sourceMessageIds: string[]) {
  return {
    conversationId: "cnv-private",
    draftId: "draft-private",
    responseKey: "response-private",
    sourceMessageIds,
    status: "streaming" as const,
    text: "private answer",
  };
}
const userMessage: ConversationChannelState["messages"][number] = {
  messageId: "msg-private",
  clientRequestId: "turn-private",
  role: "user",
  text: "private question",
  attachments: [],
  refs: [],
  createdAt: 1,
  delivery: "sent",
  source: "server",
};

it("measures readiness across loading without counting hydrated waits, drafts or participant errors", () => {
  const observe = createConversationAnalytics("route");
  observe(state({ status: "loading" }), true);
  now = 200;
  const hydrated = state({
    awaitingReply: true,
    awaitingTurnKey: "turn-private",
    awaitingTimedOut: true,
    assistantDraft: draft(["msg-private"]),
    messages: [userMessage],
    participantStatus: {
      conversationId: "cnv-private",
      participantId: "p",
      state: "error",
      status: "private",
      updatedAt: 1,
    },
  });
  observe(hydrated, true);
  observe(hydrated, true);
  expect(analytics.capture.mock.calls).toEqual([
    ["comma_conversation_ready", { surface: "route", duration_ms: 200 }],
  ]);
});

it("counts the first visible draft only for the exact new turn and deduplicates streaming updates", () => {
  const observe = createConversationAnalytics("home");
  observe(state(), true);
  now = 100;
  const waiting = state({
    awaitingReply: true,
    awaitingTurnKey: "turn-private",
    messages: [userMessage],
  });
  observe(waiting, true);
  now = 200;
  observe({ ...waiting, assistantDraft: draft(["old-private"]) }, true);
  expect(
    analytics.capture.mock.calls.some(
      ([event]) => event === "comma_reply_first_visible"
    )
  ).toBe(false);
  now = 350;
  const answer = {
    ...waiting,
    awaitingReply: false,
    awaitingTurnKey: undefined,
    assistantDraft: draft(["msg-private"]),
  };
  observe(answer, true);
  observe(answer, true);
  expect(
    analytics.capture.mock.calls.filter(
      ([event]) => event === "comma_reply_first_visible"
    )
  ).toEqual([["comma_reply_first_visible", { surface: "home", duration_ms: 250 }]]);
  expect(JSON.stringify(analytics.capture.mock.calls)).not.toContain("private");
});

it("reports an existing wait timeout once, and connection recovery across a channel error", () => {
  const observe = createConversationAnalytics("rail");
  observe(state(), true);
  const waiting = state({ awaitingReply: true, awaitingTurnKey: "turn-private" });
  observe(waiting, true);
  now = 60_000;
  observe(
    { ...waiting, awaitingTimedOut: true, connection: "reconnecting", status: "error" },
    true
  );
  now = 61_000;
  observe({ ...waiting, awaitingTimedOut: true, connection: "live" }, true);
  expect(
    analytics.capture.mock.calls.filter(
      ([event]) => event === "comma_reply_wait_timed_out"
    )
  ).toEqual([["comma_reply_wait_timed_out", { surface: "rail", duration_ms: 60_000 }]]);
  expect(analytics.capture).toHaveBeenCalledWith("comma_connection_state_changed", {
    surface: "rail",
    state: "live",
    duration_ms: 1000,
  });
});

it.each(["hidden", "account"])(
  "drops pending response attribution across %s boundaries",
  (boundary) => {
    const observe = createConversationAnalytics("side-chat");
    observe(state(), true);
    const waiting = state({
      awaitingReply: true,
      awaitingTurnKey: "turn-private",
      messages: [userMessage],
    });
    observe(waiting, true);
    if (boundary === "hidden") observe(waiting, false);
    else analytics.identity = "user-b";
    observe(
      { ...waiting, assistantDraft: draft(["msg-private"]), awaitingTimedOut: true },
      true
    );
    expect(
      analytics.capture.mock.calls.some(([event]) => event.startsWith("comma_reply_"))
    ).toBe(false);
  }
);

it("captures a newly observed participant failure without transmitting its status text", () => {
  const observe = createConversationAnalytics("route");
  observe(state(), true);
  const failed = state({
    participantStatus: {
      conversationId: "private",
      participantId: "private",
      state: "error",
      issue: "runtime_failed",
      status: "private failure detail",
      updatedAt: 2,
    },
  });
  observe(failed, true);
  observe(failed, true);
  expect(
    analytics.capture.mock.calls.filter(
      ([event]) => event === "comma_participant_failed"
    )
  ).toEqual([
    ["comma_participant_failed", { surface: "route", error_kind: "runtime_failed" }],
  ]);
});
