import { useTaskArchive, archiveDisabledReason } from "./useTaskArchive";
import { useCommaMessages } from "@comma/i18n/react";
import { useCommaLocale } from "@comma/i18n/react";
import {
  type ProductInboxHost,
  type ProductInboxItem,
  type ProductInboxListResult,
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
  /**
   * Retains the host-owned ProductInbox projection while this surface is
   * active. A surface that stops (Home behind another page) keeps the Tasks it
   * showed and stops following them.
   */
  enabled?: boolean;
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
  /** Why the list on show is the one this device kept: its last read failed. Said once for the list, not per Task. */
  taskSyncError: string | undefined;
  tasks: TaskViewModel[];
}

export function useWorkspaceTasks({
  enabled = true,
  stationTasks: withStationTasks = false,
}: UseWorkspaceTasksOptions = {}): WorkspaceTasksState {
  const locale = useCommaLocale();
  const archive = useTaskArchive();
  const messages = useCommaMessages();
  // While disabled, every source holds the value it had when the surface was
  // last active, so nothing derived from it changes: a hidden rail does not
  // drop its cards and rebuild them, and a page switch renders none of them.
  const preference = useHeldWhileDisabled(enabled, useWorkspacePreference(enabled));
  const activeWorkspaceId = preference || undefined;
  const selectWorkspace = useSelectWorkspace();
  const [loadMoreState, setLoadMoreState] = useState<{
    error?: string;
    pending: boolean;
  }>({ pending: false });
  const projection = useProductInboxProjection({
    enabled: enabled && preference !== undefined,
    ...(activeWorkspaceId ? { workspaceId: activeWorkspaceId } : {}),
    hosted: withStationTasks,
  });
  const { refresh } = projection;
  const result = useHeldWhileDisabled(enabled, projection.result);

  useEffect(() => {
    const next = result?.activeWorkspaceId;
    if (next && next !== activeWorkspaceId) selectWorkspace(next);
  }, [activeWorkspaceId, result?.activeWorkspaceId, selectWorkspace]);

  const taskCache = useRef(new Map<string, TaskViewModel>());
  const tasks = useMemo(() => {
    if (!result) return [];
    const previous = taskCache.current;
    const next = new Map<string, TaskViewModel>();
    const list = result.items
      .filter((item) => item.kind === "agent_task" && item.status !== "archived")
      .map((item) => {
        const fresh = toTaskViewModel(item);
        fresh.archiveVersion = item.archiveVersion;
        // One the core says cannot be archived from here (a Task a station hosts) offers no archive.
        if (!item.unsupported?.includes("archive"))
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
    void refresh({ workspaceId: activeWorkspaceId }).catch(() => undefined);
  }, [activeWorkspaceId, refresh]);
  const taskLoadError =
    result?.source === "error" || result?.source === "unavailable"
      ? productInboxErrorMessage(result.errorCode, locale)
      : undefined;
  const taskSyncError =
    result?.source === "cache" && result.errorCode
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
    taskSyncError,
    tasks,
  };
}

/** `value` while `enabled`; while not, the value it had when last enabled. */
function useHeldWhileDisabled<T>(enabled: boolean, value: T): T {
  const held = useRef(value);
  if (enabled) held.current = value;
  return held.current;
}

function toTaskViewModel(item: ProductInboxItem): TaskViewModel {
  const host = item.host;
  return {
    activityStatus:
      item.status === "active" && item.meetingPhase
        ? `meeting_${item.meetingPhase}`
        : item.status,
    conversationId: item.conversationId,
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
    // A Task a station hosts: where it runs, and what runs it.
    ...(host ? { host: toTaskHost(host) } : {}),
    ...(host?.runtime === "codex" || host?.runtime === "claude"
      ? { worker: host.runtime }
      : {}),
  };
}

function toTaskHost(host: ProductInboxHost): TaskHost {
  return {
    station: host.station,
    thread: host.thread,
    machine: host.machine?.name ?? null,
    online: host.machine ? host.machine.online : null,
    model: host.model,
  };
}

function sameTaskViewModel(a: TaskViewModel, b: TaskViewModel): boolean {
  return (
    a.activityStatus === b.activityStatus &&
    a.conversationId === b.conversationId &&
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
    a.workspaceId === b.workspaceId &&
    a.worker === b.worker &&
    a.host?.machine === b.host?.machine &&
    a.host?.online === b.host?.online &&
    a.host?.model === b.host?.model
  );
}

/** Each topic value is a new object; a Loop changes when one of its facts does. */
function sameLoop(a: TaskLoop | undefined, b: TaskLoop | undefined) {
  return a === b || JSON.stringify(a) === JSON.stringify(b);
}
