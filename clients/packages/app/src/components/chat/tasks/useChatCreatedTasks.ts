import { useTaskSummaries } from "../../tasks/useTaskArchive";
import { useTopicSelect, type ProductInboxListResult } from "@comma/core-client";
import {
  taskStatusBucket,
  type TaskStatusBucket,
} from "@comma/ui/components/task-workspace";
import { useEffect, useMemo, useRef } from "react";
import {
  taskReviewNeedsAttention,
  useTaskReviewSeenMarksOf,
} from "../../tasks/taskReviewAttention";
import { useDismissedPanelTasks } from "./chatTaskPanelDismissals";
import type { ChatMessage } from "@comma/core/chat";
import { asksRouter, conversationMessageTurnKey } from "@comma/core/chat";

export type ChatCreatedTask = {
  /**
   * The canonical version an archive request must name. Present only while
   * the server allows archiving, so it doubles as the row's "can archive".
   */
  archiveVersion: number | undefined;
  conversationId: string;
  /** Message that announced the task; the reveal highlights it. */
  messageId: string | undefined;
  /** Needs review and unseen since it last updated; drives the blue dot. */
  needsAttention: boolean;
  /**
   * The turn of the person's last request to the Router before the task was
   * announced; a Quick Chat's own task has the Quick Chat's turn. The reply
   * slot's wait reads it.
   */
  requestTurnKey?: string | undefined;
  statusBucket: TaskStatusBucket;
  /** The Task waits for its person (`escalated`), e.g. on a question its Worker asked. */
  needsInput: boolean;
  title: string;
  /** Turn that announced the task; undefined for agent-only leading turns. */
  turnKey: string | undefined;
  /**
   * When the Task's latest run started (`run_started_at`, Unix milliseconds)
   * as this chat knows it; 0 for a Task from before the server kept it. A
   * Dismiss acknowledges this run.
   */
  version: number;
};

const NO_TASKS: readonly ChatCreatedTask[] = [];

type CreatedTaskRef = {
  conversationId: string;
  messageId: string | undefined;
  requestTurnKey: string | undefined;
  title: string | undefined;
  turnKey: string | undefined;
  updatedAt: number | undefined;
};

/**
 * Tasks created in this conversation, in transcript order: the core names
 * each message's (`ChatMessage.createdTasks`). An agent's message and a
 * person's Quick Chat announce Tasks; a person's `comma:task` mention is
 * none. A Quick Chat Task belongs to its own turn, and a Task the agent
 * announces after a Quick Chat still answers the request before it. Status is
 * overlaid from the live ProductInbox projection so the panel tracks
 * lifecycle changes without polling. Unconfirmed references stay hidden;
 * message snapshots are never authoritative lifecycle facts.
 *
 * Settled tasks acknowledged through "Reveal in Chat" or "Dismiss" are
 * filtered out until they run again: a running task always shows, and one
 * whose latest run started after the run acknowledged shows again. A rename,
 * a label or a review acceptance starts no run, so it does not bring a row
 * back. Nothing lifts an acknowledgement, so a device that never saw the task
 * run cannot keep its next result hidden.
 *
 * The list is derived only when one of its sources changes, and a task whose
 * facts did not change keeps its object. A long-lived conversation docks every
 * task it ever announced, so one task moving on must cost one row, not a
 * re-render of the list.
 */
export function useChatCreatedTasks({
  groupId,
  messages,
}: {
  groupId: string;
  messages: readonly ChatMessage[];
}): readonly ChatCreatedTask[] {
  const createdRefs = useMemo(() => {
    const seen = new Set<string>();
    const refs: CreatedTaskRef[] = [];
    // Every turn is a person's request to the Router, their Quick Chat included.
    let requestTurnKey: string | undefined;
    for (const message of messages) {
      if (asksRouter(message)) requestTurnKey = conversationMessageTurnKey(message);
      for (const task of message.createdTasks ?? []) {
        if (seen.has(task.conversationId)) continue;
        seen.add(task.conversationId);
        refs.push({
          conversationId: task.conversationId,
          messageId: message.messageId,
          requestTurnKey,
          title: task.title,
          turnKey: requestTurnKey,
          updatedAt: task.updatedAt,
        });
      }
    }
    return refs;
  }, [messages]);

  const createdIds = useMemo(
    () => createdRefs.map((ref) => ref.conversationId),
    [createdRefs]
  );
  // The rows and marks of the Tasks this conversation created, from the live
  // projection and the reader's marks: a change to any other Task renders
  // nothing here.
  const projectedTasks = useProjectedTasks(groupId, createdIds);
  const seenReviewMarks = useTaskReviewSeenMarksOf(createdIds);
  const dismissed = useDismissedPanelTasks(createdIds);

  // The core asks the summary lane for the Tasks the list has no version of,
  // and says which facts are newer: the list's or the summary's.
  const summaries = useTaskSummaries(groupId, createdIds);

  const previousRef = useRef(NO_TASKS);
  const visible = useMemo(() => {
    if (createdRefs.length === 0) return NO_TASKS;
    const previous = previousRef.current;
    let previousById: Map<string, ChatCreatedTask> | undefined;
    const next: ChatCreatedTask[] = [];
    for (const ref of createdRefs) {
      const projected = projectedTasks.get(ref.conversationId);
      const known = summaries.get(ref.conversationId);
      if (!known && !projected) continue;
      const status = known?.status ?? projected!.status;
      if (status === "archived") continue;
      const statusBucket = taskStatusBucket(status);
      const needsInput = status === "escalated";
      const updatedAt = projected?.updatedAt ?? ref.updatedAt ?? 0;
      const version = Math.max(
        known?.run_started_at ?? 0,
        projected?.runStartedAt ?? 0
      );
      // Settled and acknowledged at this run or a later one via "Reveal in
      // Chat" or "Dismiss": stays cleared. A running task always docks.
      if (
        statusBucket !== "in_progress" &&
        (dismissed.get(ref.conversationId) ?? -1) >= version
      ) {
        continue;
      }
      // The same facts give the status, the title and the archive precondition.
      // Facts the core no longer confirms come without archive permission.
      const archiveVersion = known
        ? known.archive_availability?.allowed
          ? known.updated_at
          : undefined
        : projected?.archiveAvailability?.allowed
          ? projected.archiveVersion
          : undefined;
      const needsAttention =
        statusBucket === "needs_review" &&
        taskReviewNeedsAttention(seenReviewMarks, ref.conversationId, updatedAt);
      const title = known?.title ?? projected?.title ?? ref.title ?? "";
      // A task whose facts held keeps its object. Tasks rarely move, so the
      // same slot is tried first and the index is only built when it misses.
      let before = previous[next.length];
      if (before?.conversationId !== ref.conversationId) {
        previousById ??= new Map(previous.map((task) => [task.conversationId, task]));
        before = previousById.get(ref.conversationId);
      }
      next.push(
        before &&
          before.archiveVersion === archiveVersion &&
          before.messageId === ref.messageId &&
          before.needsAttention === needsAttention &&
          before.requestTurnKey === ref.requestTurnKey &&
          before.statusBucket === statusBucket &&
          before.needsInput === needsInput &&
          before.title === title &&
          before.turnKey === ref.turnKey &&
          before.version === version
          ? before
          : {
              archiveVersion,
              conversationId: ref.conversationId,
              messageId: ref.messageId,
              needsAttention,
              requestTurnKey: ref.requestTurnKey,
              statusBucket,
              needsInput,
              title,
              turnKey: ref.turnKey,
              version,
            }
      );
    }
    const unchanged =
      next.length === previous.length &&
      next.every((task, index) => task === previous[index]);
    return unchanged ? previous : next;
  }, [createdRefs, dismissed, projectedTasks, seenReviewMarks, summaries]);
  useEffect(() => {
    previousRef.current = visible;
  }, [visible]);

  return visible;
}

type ProjectedTask = ProductInboxListResult["items"][number];
const NO_PROJECTED_TASKS: ReadonlyMap<string, ProjectedTask> = new Map();

/**
 * The focused list's row of each of `ids` in the Group, by id. The map stays the
 * same object until one of those rows changes (the core keeps an unchanged row's
 * object), so the list's other changes render nothing.
 */
function useProjectedTasks(
  groupId: string,
  ids: readonly string[]
): ReadonlyMap<string, ProjectedTask> {
  const last = useRef(NO_PROJECTED_TASKS);
  return useTopicSelect({ topic: "tasks", workspace: "" }, (value) => {
    if (ids.length === 0) return NO_PROJECTED_TASKS;
    const wanted = new Set(ids);
    const rows = new Map<string, ProjectedTask>();
    for (const item of value?.items ?? []) {
      if (
        item.groupId === groupId &&
        wanted.has(item.conversationId) &&
        !rows.has(item.conversationId)
      ) {
        rows.set(item.conversationId, item);
      }
    }
    const previous = last.current;
    const same =
      rows.size === previous.size &&
      [...rows].every(([id, row]) => previous.get(id) === row);
    if (!same) last.current = rows;
    return last.current;
  });
}
