import { useTaskArchive, archiveDisabledReason } from "./useTaskArchive";
import { useCommaMessages } from "@comma/i18n/react";
import { useCommaLocale } from "@comma/i18n/react";
import {
  useTopic,
  type ProductInboxItem,
  type ProductInboxListResult,
  type StationTask,
  type TaskLoop,
} from "@comma/core-client";
import {
  taskStatusBucket,
  type TaskWorkspaceTask,
} from "@comma/ui/components/task-workspace";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  productInboxErrorMessage,
  useProductInboxProjection,
} from "../../product-inbox";
import { taskOriginKey, type TaskOriginKey } from "./taskOrigin";
import { useSelectWorkspace, useWorkspacePreference } from "../activeWorkspace";
import { effectiveProductFreshness } from "../inbox/freshness";

/** Where a Task a station hosts runs (a station's own chat, listed from the Task index). */
export interface TaskHost {
  station: string;
  thread: string;
  /** The machine's name, where this device knows it; null else. */
  machine: string | null;
  /** Whether the machine is online, where this device knows it. */
  online: boolean | null;
  model: string | null;
}

export type TaskViewModel = TaskWorkspaceTask & {
  origin: TaskOriginKey | undefined;
  /** Set on a Task a station hosts. */
  host?: TaskHost | undefined;
  labels?: readonly string[] | undefined;
  clientPlatform?: string | undefined;
  /** Set on a Loop Task only: its cards wear the Loops chip. */
  loop?: TaskLoop | undefined;
};

export interface UseWorkspaceTasksOptions {
  /** Retains the host-owned ProductInbox projection while this surface is active. */
  enabled?: boolean;
  includeTask?: { groupId: string; conversationId: string } | undefined;
  /** Lists the Tasks the workspace's stations host too (the Tasks page and Home's rail open them). */
  stationTasks?: boolean;
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
  stationTasks: withStationTasks = false,
}: UseWorkspaceTasksOptions = {}): WorkspaceTasksState {
  const locale = useCommaLocale();
  const archive = useTaskArchive();
  const messages = useCommaMessages();
  const preference = useWorkspacePreference(enabled);
  const activeWorkspaceId = preference || undefined;
  const selectWorkspace = useSelectWorkspace();
  const [loadMoreState, setLoadMoreState] = useState<{
    error?: string;
    pending: boolean;
  }>({ pending: false });
  const { refresh, result } = useProductInboxProjection({
    enabled: enabled && preference !== undefined,
    ...(activeWorkspaceId ? { workspaceId: activeWorkspaceId } : {}),
  });

  useEffect(() => {
    const requestedWorkspace = includeTask
      ? result?.workspaces?.find(
          (workspace) => workspace.group_id === includeTask.groupId
        )?.id
      : undefined;
    const next = requestedWorkspace ?? result?.activeWorkspaceId;
    if (next && next !== activeWorkspaceId) selectWorkspace(next);
  }, [
    activeWorkspaceId,
    includeTask,
    result?.activeWorkspaceId,
    result?.workspaces,
    selectWorkspace,
  ]);

  // The Tasks the workspace's stations host, listed beside those Salix keeps.
  const listedWorkspaceId = result?.activeWorkspaceId || activeWorkspaceId;
  const stationTasks = useTopic(
    enabled && withStationTasks && listedWorkspaceId
      ? { topic: "stationTasks", workspace: listedWorkspaceId }
      : null
  ).value;
  const taskCache = useRef(new Map<string, TaskViewModel>());
  const salixTasks = useMemo(() => {
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
      salixTasks.find((task) => task.workspaceId === selectedWorkspaceId)?.groupId,
    [result?.workspaces, selectedWorkspaceId, salixTasks]
  );
  const tasks = useMemo(() => {
    if (!result || !selectedWorkspaceId || !stationTasks) return salixTasks;
    const hosted = stationTasks.tasks
      .filter((task) => task.status !== "archived")
      .map((task) =>
        toStationTaskViewModel(
          task,
          selectedWorkspaceId,
          activeGroupId ?? "",
          stationTasks
        )
      );
    return hosted.length === 0 ? salixTasks : [...salixTasks, ...hosted];
  }, [activeGroupId, result, salixTasks, selectedWorkspaceId, stationTasks]);

  const requestedTask = useRef<string | undefined>(undefined);
  useEffect(() => {
    if (!enabled || !includeTask || !result) return;
    const targetWorkspace = result.workspaces?.find(
      (workspace) => workspace.group_id === includeTask.groupId
    );
    if (!targetWorkspace) return;
    if (targetWorkspace.id !== selectedWorkspaceId) {
      selectWorkspace(targetWorkspace.id);
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
  }, [enabled, includeTask, result, selectedWorkspaceId, refresh, selectWorkspace]);

  const loadMore = useCallback(async () => {
    if (loadMoreState.pending || !result?.hasMore || !result.nextCursor) return;
    const workspaceId = result.activeWorkspaceId || activeWorkspaceId;
    if (!workspaceId) return;

    setLoadMoreState({ pending: true });
    try {
      await refresh({
        cursor: result.nextCursor,
        workspaceId,
      });
      setLoadMoreState({ pending: false });
    } catch (error) {
      // The core says why with the list's own error code.
      setLoadMoreState({
        error: productInboxErrorMessage((error as { code?: string }).code, locale),
        pending: false,
      });
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
    loop: item.loop,
    statusBucket: taskStatusBucket(item.status),
    title: item.title,
    updatedAt: item.updatedAt,
    workspaceId: item.workspaceId,
  };
}

function toStationTaskViewModel(
  task: StationTask,
  workspaceId: string,
  groupId: string,
  list: { state: string; failed?: boolean | undefined }
): TaskViewModel {
  return {
    activityStatus: task.status,
    // A station's Task has no Salix conversation: its id stands in, and opening it goes to the station.
    conversationId: task.id,
    freshness: list.state === "ready" && !list.failed ? "fresh" : "stale",
    groupId,
    host: {
      station: task.station,
      thread: task.thread,
      machine: task.machine?.name ?? null,
      online: task.machine ? task.machine.online : null,
      model: task.model,
    },
    id: task.id,
    labels: task.labels,
    messages: [],
    origin: undefined,
    statusBucket: taskStatusBucket(task.status),
    title: task.title ?? "",
    updatedAt: task.lastActivityAt ?? task.createdAt ?? 0,
    workspaceId,
    ...(task.runtime === "codex" || task.runtime === "claude"
      ? { worker: task.runtime }
      : {}),
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
    sameLoop(a.loop, b.loop) &&
    a.statusBucket === b.statusBucket &&
    a.title === b.title &&
    a.updatedAt === b.updatedAt &&
    a.workspaceId === b.workspaceId
  );
}

/** Each topic value is a new object; a Loop changes when one of its facts does. */
function sameLoop(a: TaskLoop | undefined, b: TaskLoop | undefined) {
  return a === b || JSON.stringify(a) === JSON.stringify(b);
}
