import { describe, expect, it } from "vitest";
import type { ChatMessage } from "@comma/chat-contract";
import { messageRelationships, messageThreadRoots } from "../messageRelationships";

const message = (
  id: string,
  actorId: string,
  target?: string,
  root = target ?? id
): ChatMessage => ({
  messageId: id,
  actorId,
  actorRole: "worker",
  role: "assistant",
  text: id,
  replyToMessageId: target,
  threadRootMessageId: root,
  attachments: [],
  refs: [],
  delivery: "sent",
  source: "server",
});

const branchingThread = () => [
  { ...message("A", "user"), role: "user" },
  message("B", "worker-b", "A", "A"),
  message("C", "worker-c", "A", "A"),
  message("D", "router", "B", "A"),
  message("E", "worker-e", "C", "A"),
];

describe("message threads", () => {
  it("keeps branches in the owner's thread, including when parents and root are absent", () => {
    const messages = branchingThread();
    expect([...messageThreadRoots(messages).values()]).toEqual([
      "A",
      "A",
      "A",
      "A",
      "A",
    ]);
    const paged = [messages[3]!, messages[4]!, message("other", "router")];
    expect([...messageThreadRoots(paged)]).toEqual([
      ["D", "A"],
      ["E", "A"],
      ["other", "other"],
    ]);
  });

  it("does not reconstruct missing thread metadata from direct parents or transcript order", () => {
    const messages = branchingThread().map(
      ({ threadRootMessageId: _root, ...item }) => item
    );
    expect(new Set(messageThreadRoots(messages).values()).size).toBe(5);
    expect(messageRelationships(messages).replies.size).toBe(0);
  });
});

describe("message thread layout", () => {
  it("connects siblings and descendants along one spine instead of repeating parent edges", () => {
    const { replies } = messageRelationships(branchingThread());
    expect(
      [...replies.values()].map((r) => [r.messageId, r.targetId, r.presentation])
    ).toEqual([
      ["B", "A", "line"],
      ["C", "B", "line"],
      ["D", "C", "line"],
      ["E", "D", "line"],
    ]);
  });

  it("merges consecutive messages from the same sender and thread even with different parents", () => {
    const { positions, replies } = messageRelationships([
      message("A", "router"),
      message("B", "worker", "A", "A"),
      message("C", "worker", "B", "A"),
      message("D", "worker", "A", "A"),
      message("E", "worker", undefined, "E"),
    ]);
    expect(positions.get("B")).toEqual({
      first: true,
      last: false,
      avatarMessageId: "D",
    });
    expect(positions.get("C")).toEqual({
      first: false,
      last: false,
      avatarMessageId: "D",
    });
    expect(positions.get("D")).toEqual({
      first: false,
      last: true,
      avatarMessageId: "D",
    });
    expect(positions.get("E")?.first).toBe(true);
    expect([...replies.values()].map((r) => [r.messageId, r.sourceAnchorId])).toEqual([
      ["B", "D"],
    ]);
  });

  it("quotes the root once when a different thread cuts the spine, then extends that segment", () => {
    const { replies } = messageRelationships([
      message("A", "a"),
      message("B", "b"),
      message("C", "c", "A", "A"),
      message("D", "d", "B", "B"),
      message("E", "e", "C", "A"),
      message("F", "f", "A", "A"),
    ]);
    expect(
      [...replies.values()].map((r) => [r.messageId, r.targetId, r.presentation])
    ).toEqual([
      ["C", "A", "line"],
      ["D", "B", "preview"],
      ["E", "A", "preview"],
      ["F", "E", "line"],
    ]);
  });

  it("prevents a later thread from containing an earlier continuation segment", () => {
    const { replies } = messageRelationships([
      message("PR", "user"),
      message("Slack", "user"),
      message("PR-reply", "router", "PR"),
      message("Linear", "user"),
      message("Slack-reply", "router", "Slack"),
      message("Linear-reply", "router", "Linear"),
    ]);
    expect([...replies.values()].map((r) => r.presentation)).toEqual([
      "line",
      "preview",
      "preview",
    ]);
  });

  it("uses one root preview for a paginated thread, even with different unloaded parents", () => {
    const { replies } = messageRelationships([
      message("D", "d", "B", "A"),
      message("E", "e", "C", "A"),
    ]);
    expect(replies.get("D")).toMatchObject({ targetId: "A", presentation: "preview" });
    expect(replies.get("E")).toMatchObject({ targetId: "D", presentation: "line" });
  });

  it("keeps the exact user anchor when adjacent user messages start different threads", () => {
    const { replies } = messageRelationships([
      { ...message("A", "user"), role: "user" },
      { ...message("B", "user"), role: "user" },
      message("C", "router", "A"),
    ]);
    expect(replies.get("C")?.targetAnchorId).toBe("A");
  });

  it("breaks sender groups at timestamps without splitting the thread", () => {
    const { positions, replies } = messageRelationships(
      [
        message("A", "worker"),
        message("B", "worker", "A"),
        message("C", "router", "B", "A"),
      ],
      new Set(["B"])
    );
    expect(positions.get("A")?.last).toBe(true);
    expect(positions.get("B")?.first).toBe(true);
    expect(replies.get("B")).toMatchObject({ targetId: "A", presentation: "line" });
    expect(replies.get("C")).toMatchObject({ targetId: "B", presentation: "line" });
  });
});
