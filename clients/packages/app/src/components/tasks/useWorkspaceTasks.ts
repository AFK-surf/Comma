import { useTaskArchive, archiveDisabledReason } from "./useTaskArchive";
import { useCommaMessages } from "@comma/i18n/react";
import { useCommaLocale } from "@comma/i18n/react";
import {
  type ProductInboxItem,
  type ProductInboxListResult,
} from "@comma/native-bridge";
import { taskStatusBucket, type TaskWorkspaceTask } from "@comma/ui";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  productInboxErrorMessage,
  useProductInboxProjection,
} from "../../product-inbox";
import { taskOriginKey, type TaskOriginKey } from "./taskOrigin";
import {
  readActiveWorkspaceId,
  subscribeActiveWorkspace,
  writeActiveWorkspaceId,
} from "../activeWorkspace";
import { useCommaAuth } from "../AuthGate";
import { effectiveProductFreshness } from "../inbox/freshness";

export type TaskViewModel = TaskWorkspaceTask & {
  origin: TaskOriginKey | undefined;
  labels?: readonly string[] | undefined;
  clientPlatform?: string | undefined;
};

export interface UseWorkspaceTasksOptions {
  /** Retains the host-owned ProductInbox projection while this surface is active. */
  enabled?: boolean;
  includeTask?: { groupId: string; conversationId: string } | undefined;
}

export interface WorkspaceTasksState {
  activeGroupId: string | undefined;
  activeWorkspaceId: string | undefined;
  loadMore: () => Promise<void>;
  loadMoreState: { error?: string; pending: boolean };
  loading: boolean;
  result: ProductInboxListResult | null | undefined;
  retryTasks: () => void;
  taskLoadError: string | undefined;
  tasks: TaskViewModel[];
}

export function useWorkspaceTasks({
  enabled = true,
  includeTask,
}: UseWorkspaceTasksOptions = {}): WorkspaceTasksState {
  const locale = useCommaLocale();
  const archive = useTaskArchive();
  const messages = useCommaMessages();
  const auth = useCommaAuth();
  const [activeWorkspaceId, setActiveWorkspaceId] = useState(readActiveWorkspaceId);
  const [loadMoreState, setLoadMoreState] = useState<{
    error?: string;
    pending: boolean;
  }>({ pending: false });
  const { refresh, result } = useProductInboxProjection({
    enabled,
    session: auth.productLease,
    ...(activeWorkspaceId ? { workspaceId: activeWorkspaceId } : {}),
  });

  useEffect(() => subscribeActiveWorkspace(setActiveWorkspaceId), []);
  useEffect(() => {
    const requestedWorkspace = includeTask
      ? result?.workspaces?.find(
          (workspace) => workspace.group_id === includeTask.groupId
        )?.id
      : undefined;
    const next = requestedWorkspace ?? result?.activeWorkspaceId;
    if (next && next !== activeWorkspaceId) writeActiveWorkspaceId(next);
  }, [activeWorkspaceId, includeTask, result?.activeWorkspaceId, result?.workspaces]);

  const taskCache = useRef(new Map<string, TaskViewModel>());
  const tasks = useMemo(() => {
    if (!result) return [];
    const previous = taskCache.current;
    const next = new Map<string, TaskViewModel>();
    const list = result.items
      .filter((item) => item.kind === "agent_task" && item.status !== "archived")
      .map((item) => {
        const fresh = toTaskViewModel(item, result.source);
        fresh.archiveVersion = item.archiveVersion;
        fresh.archiveAction = {
          disabledReason: item.archiveAvailability?.allowed
            ? undefined
            : archiveDisabledReason(item.archiveAvailability?.reason, messages),
          run: () =>
            archive(
              {
                id: item.conversationId,
                group_id: item.groupId,
                updated_at: item.archiveVersion,
              },
              "archive"
            ),
        };
        const cached = previous.get(fresh.id);
        const model =
          cached &&
          cached.archiveVersion === fresh.archiveVersion &&
          sameTaskViewModel(cached, fresh) &&
          cached.archiveAction?.disabledReason === fresh.archiveAction?.disabledReason
            ? cached
            : fresh;
        next.set(model.id, model);
        return model;
      });
    taskCache.current = next;
    return list;
  }, [result, archive, messages]);
  const selectedWorkspaceId = result?.activeWorkspaceId || activeWorkspaceId;
  const activeGroupId = useMemo(
    () =>
      result?.workspaces?.find((workspace) => workspace.id === selectedWorkspaceId)
        ?.group_id ??
      tasks.find((task) => task.workspaceId === selectedWorkspaceId)?.groupId,
    [result?.workspaces, selectedWorkspaceId, tasks]
  );

  const requestedTask = useRef<string | undefined>(undefined);
  useEffect(() => {
    if (!enabled || !includeTask || !result) return;
    const targetWorkspace = result.workspaces?.find(
      (workspace) => workspace.group_id === includeTask.groupId
    );
    if (!targetWorkspace) return;
    if (targetWorkspace.id !== selectedWorkspaceId) {
      writeActiveWorkspaceId(targetWorkspace.id);
      return;
    }
    const key = `${targetWorkspace.id}:${includeTask.conversationId}`;
    if (requestedTask.current === key) return;
    requestedTask.current = key;
    // One exact owner lookup also finds an older meeting outside the first page.
    void refresh({
      workspaceId: targetWorkspace.id,
      conversationIds: [includeTask.conversationId],
    }).catch(() => undefined);
  }, [enabled, includeTask, result, selectedWorkspaceId, refresh]);

  const loadMore = useCallback(async () => {
    if (loadMoreState.pending || !result?.hasMore || !result.nextCursor) return;
    const workspaceId = result.activeWorkspaceId || activeWorkspaceId;
    if (!workspaceId) return;

    setLoadMoreState({ pending: true });
    try {
      const envelope = await refresh({
        cursor: result.nextCursor,
        limit: 50,
        workspaceId,
      });
      if (envelope.snapshot.source !== "live-sync") {
        throw new Error(productInboxErrorMessage(envelope.snapshot.errorCode, locale));
      }
      setLoadMoreState({ pending: false });
    } catch (error) {
      setLoadMoreState({ error: errorMessage(error), pending: false });
    }
  }, [activeWorkspaceId, loadMoreState.pending, locale, refresh, result]);

  const retryTasks = useCallback(() => {
    setLoadMoreState({ pending: false });
    void refresh({
      workspaceId: activeWorkspaceId,
      ...(includeTask && includeTask.groupId === activeGroupId
        ? { conversationIds: [includeTask.conversationId] }
        : {}),
    }).catch(() => undefined);
  }, [activeWorkspaceId, activeGroupId, includeTask, refresh]);
  const taskLoadError =
    result?.source === "error" || result?.source === "unavailable"
      ? productInboxErrorMessage(result.errorCode, locale)
      : undefined;

  return {
    activeGroupId,
    activeWorkspaceId,
    loadMore,
    loadMoreState,
    loading: !result,
    result,
    retryTasks,
    taskLoadError,
    tasks,
  };
}

function toTaskViewModel(
  item: ProductInboxItem,
  source: ProductInboxListResult["source"]
): TaskViewModel {
  return {
    activityStatus:
      item.status === "active" && item.meetingPhase
        ? `meeting_${item.meetingPhase}`
        : item.status,
    conversationId: item.conversationId,
    freshness: effectiveProductFreshness(item.freshness, source),
    groupId: item.groupId,
    id: item.id,
    messages: [],
    origin: taskOriginKey(item.origin),
    labels: item.labels,
    clientPlatform: item.clientPlatform,
    statusBucket: taskStatusBucket(item.status),
    title: item.title,
    updatedAt: item.updatedAt,
    workspaceId: item.workspaceId,
  };
}

function sameTaskViewModel(a: TaskViewModel, b: TaskViewModel): boolean {
  return (
    a.activityStatus === b.activityStatus &&
    a.conversationId === b.conversationId &&
    a.freshness === b.freshness &&
    a.groupId === b.groupId &&
    a.origin === b.origin &&
    a.clientPlatform === b.clientPlatform &&
    (a.labels === b.labels ||
      (a.labels !== undefined &&
        b.labels !== undefined &&
        a.labels.length === b.labels.length &&
        a.labels.every((label, index) => label === b.labels?.[index]))) &&
    a.statusBucket === b.statusBucket &&
    a.title === b.title &&
    a.updatedAt === b.updatedAt &&
    a.workspaceId === b.workspaceId
  );
}

function errorMessage(error: unknown) {
  return error instanceof Error ? error.message : String(error);
}
