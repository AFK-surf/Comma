import type { ProductInboxItem } from "@comma/core-client";
import { taskStatusBucket } from "@comma/ui/components/task-workspace";
import { useMemo } from "react";
import {
  useRevisionMarks,
  useRevisionMarkWriter,
  type RevisionMarks,
} from "../revisionMarks";
import {
  taskReviewNeedsAttention,
  useMarkTaskReviewSeen,
  type TaskReviewSeenMarks,
} from "../tasks/taskReviewAttention";

/**
 * "Deleted" marks for Inbox notifications. Deleting one never touches its
 * conversation — the server keeps no per-user notification state — it hides
 * the row until the conversation updates again, when the newer revision
 * outgrows the mark and the notification comes back, the way an inbox
 * re-notifies on fresh activity.
 *
 * "Unread" marks: the server has no per-user read state for Inbox rows, so
 * Mark as unread is a fact of this device: the attention dot stays until the
 * reader opens the row or marks it read.
 */
const LEGACY_DELETED_KEY = "comma.inboxDeleted";
const LEGACY_UNREAD_KEY = "comma.inboxUnread";

export type InboxDeletedMarks = RevisionMarks;
export type InboxUnreadMarks = RevisionMarks;

export function useInboxDeletedMarks(): InboxDeletedMarks {
  return useRevisionMarks("inboxDeleted", LEGACY_DELETED_KEY);
}

export function useInboxUnreadMarks(): InboxUnreadMarks {
  return useRevisionMarks("inboxUnread", LEGACY_UNREAD_KEY);
}

/** What the reader can do to Inbox rows on this device. */
export function useInboxMarkActions() {
  const deleted = useRevisionMarkWriter("inboxDeleted");
  const unread = useRevisionMarkWriter("inboxUnread");
  const seen = useMarkTaskReviewSeen();
  return useMemo(
    () => ({
      /** Hides these notifications until their conversations update again. */
      deleteItems: (items: readonly ProductInboxItem[]) =>
        deleted.mark(items.map((item) => [item.id, item.updatedAt] as const)),
      /** Shows the attention dot on these notifications until the reader opens them. */
      markUnread: (items: readonly ProductInboxItem[]) =>
        unread.mark(items.map((item) => [item.id, item.updatedAt] as const)),
      /** Drops a user unread mark so the row can read as read again. */
      clearUnread: (ids: readonly string[]) => unread.unmark(ids),
      /**
       * Clears the attention dot without opening the row: drops a user unread
       * mark and records the current revision as seen for needs-review tasks.
       */
      markRead: (items: readonly ProductInboxItem[]) => {
        unread.unmark(items.map((item) => item.id));
        for (const item of items) seen(item.conversationId, item.updatedAt);
      },
    }),
    [deleted, seen, unread]
  );
}

export function isInboxItemDeleted(marks: InboxDeletedMarks, item: ProductInboxItem) {
  const deletedAt = marks.get(item.id);
  return deletedAt !== undefined && item.updatedAt <= deletedAt;
}

function isInboxItemUserUnread(marks: InboxUnreadMarks, item: ProductInboxItem) {
  return marks.has(item.id);
}

/**
 * A notification is unread while its row shows the attention dot: a
 * needs-review task the reader has not opened since it last updated, or a
 * row the reader marked unread. Opening the row clears the user mark.
 */
export function isInboxItemUnread(
  seenMarks: TaskReviewSeenMarks,
  unreadMarks: InboxUnreadMarks,
  item: ProductInboxItem
) {
  if (isInboxItemUserUnread(unreadMarks, item)) return true;
  return (
    taskStatusBucket(item.status) === "needs_review" &&
    taskReviewNeedsAttention(seenMarks, item.conversationId, item.updatedAt)
  );
}

/**
 * True when the Inbox tab should show its unread badge: any visible
 * notification still carries the attention dot.
 */
export function inboxHasUnread(
  items: readonly ProductInboxItem[],
  seenMarks: TaskReviewSeenMarks,
  unreadMarks: InboxUnreadMarks,
  deletedMarks: InboxDeletedMarks
) {
  return items.some(
    (item) =>
      item.status !== "archived" &&
      !isInboxItemDeleted(deletedMarks, item) &&
      isInboxItemUnread(seenMarks, unreadMarks, item)
  );
}
