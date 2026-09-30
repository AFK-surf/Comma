import type { CommaApiClient } from "../../../api";
import { useSyncExternalStore, useCallback } from "react";
import {
  readTaskSummary,
  requestTaskSummary,
  subscribeTaskSummaries,
  taskSummaryRevision,
} from "../../tasks/taskArchiveState";
import { useTaskFactsRevalidation } from "../../tasks/useTaskArchive";
import { taskStatusBucket, type TaskStatusBucket } from "@comma/ui";
import { useEffect, useMemo, useRef } from "react";
import { useProductInboxSnapshot } from "../../../product-inbox/react";
import {
  taskReviewNeedsAttention,
  useTaskReviewSeenMarks,
} from "../../tasks/taskReviewAttention";
import { restorePanelTask, useDismissedPanelTasks } from "./chatTaskPanelDismissals";
import type { ChatMessage } from "../model/conversationChannel";
import { conversationMessageTurnKey } from "../model/visibleReplyPresentation";

export type ChatCreatedTask = {
  /**
   * The canonical version an archive request must name. Present only while
   * the server allows archiving, so it doubles as the row's "can archive".
   */
  archiveVersion: number | undefined;
  conversationId: string;
  /** Assistant message that announced the task; the reveal highlights it. */
  messageId: string | undefined;
  /** Needs review and unseen since it last updated; drives the blue dot. */
  needsAttention: boolean;
  statusBucket: TaskStatusBucket;
  title: string;
  /** Turn that announced the task; undefined for agent-only leading turns. */
  turnKey: string | undefined;
};

const NO_TASKS: readonly ChatCreatedTask[] = [];
const NO_RESTORES: readonly string[] = [];

type CreatedTaskRef = {
  conversationId: string;
  messageId: string | undefined;
  title: string | undefined;
  turnKey: string | undefined;
  updatedAt: number | undefined;
};

/**
 * Tasks the agent created in this conversation, in transcript order. A task
 * arrives as a `conversation_ref` on a committed assistant message (inline
 * part or block ref), so scanning non-user messages both defines creation
 * order and skips user-authored `comma:task` mentions. Status is overlaid from
 * the live ProductInbox projection so the panel tracks lifecycle changes
 * without polling. Unconfirmed references stay hidden; message snapshots are
 * never authoritative lifecycle facts.
 *
 * Settled tasks acknowledged through "Reveal in Chat" or "Dismiss" are
 * filtered out until the task is observed running again (see
 * chatTaskPanelDismissals).
 *
 * The list is derived only when one of its sources changes, and a task whose
 * facts did not change keeps its object. A long-lived conversation docks every
 * task it ever announced, so one task moving on must cost one row, not a
 * re-render of the list.
 */
export function useChatCreatedTasks({
  api,
  groupId,
  messages,
}: {
  api?: CommaApiClient | undefined;
  groupId: string;
  messages: readonly ChatMessage[];
}): readonly ChatCreatedTask[] {
  const productInbox = useProductInboxSnapshot();
  useTaskFactsRevalidation(api);
  const revision = useSyncExternalStore(
    useCallback(
      (listener: () => void) =>
        api ? subscribeTaskSummaries(api, listener) : () => {},
      [api]
    ),
    () => (api ? taskSummaryRevision(api) : 0),
    () => 0
  );
  const seenReviewMarks = useTaskReviewSeenMarks();
  const dismissed = useDismissedPanelTasks();
  const createdRefs = useMemo(() => {
    const seen = new Set<string>();
    const refs: CreatedTaskRef[] = [];
    let currentTurnKey: string | undefined;
    for (const message of messages) {
      if (message.role === "user") {
        currentTurnKey = conversationMessageTurnKey(message);
        continue;
      }
      for (const part of message.parts ?? []) {
        if (part.kind !== "inline-task") continue;
        const conversationId = part.task.conversationId;
        if (!conversationId || part.task.unavailable || seen.has(conversationId)) {
          continue;
        }
        seen.add(conversationId);
        refs.push({
          conversationId,
          messageId: message.messageId,
          title: part.task.title,
          turnKey: currentTurnKey,
          updatedAt: part.task.updatedAt,
        });
      }
      for (const ref of message.refs) {
        if (ref.kind !== "agent_task" || seen.has(ref.conversationId)) continue;
        seen.add(ref.conversationId);
        refs.push({
          conversationId: ref.conversationId,
          messageId: message.messageId,
          title: ref.title,
          turnKey: currentTurnKey,
          updatedAt: undefined,
        });
      }
    }
    return refs;
  }, [messages]);

  // One pass over the projection per snapshot; every reference then resolves
  // its task in constant time instead of scanning the whole Inbox.
  const projectedItems = productInbox?.snapshot.items;
  const projectedTasks = useMemo(() => {
    const tasks = new Map<string, NonNullable<typeof projectedItems>[number]>();
    if (createdRefs.length === 0) return tasks;
    for (const item of projectedItems ?? []) {
      if (item.groupId === groupId && !tasks.has(item.conversationId)) {
        tasks.set(item.conversationId, item);
      }
    }
    return tasks;
  }, [createdRefs, groupId, projectedItems]);

  useEffect(() => {
    if (api)
      for (const ref of createdRefs)
        // The owner already supplied versioned facts for Tasks in its loaded page.
        // References outside that page still use the bounded summary request lane.
        if (!projectedTasks.get(ref.conversationId)?.archiveVersion)
          requestTaskSummary(api, groupId, ref.conversationId);
  }, [api, groupId, createdRefs, projectedTasks, revision]);

  const previousRef = useRef(NO_TASKS);
  const { restore, visible } = useMemo(() => {
    if (createdRefs.length === 0) {
      return { restore: NO_RESTORES, visible: NO_TASKS };
    }
    const previous = previousRef.current;
    let previousById: Map<string, ChatCreatedTask> | undefined;
    const next: ChatCreatedTask[] = [];
    const running: string[] = [];
    for (const ref of createdRefs) {
      const projected = projectedTasks.get(ref.conversationId);
      const canonical = api
        ? readTaskSummary(api, groupId, ref.conversationId)
        : undefined;
      if (!canonical && !projected) continue;
      const useProjected =
        projected && (projected.archiveVersion ?? 0) >= (canonical?.updated_at ?? 0);
      const status = useProjected
        ? projected.status
        : (canonical?.status ?? projected!.status);
      if (status === "archived") continue;
      const statusBucket = taskStatusBucket(status);
      const updatedAt = projected?.updatedAt ?? ref.updatedAt ?? 0;
      if (statusBucket === "in_progress") {
        // A running task always docks; observing it running also lifts an old
        // acknowledgement so its next settle asks to be revealed again.
        if (dismissed.has(ref.conversationId)) running.push(ref.conversationId);
      } else if (dismissed.has(ref.conversationId)) {
        // Settled and acknowledged via "Reveal in Chat" or "Dismiss" — stays cleared.
        continue;
      }
      // Keep the same authority for status, title and the archive precondition.
      // Invalidating cached summaries must not remove controls backed by current owner facts.
      const archiveVersion = useProjected
        ? projected.archiveAvailability?.allowed
          ? projected.archiveVersion
          : undefined
        : canonical?.archive_availability?.allowed
          ? canonical.updated_at
          : undefined;
      const needsAttention =
        statusBucket === "needs_review" &&
        taskReviewNeedsAttention(seenReviewMarks, ref.conversationId, updatedAt);
      const title = useProjected
        ? projected.title
        : (canonical?.title ?? projected?.title ?? ref.title ?? "");
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
          before.statusBucket === statusBucket &&
          before.title === title &&
          before.turnKey === ref.turnKey
          ? before
          : {
              archiveVersion,
              conversationId: ref.conversationId,
              messageId: ref.messageId,
              needsAttention,
              statusBucket,
              title,
              turnKey: ref.turnKey,
            }
      );
    }
    const unchanged =
      next.length === previous.length &&
      next.every((task, index) => task === previous[index]);
    return {
      restore: running.length > 0 ? running : NO_RESTORES,
      visible: unchanged ? previous : next,
    };
    // `revision` is the summary cache's version: `readTaskSummary` reads the
    // cache, so a new revision is what makes this derivation stale.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [api, createdRefs, dismissed, groupId, projectedTasks, revision, seenReviewMarks]);
  useEffect(() => {
    previousRef.current = visible;
  }, [visible]);

  useEffect(() => {
    for (const conversationId of restore) restorePanelTask(conversationId);
  }, [restore]);

  return visible;
}
