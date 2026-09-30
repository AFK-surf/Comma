import type { ProductInboxItem } from "@comma/native-bridge";
import { taskStatusBucket } from "@comma/ui";
import {
  createRevisionMarksStore,
  useRevisionMarks,
  type RevisionMarks,
} from "../revisionMarks";
import {
  markTaskReviewSeen,
  taskReviewNeedsAttention,
  type TaskReviewSeenMarks,
} from "../tasks/taskReviewAttention";

/**
 * Renderer-local "deleted" marks for Inbox notifications. Deleting one never
 * touches its conversation — the server keeps no per-user notification state
 * — it hides the row until the conversation updates again, when the newer
 * revision outgrows the mark and the notification comes back, the way an
 * inbox re-notifies on fresh activity.
 */
const INBOX_DELETED_STORAGE_KEY = "comma.inboxDeleted";
const INBOX_UNREAD_STORAGE_KEY = "comma.inboxUnread";

const deletedStore = createRevisionMarksStore({
  changedEvent: "comma:inbox-deleted-changed",
  maxMarks: 500,
  persist: (raw) => globalThis.localStorage?.setItem(INBOX_DELETED_STORAGE_KEY, raw),
  storageKey: INBOX_DELETED_STORAGE_KEY,
});

/**
 * Renderer-local "unread" marks. The server has no per-user read state for
 * Inbox rows, so Mark as unread is a client fact: the attention dot stays
 * until the reader opens the row or marks it read.
 */
const unreadStore = createRevisionMarksStore({
  changedEvent: "comma:inbox-unread-changed",
  maxMarks: 500,
  persist: (raw) => globalThis.localStorage?.setItem(INBOX_UNREAD_STORAGE_KEY, raw),
  storageKey: INBOX_UNREAD_STORAGE_KEY,
});

export type InboxDeletedMarks = RevisionMarks;
export type InboxUnreadMarks = RevisionMarks;

export const readInboxDeletedMarks = deletedStore.read;
export const readInboxUnreadMarks = unreadStore.read;

export function useInboxDeletedMarks(): InboxDeletedMarks {
  return useRevisionMarks(deletedStore);
}

export function useInboxUnreadMarks(): InboxUnreadMarks {
  return useRevisionMarks(unreadStore);
}

export function isInboxItemDeleted(marks: InboxDeletedMarks, item: ProductInboxItem) {
  const deletedAt = marks.get(item.id);
  return deletedAt !== undefined && item.updatedAt <= deletedAt;
}

/** Hides these notifications until their conversations update again. */
export function deleteInboxItems(items: readonly ProductInboxItem[]) {
  deletedStore.mark(items.map((item) => [item.id, item.updatedAt] as const));
}

/** Shows the attention dot on these notifications until the reader opens them. */
export function markInboxItemsUnread(items: readonly ProductInboxItem[]) {
  unreadStore.mark(items.map((item) => [item.id, item.updatedAt] as const));
}

/** Drops a user unread mark so the row can read as read again. */
export function clearInboxItemUnread(ids: readonly string[]) {
  unreadStore.unmark(ids);
}

/**
 * Clears the attention dot without opening the row: drops a user unread mark
 * and records the current revision as seen for needs-review tasks.
 */
export function markInboxItemsRead(items: readonly ProductInboxItem[]) {
  unreadStore.unmark(items.map((item) => item.id));
  for (const item of items) {
    markTaskReviewSeen(item.conversationId, item.updatedAt);
  }
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
