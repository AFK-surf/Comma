import { useCall, useTopic, type TaskOrderValue } from "@comma/core-client";
import { messages } from "@comma/i18n";
import { toast } from "@comma/ui/components/toast";
import { type TaskStatusBucket } from "@comma/ui/components/task-workspace";
import { useCallback, useMemo, useRef, useState } from "react";

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

/**
 * Drops shown before the core's arrangement says them: while the drop's call
 * is under way, and after it until the core's arrangement next changes.
 */
type Dropped = {
  groupId: string;
  orders: Record<string, string[]>;
  /** The arrangement shown when the call settled. */
  settled?: { base: TaskOrderValue | undefined };
};

function notifyTaskOrderSaveFailed() {
  toast.error(messages.tasks_order_save_failed(), {
    id: "tasks-order-save-failed",
    testId: "tasks-order-save-failed",
  });
}

/**
 * The Group's persisted Task-board arrangement (`taskOrder`), shared by every
 * surface that renders the cards (the Tasks board and the home rail). The core
 * keeps it, writes each drop through to the Group in order and keeps a drop
 * whose save failed — the cards the user just placed must not snap back under
 * their pointer — while this says the save failed. A drop shows in the same
 * frame, until the core's arrangement after it arrives.
 */
export function useTaskOrder(
  groupId: string | undefined,
  tasks: readonly TaskOrderRef[]
): TaskOrderState {
  const call = useCall();
  const { value } = useTopic(groupId ? { topic: "taskOrder", group: groupId } : null);
  const [dropped, setDropped] = useState<Dropped | null>(null);
  const latest = useRef(value);
  latest.current = value;
  const conversationIdByViewId = useMemo(
    () => new Map(tasks.map((task) => [task.id, task.conversationId])),
    [tasks]
  );
  const viewIdByConversationId = useMemo(
    () => new Map(tasks.map((task) => [task.conversationId, task.id])),
    [tasks]
  );
  const pending =
    dropped &&
    dropped.groupId === (groupId ?? "") &&
    (!dropped.settled || dropped.settled.base === value)
      ? dropped.orders
      : undefined;
  const orders = useMemo(() => {
    const projected: Record<string, readonly string[]> = {};
    const arranged = Object.fromEntries(
      (value?.sections ?? []).map((section) => [section.bucket, section.ids])
    );
    for (const [bucket, conversationIds] of Object.entries({
      ...arranged,
      ...pending,
    })) {
      projected[bucket] = conversationIds
        .map((conversationId) => viewIdByConversationId.get(conversationId))
        .filter((viewId): viewId is string => viewId !== undefined);
    }
    return projected as TaskOrders;
  }, [pending, value, viewIdByConversationId]);

  const setBucketOrder = useCallback(
    (bucket: TaskStatusBucket, viewIds: string[]) => {
      const visible = viewIds
        .map((viewId) => conversationIdByViewId.get(viewId))
        .filter((conversationId): conversationId is string => {
          return conversationId !== undefined;
        });
      const drop: Dropped = {
        groupId: groupId ?? "",
        orders: { ...pending, [bucket]: visible },
      };
      setDropped(drop);
      if (!groupId) return;
      void call("taskOrder.set", { group: groupId, bucket, visible })
        .catch(notifyTaskOrderSaveFailed)
        .finally(() =>
          setDropped((current) =>
            current === drop ? { ...drop, settled: { base: latest.current } } : current
          )
        );
    },
    [call, conversationIdByViewId, groupId, pending]
  );

  return { orders, setBucketOrder };
}
