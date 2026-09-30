import { messages } from "@comma/i18n";
import { toast, type TaskStatusBucket } from "@comma/ui";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { CommaApiClient } from "../../api";

export type TaskOrders = Partial<Record<TaskStatusBucket, readonly string[]>>;

export interface TaskOrderRef {
  /** Canonical conversation id — what the Group's stored order is written in. */
  conversationId: string;
  /** Projection view-model id — what the cards on screen are keyed by. */
  id: string;
}

export interface TaskOrderState {
  /** Per-bucket dragged card order, layered over the projection's order. */
  orders: TaskOrders;
  /** Commits a drop: applies it locally at once and persists it per Group. */
  setBucketOrder: (bucket: TaskStatusBucket, ids: string[]) => void;
}

interface TaskOrderWrite {
  api: CommaApiClient;
  bucket: TaskStatusBucket;
  conversationIds: string[];
  groupId: string;
}

interface TaskOrderWriteLane {
  pending: TaskOrderWrite | undefined;
}

/**
 * One renderer-wide writer lane per durable bucket. React routes may unmount
 * while fetch still owns a request, so hook-local refs cannot enforce the
 * ordering contract. A busy lane keeps only the newest unsent drop; the active
 * PUT always settles before that value is sent.
 *
 * Keep these transitions aligned with tla/task-order/TaskOrderWriteQueue.tla.
 */
const taskOrderWriteLanes = new Map<string, TaskOrderWriteLane>();

function taskOrderWriteKey(groupId: string, bucket: TaskStatusBucket) {
  return JSON.stringify([groupId, bucket]);
}

function notifyTaskOrderSaveFailed() {
  toast.error(messages.tasks_order_save_failed(), {
    id: "tasks-order-save-failed",
    testId: "tasks-order-save-failed",
  });
}

async function drainTaskOrderWriteLane(key: string, lane: TaskOrderWriteLane) {
  while (lane.pending) {
    const write = lane.pending;
    lane.pending = undefined;
    try {
      await write.api.putTaskOrder(write.groupId, write.bucket, write.conversationIds);
    } catch {
      notifyTaskOrderSaveFailed();
    }
  }
  if (taskOrderWriteLanes.get(key) === lane) taskOrderWriteLanes.delete(key);
}

function enqueueTaskOrderWrite(write: TaskOrderWrite) {
  const key = taskOrderWriteKey(write.groupId, write.bucket);
  const existing = taskOrderWriteLanes.get(key);
  if (existing) {
    existing.pending = write;
    return;
  }

  const lane = { pending: write };
  taskOrderWriteLanes.set(key, lane);
  void drainTaskOrderWriteLane(key, lane);
}

/**
 * The Group's persisted Task-board arrangement, shared by every surface that
 * renders the cards (the Tasks board and the home rail). A drop applies
 * locally in the same frame and is written through to the Group, so the
 * arrangement survives reloads and follows the user across devices. A failed
 * write keeps the local arrangement — the cards the user just placed must not
 * snap back under their pointer — and says so instead of pretending it stuck.
 */
export function useTaskOrder(
  api: CommaApiClient,
  groupId: string | undefined,
  tasks: readonly TaskOrderRef[]
): TaskOrderState {
  /** Stored in canonical conversation ids; projected to view ids on the way out. */
  const [stored, setStored] = useState<TaskOrders>({});
  const groupRef = useRef(groupId);
  const localMutationGeneration = useRef(0);
  groupRef.current = groupId;
  const conversationIdByViewId = useMemo(
    () => new Map(tasks.map((task) => [task.id, task.conversationId])),
    [tasks]
  );
  const viewIdByConversationId = useMemo(
    () => new Map(tasks.map((task) => [task.conversationId, task.id])),
    [tasks]
  );
  const orders = useMemo(() => {
    const projected: Record<string, readonly string[]> = {};
    for (const [bucket, conversationIds] of Object.entries(stored)) {
      projected[bucket] = (conversationIds ?? [])
        .map((conversationId) => viewIdByConversationId.get(conversationId))
        .filter((viewId): viewId is string => viewId !== undefined);
    }
    return projected as TaskOrders;
  }, [stored, viewIdByConversationId]);

  useEffect(() => {
    setStored({});
    if (!groupId) return undefined;
    let alive = true;
    const generationAtLoadStart = localMutationGeneration.current;
    api
      .getTaskOrder(groupId)
      .then((persisted) => {
        if (
          alive &&
          groupRef.current === groupId &&
          localMutationGeneration.current === generationAtLoadStart
        ) {
          setStored(persisted.orders as TaskOrders);
        }
      })
      .catch(() => {
        // The board stays fully usable in projection order — the stored
        // arrangement simply has not been applied. Only a failed SAVE is worth
        // interrupting for: the user just placed a card and must know it may
        // not stick.
      });
    return () => {
      alive = false;
    };
  }, [api, groupId]);

  const setBucketOrder = useCallback(
    (bucket: TaskStatusBucket, viewIds: string[]) => {
      const visibleIds = viewIds
        .map((viewId) => conversationIdByViewId.get(viewId))
        .filter((conversationId): conversationId is string => {
          return conversationId !== undefined;
        });
      const visible = new Set(visibleIds);
      const remaining = [...visibleIds];
      const conversationIds = (stored[bucket] ?? []).flatMap((id) =>
        visible.has(id) ? (remaining.length ? [remaining.shift()!] : []) : [id]
      );
      conversationIds.push(...remaining);
      localMutationGeneration.current += 1;
      setStored((current) => ({ ...current, [bucket]: conversationIds }));
      const group = groupRef.current;
      if (!group) return;
      enqueueTaskOrderWrite({
        api,
        bucket,
        conversationIds,
        groupId: group,
      });
    },
    [api, conversationIdByViewId, stored]
  );

  return { orders, setBucketOrder };
}
