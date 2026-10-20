import type { ProductInboxItem } from "@comma/core-client";
import type { MarkKind } from "@comma/core/contract";
import { flush } from "@comma/test-utils/fake-clock";
import { act, renderHook } from "@comma/test-utils/render";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { beforeEach, describe, expect, it } from "vitest";
import {
  useMarkTaskReviewSeen,
  useTaskReviewSeenMarks,
} from "../../tasks/taskReviewAttention";
import {
  inboxHasUnread,
  isInboxItemDeleted,
  isInboxItemUnread,
  useInboxDeletedMarks,
  useInboxMarkActions,
  useInboxUnreadMarks,
} from "../inboxDeletion";

const item = (over: Partial<ProductInboxItem>): ProductInboxItem => ({
  id: "w1:c1",
  kind: "user_chat",
  source: "salix.conversation",
  workspaceId: "w1",
  workspaceName: "Acme",
  groupId: "grp_test",
  conversationId: "c1",
  title: "Kickoff sync",
  status: "open",
  updatedAt: 1_000,
  ...over,
});

// The marks the core says the reader has (`say` changes them), and the reader's actions on them. The core's own
// keeping of marks (never moving back, unmarking) is core/test/marks.test.ts.
let marks: () => {
  seen: ReturnType<typeof useTaskReviewSeenMarks>;
  deleted: ReturnType<typeof useInboxDeletedMarks>;
  unreadMarks: ReturnType<typeof useInboxUnreadMarks>;
  actions: ReturnType<typeof useInboxMarkActions>;
  markSeen: ReturnType<typeof useMarkTaskReviewSeen>;
};
let core = createScriptedCore();
let scripted: Partial<Record<MarkKind, Record<string, number>>> = {};
const say = async (kind: MarkKind, next: Record<string, number>) => {
  scripted = { ...scripted, [kind]: next };
  act(() => core.changed("marks"));
  await flush();
};
const readTaskReviewSeenMarks = () => marks().seen;
const readInboxDeletedMarks = () => marks().deleted;
const readInboxUnreadMarks = () => marks().unreadMarks;
/** Runs a reader's action and answers the calls it sent. */
const run = async (action: () => void) => {
  const before = core.sent.length;
  act(action);
  await flush();
  return core.sent.slice(before);
};
const deleteInboxItems = (items: ProductInboxItem[]) =>
  run(() => marks().actions.deleteItems(items));
const markInboxItemsUnread = (items: ProductInboxItem[]) =>
  run(() => marks().actions.markUnread(items));
const markInboxItemsRead = (items: ProductInboxItem[]) =>
  run(() => marks().actions.markRead(items));
const clearInboxItemUnread = (ids: string[]) =>
  run(() => marks().actions.clearUnread(ids));
const markTaskReviewSeen = (id: string, at: number) =>
  run(() => marks().markSeen(id, at));

const unread = (target: ProductInboxItem) =>
  isInboxItemUnread(readTaskReviewSeenMarks(), readInboxUnreadMarks(), target);

describe("inboxDeletion", async () => {
  beforeEach(async () => {
    scripted = {};
    core = createScriptedCore({
      values: (topic) =>
        topic.topic === "marks"
          ? { marks: scripted[topic.kind as MarkKind] ?? {} }
          : undefined,
    });
    const view = renderHook(
      () => ({
        seen: useTaskReviewSeenMarks(),
        deleted: useInboxDeletedMarks(),
        unreadMarks: useInboxUnreadMarks(),
        actions: useInboxMarkActions(),
        markSeen: useMarkTaskReviewSeen(),
      }),
      { wrapper: ({ children }) => core.wrap(children) }
    );
    marks = () => view.result.current;
    await flush();
  });

  it("hides a deleted notification until its conversation updates again", async () => {
    const task = item({ kind: "agent_task", status: "completed", updatedAt: 100 });
    expect(isInboxItemDeleted(readInboxDeletedMarks(), task)).toBe(false);

    expect(await deleteInboxItems([task])).toEqual([
      ["marks.mark", { kind: "inboxDeleted", entries: [["w1:c1", 100]] }],
    ]);
    await say("inboxDeleted", { "w1:c1": 100 });
    expect(isInboxItemDeleted(readInboxDeletedMarks(), task)).toBe(true);
    expect(
      isInboxItemDeleted(readInboxDeletedMarks(), { ...task, updatedAt: 101 })
    ).toBe(false);
  });

  it("treats only an unseen needs-review task as naturally unread", async () => {
    const review = item({ kind: "agent_task", status: "needs_review", updatedAt: 100 });
    expect(unread(review)).toBe(true);
    expect(unread(item({ status: "open" }))).toBe(false);
    expect(unread(item({ kind: "agent_task", status: "completed" }))).toBe(false);

    expect(await markTaskReviewSeen(review.conversationId, 100)).toEqual([
      ["marks.mark", { kind: "taskReviewSeen", entries: [["c1", 100]] }],
    ]);
    await say("taskReviewSeen", { c1: 100 });
    expect(unread(review)).toBe(false);
  });

  it("keeps a user-marked row unread until the reader opens it", async () => {
    const chat = item({ status: "open" });
    expect(unread(chat)).toBe(false);

    expect(await markInboxItemsUnread([chat])).toEqual([
      ["marks.mark", { kind: "inboxUnread", entries: [["w1:c1", 1_000]] }],
    ]);
    await say("inboxUnread", { "w1:c1": 1_000 });
    expect(unread(chat)).toBe(true);
    expect(unread({ ...chat, updatedAt: 2_000 })).toBe(true);

    expect(await clearInboxItemUnread([chat.id])).toEqual([
      ["marks.unmark", { kind: "inboxUnread", ids: ["w1:c1"] }],
    ]);
    await say("inboxUnread", {});
    expect(unread(chat)).toBe(false);
  });

  it("shows the Inbox tab badge for visible unread rows only", async () => {
    const review = item({ kind: "agent_task", status: "needs_review", updatedAt: 100 });
    const chat = item({ id: "w1:c2", conversationId: "c2", status: "open" });
    const archived = item({
      id: "w1:c3",
      conversationId: "c3",
      kind: "agent_task",
      status: "archived",
      updatedAt: 100,
    });
    const deleted = item({
      id: "w1:c4",
      conversationId: "c4",
      kind: "agent_task",
      status: "needs_review",
      updatedAt: 100,
    });
    expect(await deleteInboxItems([deleted])).toEqual([
      ["marks.mark", { kind: "inboxDeleted", entries: [["w1:c4", 100]] }],
    ]);
    await say("inboxDeleted", { "w1:c4": 100 });

    expect(
      inboxHasUnread(
        [chat],
        readTaskReviewSeenMarks(),
        readInboxUnreadMarks(),
        readInboxDeletedMarks()
      )
    ).toBe(false);
    expect(
      inboxHasUnread(
        [review, archived, deleted],
        readTaskReviewSeenMarks(),
        readInboxUnreadMarks(),
        readInboxDeletedMarks()
      )
    ).toBe(true);

    expect(await markTaskReviewSeen(review.conversationId, 100)).toEqual([
      ["marks.mark", { kind: "taskReviewSeen", entries: [["c1", 100]] }],
    ]);
    await say("taskReviewSeen", { c1: 100 });
    expect(
      inboxHasUnread(
        [review, archived, deleted],
        readTaskReviewSeenMarks(),
        readInboxUnreadMarks(),
        readInboxDeletedMarks()
      )
    ).toBe(false);

    expect(await markInboxItemsUnread([chat])).toEqual([
      ["marks.mark", { kind: "inboxUnread", entries: [["w1:c2", 1_000]] }],
    ]);
    await say("inboxUnread", { "w1:c2": 1_000 });
    expect(
      inboxHasUnread(
        [chat, archived, deleted],
        readTaskReviewSeenMarks(),
        readInboxUnreadMarks(),
        readInboxDeletedMarks()
      )
    ).toBe(true);
  });

  it("clears user unread and needs-review attention when marked read", async () => {
    const chat = item({ status: "open" });
    const review = item({
      id: "w1:c2",
      conversationId: "c2",
      kind: "agent_task",
      status: "needs_review",
      updatedAt: 100,
    });
    expect(await markInboxItemsUnread([chat])).toEqual([
      ["marks.mark", { kind: "inboxUnread", entries: [["w1:c1", 1_000]] }],
    ]);
    await say("inboxUnread", { "w1:c1": 1_000 });
    expect(unread(chat)).toBe(true);
    expect(unread(review)).toBe(true);

    expect(await markInboxItemsRead([chat, review])).toEqual([
      ["marks.unmark", { kind: "inboxUnread", ids: ["w1:c1", "w1:c2"] }],
      ["marks.mark", { kind: "taskReviewSeen", entries: [["c1", 1_000]] }],
      ["marks.mark", { kind: "taskReviewSeen", entries: [["c2", 100]] }],
    ]);
    await say("inboxUnread", {});
    await say("taskReviewSeen", { c1: 1_000, c2: 100 });
    expect(unread(chat)).toBe(false);
    expect(unread(review)).toBe(false);
  });
});
