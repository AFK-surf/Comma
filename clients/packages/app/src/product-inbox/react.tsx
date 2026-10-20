import type { ManualTaskStatus } from "@comma/chat-contract";
import {
  useCall,
  useTopic,
  useTopicSelect,
  type ProductInboxListResult,
} from "@comma/core-client";
import { useCallback, useEffect, useRef } from "react";
import { productInboxUnavailableResult } from "./messages";

/**
 * A workspace's tasks and chats, as the client core keeps them (`tasks`): shown
 * from the device at once and kept current while shown. `workspaceId` also
 * becomes the core's focus, which `useProductInboxSnapshot` and the other
 * readers without a workspace follow.
 */
export type ProductInboxRefresh = {
  conversationIds?: string[] | undefined;
  /** Reads the next page (the list's own cursor). */
  cursor?: string | undefined;
  workspaceId?: string | undefined;
};

export function useProductInboxProjection(input: {
  enabled: boolean;
  workspaceId?: string | undefined;
}) {
  const call = useCall();
  const workspace = input.workspaceId ?? "";
  const { error, value } = useTopic(
    input.enabled ? { topic: "tasks", workspace } : null
  );

  useEffect(() => {
    if (input.enabled && input.workspaceId)
      void call("tasks.focus", { workspace: input.workspaceId }).catch(() => undefined);
  }, [call, input.enabled, input.workspaceId]);

  // Following the focus ("") and then naming the workspace it showed is the
  // same list: keep showing it until the named topic's first value arrives.
  const last = useRef<ProductInboxListResult | null>(null);
  const kept = last.current;
  if (value && !error) last.current = value;
  const result = error
    ? // The core could not keep the list (it is not running): say so, not loading.
      productInboxUnavailableResult("utility_unavailable")
    : (value ??
      (input.enabled && workspace && kept?.activeWorkspaceId === workspace
        ? kept
        : null));

  const refresh = useProductInboxRefresh();
  return { refresh, result };
}

/**
 * Asks the core to read a list again now (`conversationIds`: those tasks
 * exactly), or its next page (`cursor`). A failed next page rejects with the
 * list's error code.
 */
export function useProductInboxRefresh() {
  const call = useCall();
  return useCallback(
    async (input: ProductInboxRefresh = {}) => {
      const workspace = input.workspaceId ? { workspace: input.workspaceId } : {};
      if (input.cursor) await call("tasks.more", workspace);
      else
        await call("tasks.refresh", {
          ...workspace,
          ...(input.conversationIds ? { conversations: input.conversationIds } : {}),
        });
    },
    [call]
  );
}

export type ProductInboxArchiveIntent = {
  conversationId: string;
  groupId: string;
  /** The Task version the decision was taken against: a later one ends it. */
  version?: number | undefined;
};

/** A staged decision's handle: `confirm` keeps it until the server shows it, `rollback` drops it. */
export type ProductInboxArchiveStage = {
  confirm(): void;
  rollback(): void;
};

export type ProductInboxStatusIntent = ProductInboxArchiveIntent & {
  status: ManualTaskStatus;
};

function useStage() {
  const call = useCall();
  return useCallback(
    (input: ProductInboxArchiveIntent, status: string): ProductInboxArchiveStage => {
      const staged = call("tasks.stage", {
        conversationId: input.conversationId,
        groupId: input.groupId,
        status,
        ...(input.version === undefined ? {} : { version: input.version }),
      });
      // A stage the core could not make (or no core) has nothing to settle; it
      // fails quietly whether or not the caller settles it.
      staged.catch(() => undefined);
      const settle = (accepted: boolean) =>
        void staged
          .then(({ stage }) => call("tasks.stage.settle", { accepted, stage }))
          .catch(() => undefined);
      return { confirm: () => settle(true), rollback: () => settle(false) };
    },
    [call]
  );
}

/** Shows a status the user just chose by hand on every list at once. */
export function useStageTaskStatus() {
  const stage = useStage();
  return useCallback(
    (input: ProductInboxStatusIntent) => stage(input, input.status),
    [stage]
  );
}

/** One Task of the focused list: the caller renders again only when that Task changes. */
export function useProductInboxItem(groupId: string, conversationId: string) {
  return useTopicSelect({ topic: "tasks", workspace: "" }, (value) =>
    value?.items.find(
      (item) => item.groupId === groupId && item.conversationId === conversationId
    )
  );
}

/** The focused list, without asking for a workspace. */
export function useProductInboxSnapshot(): ProductInboxListResult | null {
  return useTopic({ topic: "tasks", workspace: "" }).value ?? null;
}
