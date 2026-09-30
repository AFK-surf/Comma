import {
  createRevisionMarksStore,
  useRevisionMarks,
  type RevisionMarks,
} from "../revisionMarks";

/**
 * Client-side "seen" marks for the needs-review attention dot. The server has
 * no per-user read state for tasks, so viewing is a renderer-local fact: a
 * mark records the task's projection `updatedAt` at the moment its
 * conversation was open. The dot shows while a needs-review task is newer
 * than its mark, which also re-arms it by itself when a task later re-enters
 * review (any lifecycle change bumps `updatedAt` past the old mark).
 */
const TASK_REVIEW_SEEN_STORAGE_KEY = "comma.taskReviewSeen";

const store = createRevisionMarksStore({
  changedEvent: "comma:task-review-seen-changed",
  maxMarks: 300,
  persist: (raw) => globalThis.localStorage?.setItem(TASK_REVIEW_SEEN_STORAGE_KEY, raw),
  storageKey: TASK_REVIEW_SEEN_STORAGE_KEY,
});

export type TaskReviewSeenMarks = RevisionMarks;

export const readTaskReviewSeenMarks = store.read;
export const subscribeTaskReviewSeen = store.subscribe;

export function markTaskReviewSeen(conversationId: string, updatedAt: number) {
  store.mark([[conversationId, updatedAt]]);
}

export function useTaskReviewSeenMarks(): TaskReviewSeenMarks {
  return useRevisionMarks(store);
}

/** Whether a needs-review task still awaits its first viewing since updating. */
export function taskReviewNeedsAttention(
  marks: TaskReviewSeenMarks,
  conversationId: string,
  updatedAt: number
) {
  const seenAt = marks.get(conversationId);
  return seenAt === undefined || updatedAt > seenAt;
}
