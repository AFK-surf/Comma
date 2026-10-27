import { useCallback } from "react";
import {
  useRevisionMarks,
  useRevisionMarksOf,
  useRevisionMarkWriter,
  type RevisionMarks,
} from "../revisionMarks";

/**
 * "Seen" marks for the needs-review attention dot. The server has no per-user
 * read state for tasks, so viewing is a fact of this device: a mark records
 * the task's projection `updatedAt` at the moment its conversation was open.
 * The dot shows while a needs-review task is newer than its mark, which also
 * re-arms it by itself when a task later re-enters review (any lifecycle
 * change bumps `updatedAt` past the old mark).
 */
const LEGACY_STORAGE_KEY = "comma.taskReviewSeen";

export type TaskReviewSeenMarks = RevisionMarks;

export function useTaskReviewSeenMarks(): TaskReviewSeenMarks {
  return useRevisionMarks("taskReviewSeen", LEGACY_STORAGE_KEY);
}

/** The "seen" marks of `ids` alone: rows of a few Tasks render again only when one of theirs moves. */
export function useTaskReviewSeenMarksOf(ids: readonly string[]): TaskReviewSeenMarks {
  return useRevisionMarksOf("taskReviewSeen", LEGACY_STORAGE_KEY, ids);
}

/** Records that a task was seen at a revision. */
export function useMarkTaskReviewSeen() {
  const { mark } = useRevisionMarkWriter("taskReviewSeen");
  return useCallback(
    (conversationId: string, updatedAt: number) => mark([[conversationId, updatedAt]]),
    [mark]
  );
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
