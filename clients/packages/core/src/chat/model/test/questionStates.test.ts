import type { ChatMessage, ChatQuestionPart } from "@comma/chat-contract";
import { describe, expect, it } from "vitest";
import { questionPartValue } from "../inlineElementContract";
import { createQuestionStates } from "../questionStates";

function questionMessage(
  id: string,
  opts: { independent?: boolean; choices?: number } = {}
): ChatMessage {
  const count = opts.choices ?? 2;
  const choices = Array.from({ length: count }, (_, idx) => ({
    id: `c${idx + 1}`,
    label: `Choice ${idx + 1}`,
  }));
  const part: ChatQuestionPart = {
    kind: "question",
    messageId: id,
    prompt: `Prompt ${id}`,
    choices,
    multiSelect: false,
    allowOther: true,
    ...(opts.independent
      ? { independent: true, skipBehavior: "dismiss" as const }
      : {}),
    state: { status: "open" },
  };
  return {
    messageId: id,
    role: "assistant",
    text: "",
    createdAt: 1,
    attachments: [],
    delivery: "sent",
    refs: [],
    source: "server",
    parts: [part],
  };
}

function assistantText(
  id: string,
  text: string,
  opts: { clientRequestId?: string } = {}
): ChatMessage {
  return {
    messageId: id,
    role: "assistant",
    text,
    createdAt: 2,
    attachments: [],
    delivery: "sent",
    refs: [],
    source: "server",
    ...(opts.clientRequestId ? { clientRequestId: opts.clientRequestId } : {}),
  };
}

function userText(
  id: string,
  text: string,
  opts: { replyToMessageId?: string } = {}
): ChatMessage {
  return {
    messageId: id,
    role: "user",
    text,
    createdAt: 2,
    attachments: [],
    delivery: "sent",
    refs: [],
    source: "server",
    ...(opts.replyToMessageId ? { replyToMessageId: opts.replyToMessageId } : {}),
  };
}

function userAnswer(
  id: string,
  questionMessageId: string,
  opts: {
    choiceIds?: string[];
    skipped?: boolean;
    delivery?: "sending" | "failed";
    error?: string;
    text?: string;
    clientRequestId?: string;
  } = {}
): ChatMessage {
  const text = opts.text ?? (opts.skipped ? "Dismissed" : "Choice 1");
  return {
    messageId: id,
    role: "user",
    text,
    createdAt: 3,
    attachments: [],
    delivery: opts.delivery ?? "sent",
    refs: [],
    source: opts.delivery ? "pending" : "server",
    replyToMessageId: questionMessageId,
    ...(opts.clientRequestId ? { clientRequestId: opts.clientRequestId } : {}),
    ...(opts.error ? { error: opts.error } : {}),
    parts: [
      ...(text ? [{ kind: "markdown" as const, text }] : []),
      {
        kind: "question-answer",
        questionMessageId,
        choiceIds: opts.choiceIds ?? (opts.skipped ? [] : ["c1"]),
        skipped: opts.skipped ?? false,
      },
    ],
  };
}

function stateOf(messages: ChatMessage[], id: string) {
  const msg = messages.find((m) => m.messageId === id);
  const part = msg?.parts?.find((p): p is ChatQuestionPart => p.kind === "question");
  return part?.state;
}

describe("questionStates", () => {
  it("keeps concurrent independent cards open across newer cards and plain user messages", () => {
    const qs = createQuestionStates();
    const transcript = qs.inTranscript([
      questionMessage("q_pinshot", { independent: true }),
      questionMessage("q_photon", { independent: true }),
      userAnswer("a_photon", "q_photon", { choiceIds: ["c1"] }),
      userText("u_chat", "What is on my calendar tomorrow?"),
    ]);

    expect(stateOf(transcript, "q_pinshot")).toEqual({ status: "open" });
    expect(stateOf(transcript, "q_photon")).toEqual({
      status: "answered",
      choiceIds: ["c1"],
    });
  });

  it("keeps independent cards transparent to ordinary conversation questions", () => {
    const qs = createQuestionStates();

    // Before user replies: background independent card must not mark earlier Router question replaced.
    const beforeReply = qs.inTranscript([
      questionMessage("q_router"),
      questionMessage("q_station", { independent: true }),
    ]);
    expect(stateOf(beforeReply, "q_router")).toEqual({ status: "open" });
    expect(stateOf(beforeReply, "q_station")).toEqual({ status: "open" });

    // After user sends plain chat: Router question becomes replied, independent card stays open.
    const afterReply = qs.inTranscript([
      questionMessage("q_router"),
      questionMessage("q_station", { independent: true }),
      userText("u_reply", "Sounds good, go ahead"),
    ]);
    expect(stateOf(afterReply, "q_router")).toEqual({ status: "replied" });
    expect(stateOf(afterReply, "q_station")).toEqual({ status: "open" });
  });

  it("preserves sending, failed, and skipped states for independent cards", () => {
    const qs = createQuestionStates();
    const transcript = qs.inTranscript([
      questionMessage("q_sending", { independent: true }),
      questionMessage("q_failed", { independent: true }),
      questionMessage("q_skipped", { independent: true }),
      userAnswer("a_sending", "q_sending", { delivery: "sending", choiceIds: ["c1"] }),
      userAnswer("a_failed", "q_failed", {
        delivery: "failed",
        choiceIds: ["c2"],
        error: "offline",
      }),
      userAnswer("a_skipped", "q_skipped", { skipped: true }),
    ]);

    expect(stateOf(transcript, "q_sending")).toEqual({
      status: "sending",
      choiceIds: ["c1"],
    });
    expect(stateOf(transcript, "q_failed")).toEqual({
      status: "failed",
      choiceIds: ["c2"],
      error: "offline",
    });
    expect(stateOf(transcript, "q_skipped")).toEqual({ status: "skipped" });
    // Independent card answers fold in-place without leaving standalone user bubbles,
    // while failed sends remain visible alongside the failed card state.
    expect(transcript.map((m) => m.messageId)).toEqual([
      "q_sending",
      "q_failed",
      "q_skipped",
      "a_failed",
    ]);
  });

  it("omits still.fail card-sync folds from visible rows and stops unrelated assistant alerts from closing older cards", () => {
    const qs = createQuestionStates();
    const raw = [
      questionMessage("q_monoid", { independent: true }),
      questionMessage("q_jiachen"),
      userAnswer("a_monoid_sync", "q_monoid", {
        choiceIds: ["c1"],
        text: "提 PR 到 still.fail",
        clientRequestId: "sf-card-sync:q_monoid",
      }),
      assistantText("m_google_alert", "Google security alert"),
      userText("u_google_reply", "不用，这是我自己"),
    ];

    const transcript = qs.inTranscript(raw);
    const server = qs.inServerMessages(raw, transcript);

    expect(stateOf(transcript, "q_monoid")).toEqual({
      status: "answered",
      choiceIds: ["c1"],
    });
    expect(stateOf(transcript, "q_jiachen")).toEqual({ status: "open" });
    expect(transcript.map((m) => m.messageId)).toEqual([
      "q_monoid",
      "q_jiachen",
      "m_google_alert",
      "u_google_reply",
    ]);
    expect(server.map((m) => m.messageId)).toEqual([
      "q_monoid",
      "q_jiachen",
      "m_google_alert",
      "u_google_reply",
    ]);
    expect(stateOf(server, "q_monoid")).toEqual({
      status: "answered",
      choiceIds: ["c1"],
    });
    expect(stateOf(server, "q_jiachen")).toEqual({ status: "open" });
  });

  it("keeps background station notices transparent and still closes an earlier card on direct reply", () => {
    const qs = createQuestionStates();

    const afterStationNotice = qs.inTranscript([
      questionMessage("q_router"),
      assistantText("m_station_done", "Done notice", {
        clientRequestId: "station-task:abc",
      }),
      userText("u_reply", "Go ahead"),
    ]);
    expect(stateOf(afterStationNotice, "q_router")).toEqual({ status: "replied" });

    const withDirectReply = qs.inTranscript([
      questionMessage("q_jiachen"),
      assistantText("m_google_alert", "Google security alert"),
      userText("u_direct", "Go ahead with App Store rename", {
        replyToMessageId: "q_jiachen",
      }),
    ]);
    expect(stateOf(withDirectReply, "q_jiachen")).toEqual({ status: "replied" });
  });

  it("omits off-page sf-card-sync and textless question-answer folds even without a question card on the page", () => {
    const qs = createQuestionStates();
    const raw = [
      assistantText("m_google_alert", "Google security alert"),
      userAnswer("a_legacy_sync", "q_offpage_1", {
        choiceIds: ["c1"],
        text: "提 PR 到 still.fail",
        clientRequestId: "sf-card-sync:q_offpage_1",
      }),
      userAnswer("a_textless_sync", "q_offpage_2", {
        choiceIds: ["c1"],
        text: "",
      }),
      userText("u_chat", "Hello"),
    ];

    expect(qs.inTranscript(raw).map((m) => m.messageId)).toEqual([
      "m_google_alert",
      "u_chat",
    ]);
  });

  it("decodes single-choice and independent question blocks", () => {
    const part = questionPartValue(
      {
        type: "question",
        prompt: "Proceed with release?",
        choices: [{ id: "c1", label: "Proceed", recommended: true }],
        skip_behavior: "dismiss",
        independent: true,
      },
      "msg_1"
    );
    expect(part).toMatchObject({
      kind: "question",
      messageId: "msg_1",
      choices: [{ id: "c1", label: "Proceed", recommended: true }],
      skipBehavior: "dismiss",
      independent: true,
      state: { status: "open" },
    });
  });
});
