import type { ProductInboxItem } from "@comma/native-bridge";
import { beforeEach, describe, expect, it } from "vitest";
import {
  markTaskReviewSeen,
  readTaskReviewSeenMarks,
} from "../../tasks/taskReviewAttention";
import {
  clearInboxItemUnread,
  deleteInboxItems,
  inboxHasUnread,
  isInboxItemDeleted,
  isInboxItemUnread,
  markInboxItemsRead,
  markInboxItemsUnread,
  readInboxDeletedMarks,
  readInboxUnreadMarks,
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

const unread = (target: ProductInboxItem) =>
  isInboxItemUnread(readTaskReviewSeenMarks(), readInboxUnreadMarks(), target);

describe("inboxDeletion", () => {
  beforeEach(() => {
    window.localStorage.clear();
  });

  it("hides a deleted notification until its conversation updates again", () => {
    const task = item({ kind: "agent_task", status: "completed", updatedAt: 100 });
    expect(isInboxItemDeleted(readInboxDeletedMarks(), task)).toBe(false);

    deleteInboxItems([task]);
    expect(isInboxItemDeleted(readInboxDeletedMarks(), task)).toBe(true);
    expect(
      isInboxItemDeleted(readInboxDeletedMarks(), { ...task, updatedAt: 101 })
    ).toBe(false);
  });

  it("treats only an unseen needs-review task as naturally unread", () => {
    const review = item({ kind: "agent_task", status: "needs_review", updatedAt: 100 });
    expect(unread(review)).toBe(true);
    expect(unread(item({ status: "open" }))).toBe(false);
    expect(unread(item({ kind: "agent_task", status: "completed" }))).toBe(false);

    markTaskReviewSeen(review.conversationId, 100);
    expect(unread(review)).toBe(false);
  });

  it("keeps a user-marked row unread until the reader opens it", () => {
    const chat = item({ status: "open" });
    expect(unread(chat)).toBe(false);

    markInboxItemsUnread([chat]);
    expect(unread(chat)).toBe(true);
    expect(unread({ ...chat, updatedAt: 2_000 })).toBe(true);

    clearInboxItemUnread([chat.id]);
    expect(unread(chat)).toBe(false);
  });

  it("shows the Inbox tab badge for visible unread rows only", () => {
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
    deleteInboxItems([deleted]);

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

    markTaskReviewSeen(review.conversationId, 100);
    expect(
      inboxHasUnread(
        [review, archived, deleted],
        readTaskReviewSeenMarks(),
        readInboxUnreadMarks(),
        readInboxDeletedMarks()
      )
    ).toBe(false);

    markInboxItemsUnread([chat]);
    expect(
      inboxHasUnread(
        [chat, archived, deleted],
        readTaskReviewSeenMarks(),
        readInboxUnreadMarks(),
        readInboxDeletedMarks()
      )
    ).toBe(true);
  });

  it("clears user unread and needs-review attention when marked read", () => {
    const chat = item({ status: "open" });
    const review = item({
      id: "w1:c2",
      conversationId: "c2",
      kind: "agent_task",
      status: "needs_review",
      updatedAt: 100,
    });
    markInboxItemsUnread([chat]);
    expect(unread(chat)).toBe(true);
    expect(unread(review)).toBe(true);

    markInboxItemsRead([chat, review]);
    expect(unread(chat)).toBe(false);
    expect(unread(review)).toBe(false);
  });
});
