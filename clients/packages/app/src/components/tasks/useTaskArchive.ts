import { useCallback, useEffect, useMemo, useSyncExternalStore } from "react";
import { useCommaMessages } from "@comma/i18n/react";
import { toast, type TaskArchiveAction } from "@comma/ui";
import type { CommaApiClient, CommaConversation } from "../../api";
import { CommaApiError } from "../../api";
import {
  useProductInboxActiveWorkspaceId,
  useProductInboxItem,
  useProductInboxOwnerReads,
  useProductInboxRefresh,
  useStageTaskArchived,
} from "../../product-inbox";
import { useChatApi } from "../chat/ChatProvider";
import {
  observeTaskProjection,
  invalidateTaskSummaries,
  readTaskSummary,
  recordTaskSummary,
  requestTaskSummary,
  subscribeTaskSummaries,
} from "./taskArchiveState";

/**
 * Each owner read revalidates the session's cached Task facts. The owner's
 * page says nothing about Tasks outside it, so a read that leaves the page
 * unchanged can still find one of them archived.
 */
export function useTaskFactsRevalidation(api: CommaApiClient | undefined) {
  const observe = useCallback(
    (snapshot: object) => {
      if (api) observeTaskProjection(api, snapshot);
    },
    [api]
  );
  useProductInboxOwnerReads(observe);
}

/**
 * One Task's facts, from its projected item or the session's summary cache,
 * whichever is newer. The caller renders again only when this Task's facts
 * change: another Task's update or an owner read that leaves them as they are
 * returns the same object.
 */
export function useTaskSummary(
  api: CommaApiClient | undefined,
  groupId: string,
  conversationId: string,
  { fetch = true }: { fetch?: boolean } = {}
) {
  const live = useProductInboxItem(groupId, conversationId);
  useTaskFactsRevalidation(api);
  const liveSummary = useMemo(
    () =>
      live &&
      ({
        id: live.conversationId,
        group_id: live.groupId,
        kind: live.kind,
        status: live.status,
        title: live.title,
        updated_at: live.archiveVersion,
        archive_availability: live.archiveAvailability,
        labels: live.labels,
        origin: live.origin,
        client_platform: live.clientPlatform,
      } satisfies CommaConversation),
    [live]
  );
  const summary = useSyncExternalStore(
    useCallback(
      (listener: () => void) =>
        api ? subscribeTaskSummaries(api, listener) : () => {},
      [api]
    ),
    () => {
      const value = api ? readTaskSummary(api, groupId, conversationId) : undefined;
      return liveSummary &&
        (!value || (liveSummary.updated_at ?? 0) >= (value.updated_at ?? 0))
        ? liveSummary
        : value;
    },
    () => liveSummary
  );
  useEffect(() => {
    if (api && liveSummary?.updated_at) recordTaskSummary(api, liveSummary);
  }, [api, liveSummary]);
  useEffect(() => {
    if (!fetch || !api || !groupId || !conversationId || live?.archiveVersion)
      return undefined;
    const request = () => requestTaskSummary(api, groupId, conversationId);
    request();
    // An owner read marks cached facts stale without rendering this reader;
    // ask again once it has.
    return subscribeTaskSummaries(api, request);
  }, [api, groupId, conversationId, live, fetch]);
  return summary;
}

const pending = new WeakMap<CommaApiClient, Set<string>>();
export function useTaskArchive() {
  return useTaskArchiveForApi(useChatApi());
}
export function useTaskArchiveForApi(api: CommaApiClient | undefined) {
  const messages = useCommaMessages();
  const refresh = useProductInboxRefresh();
  const stage = useStageTaskArchived();
  const activeWorkspaceId = useProductInboxActiveWorkspaceId();
  const change = useCallback(
    async (
      task: Pick<CommaConversation, "id" | "group_id" | "updated_at">,
      action: "archive" | "unarchive"
    ) => {
      if (!api) throw new Error(messages.tasks_archive_unavailable());
      let requests = pending.get(api);
      if (!requests) {
        requests = new Set();
        pending.set(api, requests);
      }
      const key = `${task.group_id}:${task.id}`;
      if (requests.has(key)) return;
      requests.add(key);
      try {
        if (!task.updated_at) throw new Error(messages.tasks_archive_unavailable());
        // The user has already decided, so the list stops showing the Task now
        // and the request only decides whether it stays gone. Every surface
        // reads the same projection, so one staged decision serves them all.
        const staged =
          action === "archive"
            ? stage({
                conversationId: task.id,
                groupId: task.group_id,
                version: task.updated_at,
              })
            : undefined;
        let committed: CommaConversation;
        try {
          committed = await api.setTaskArchived(
            task.group_id,
            task.id,
            action,
            task.updated_at
          );
        } catch (error) {
          staged?.rollback();
          throw error;
        }
        staged?.confirm();
        invalidateTaskSummaries(api);
        recordTaskSummary(api, committed);
        toast.success(
          action === "archive"
            ? messages.tasks_archive_success()
            : messages.tasks_unarchive_success()
        );
        // Reconciliation, not what removes the Task: the owner rereads this
        // Task and the projection carries the served fact from here on.
        void refresh({
          conversationIds: [task.id],
          ...(activeWorkspaceId ? { workspaceId: activeWorkspaceId } : {}),
        }).catch(() => undefined);
      } catch (error) {
        if (error instanceof CommaApiError && error.status === 409) {
          invalidateTaskSummaries(api);
          void refresh({
            conversationIds: [task.id],
            ...(activeWorkspaceId ? { workspaceId: activeWorkspaceId } : {}),
          }).catch(() => undefined);
        }
        toast.error(
          error instanceof Error ? error.message : messages.tasks_archive_failed()
        );
        throw error;
      } finally {
        requests.delete(key);
      }
    },
    [api, refresh, stage, messages, activeWorkspaceId]
  );
  return change;
}

export function archiveDisabledReason(
  reason: string | null | undefined,
  messages: ReturnType<typeof useCommaMessages>
): string {
  switch (reason) {
    case "not_finished":
      return messages.tasks_archive_not_finished();
    case "schedule_bound":
      return messages.tasks_archive_schedule_bound();
    default:
      return messages.tasks_archive_unavailable();
  }
}
export function useArchiveAction(
  api: CommaApiClient | undefined,
  group: string,
  id: string
): TaskArchiveAction {
  const summary = useTaskSummary(api, group, id),
    change = useTaskArchiveForApi(api),
    messages = useCommaMessages();
  return useMemo(
    () => ({
      disabledReason: summary?.archive_availability?.allowed
        ? undefined
        : archiveDisabledReason(summary?.archive_availability?.reason, messages),
      run: async () => {
        if (summary) await change(summary, "archive");
      },
    }),
    [change, messages, summary]
  );
}
