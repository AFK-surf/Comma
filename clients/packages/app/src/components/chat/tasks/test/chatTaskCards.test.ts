import type { ChatMessage } from "@comma/core/chat";
import { expect, it, vi } from "vitest";
import { ChatTaskCards, taskAnnouncements } from "../chatTaskCards";

function message(
  messageId: string,
  taskIds: readonly string[],
  role: ChatMessage["role"] = "assistant"
): ChatMessage {
  return {
    attachments: [],
    blocksKey: undefined,
    clientRequestId: undefined,
    createdAt: 1,
    createdBy: undefined,
    delivery: "sent",
    error: undefined,
    messageId,
    parts: taskIds.map((conversationId) => ({
      kind: "inline-task",
      task: { conversationId, title: conversationId, unavailable: false },
    })),
    refs: [],
    role,
    source: "server",
    status: "completed",
    text: "",
  };
}

function withReference(base: ChatMessage, conversationId: string): ChatMessage {
  return {
    ...base,
    refs: [{ conversationId, kind: "agent_task", title: conversationId }],
  };
}

it("gives a card only to an agent message that created one Task", () => {
  const announced = taskAnnouncements([
    message("ask", ["mentioned"], "user"),
    message("created", ["a"]),
    message("listed", ["b", "c"]),
    message("again", ["a"]),
    message("from-list", ["b"]),
    message("new", ["mentioned"]),
  ]);

  // Several Tasks in one message, created together or listed, keep their
  // inline chips only; a later mention of a Task creates nothing.
  expect([...announced]).toEqual([
    ["created", "a"],
    ["new", "mentioned"],
  ]);
});

it("counts a Task reference as naming its Task", () => {
  const announced = taskAnnouncements([
    // First named as a reference: a later inline mention creates nothing.
    withReference(message("ref", []), "a"),
    message("later", ["a"]),
    // One inline Task beside a reference to another names two Tasks.
    withReference(message("pair", ["b"]), "c"),
    // The same Task inline and as a reference is still one Task.
    withReference(message("same", ["d"]), "d"),
  ]);

  expect([...announced]).toEqual([["same", "d"]]);
});

it("gives a card to a new Task named beside earlier ones", () => {
  const base = message("beside-unavailable", ["e"]);
  const unavailable: ChatMessage = {
    ...base,
    parts: [
      ...(base.parts ?? []),
      { kind: "inline-task", task: { unavailable: true } },
    ],
  };
  const announced = taskAnnouncements([
    message("created", ["a"]),
    // A new Task beside an earlier one, inline or as a reference.
    message("follow-up", ["b", "a"]),
    withReference(message("referenced", ["c"]), "a"),
    // Two new Tasks beside an earlier one still keep their chips only.
    message("pair", ["a", "d", "f"]),
    // An unavailable chip names no new Task.
    unavailable,
  ]);

  expect([...announced]).toEqual([
    ["created", "a"],
    ["follow-up", "b"],
    ["referenced", "c"],
    ["beside-unavailable", "e"],
  ]);
});

it("gives a person's Quick Chat message the card of the Task it started", () => {
  const spoken = { ...message("spoken", ["a"], "user"), messageType: "quick_chat" };
  const announced = taskAnnouncements([
    spoken,
    message("ask", ["b"], "user"),
    message("reply", ["a", "b"]),
  ]);

  expect([...announced]).toEqual([
    ["spoken", "a"],
    ["reply", "b"],
  ]);
});

it("follows the Workers of the two most recently created running Tasks", () => {
  const cards = new ChatTaskCards();
  cards.update(
    [message("one", ["a"]), message("two", ["b"]), message("three", ["c"])],
    true
  );
  const [, , releaseC] = ["a", "b", "c"].map((id) => cards.holdRunning(id));

  expect(["a", "b", "c"].map((id) => cards.follows(id))).toEqual([false, true, true]);

  releaseC!();
  expect(["a", "b", "c"].map((id) => cards.follows(id))).toEqual([true, true, false]);
});

it("keeps following a Task while another card of it still shows it running", () => {
  const cards = new ChatTaskCards();
  cards.update([message("one", ["a"])], true);
  const releaseTranscriptCard = cards.holdRunning("a");
  // A reply thread on the message draws a second card of the Task, then closes.
  cards.holdRunning("a")();

  expect(cards.follows("a")).toBe(true);
  releaseTranscriptCard();
  expect(cards.follows("a")).toBe(false);
});

it("follows no Worker while the surface is not shown", () => {
  const cards = new ChatTaskCards();
  cards.update([message("one", ["a"])], false);
  cards.holdRunning("a");

  expect(cards.follows("a")).toBe(false);
});

it("notifies no row when a message without a new Task arrives", () => {
  const cards = new ChatTaskCards();
  const first = [message("one", ["a"])];
  cards.update(first, true);
  const listener = vi.fn();
  cards.subscribe(listener);

  cards.update([...first, message("reply", [])], true);

  expect(cards.taskOf("one")).toBe("a");
  expect(listener).not.toHaveBeenCalled();
});
