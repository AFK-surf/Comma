import { useCommaMessages } from "@comma/i18n/react";
import { useCallback, useMemo, type ReactNode } from "react";
import type { CommaTaskLabel, CommaTaskLabelCatalog } from "@comma/core/api-schemas";
import type { TaskLoop } from "@comma/core/contract";
import { openNativePlatformExternalUrl } from "../../nativePlatformActions";
import { useTaskLabelsCatalog } from "../chat/tasks/labels/useTaskLabelsCatalog";
import {
  TaskLabelChip,
  TaskHostChip,
  TaskLabelOverflowChip,
  TaskPlatformChip,
  TaskPullRequestChip,
  TaskScheduleChip,
  type TaskPullRequest,
} from "./taskChips";
import { taskLoopFilterKey } from "./taskLoopLabels";
import { taskOriginKey, taskOriginLabel, type TaskOriginKey } from "./taskOrigin";
import type { TasksFilterLink } from "./taskChips";

/** Card metadata comes from the same owner projection as the task title. */
export interface TaskMeta {
  labels: readonly string[];
  clientPlatform?: string | undefined;
}

type LoadedTask = {
  conversationId: string;
  labels?: readonly string[] | undefined;
  clientPlatform?: string | undefined;
  /** Set on a coding Task that has a pull request. */
  pullRequest?: TaskPullRequest | undefined;
  /** Set on a Loop Task only. */
  loop?: TaskLoop | undefined;
  /** Set on a Task a station hosts. */
  host?: TaskHostFacts | undefined;
};

type TaskHostFacts = {
  machine: string | null;
  online: boolean | null;
  model: string | null;
};

export interface TaskBadges {
  catalog: CommaTaskLabelCatalog | undefined;
  catalogById: ReadonlyMap<string, CommaTaskLabel>;
  metaById: ReadonlyMap<string, TaskMeta>;
  renderTaskBadges: (task: {
    conversationId: string;
    origin?: string | undefined;
  }) => ReactNode;
}

/**
 * Home and Tasks read label membership directly from the shared inbox projection.
 * One Group catalog supplies names and colors, independent of the number of tasks.
 * Membership changes refresh the catalog to include newly created labels.
 */
export function useTaskBadges(
  groupId: string | undefined,
  tasks: readonly LoadedTask[],
  onOpen?: ((filter: TasksFilterLink) => void) | undefined
): TaskBadges {
  const labelIds = useMemo(
    () =>
      JSON.stringify(
        [...new Set(tasks.flatMap((task) => task.labels ?? []))].toSorted()
      ),
    [tasks]
  );
  const { catalog } = useTaskLabelsCatalog(groupId, true, labelIds);
  const catalogById = useMemo(() => {
    const byId = new Map<string, CommaTaskLabel>();
    for (const label of catalog?.labels ?? []) byId.set(label.id, label);
    return byId;
  }, [catalog]);
  const metaById = useMemo(
    () =>
      new Map(
        tasks.flatMap((task) =>
          task.labels === undefined
            ? []
            : [
                [
                  task.conversationId,
                  {
                    labels: task.labels,
                    clientPlatform: task.clientPlatform
                      ? ["macos", "windows", "linux", "ios", "android", "web"].includes(
                          task.clientPlatform
                        )
                        ? task.clientPlatform
                        : "unknown"
                      : undefined,
                  },
                ] as const,
              ]
        )
      ),
    [tasks]
  );
  const loops = useMemo(
    () =>
      new Map(
        tasks.flatMap((task) =>
          task.loop ? [[task.conversationId, task.loop] as const] : []
        )
      ),
    [tasks]
  );

  const pullRequests = useMemo(
    () =>
      new Map(
        tasks.flatMap((task) =>
          task.pullRequest ? [[task.conversationId, task.pullRequest] as const] : []
        )
      ),
    [tasks]
  );

  const hosts = useMemo(
    () =>
      new Map(
        tasks.flatMap((task) =>
          task.host ? [[task.conversationId, task.host] as const] : []
        )
      ),
    [tasks]
  );

  const renderTaskBadges = useCallback(
    (task: { conversationId: string; origin?: string | undefined }): ReactNode => {
      const host = hosts.get(task.conversationId);
      const origin = taskOriginKey(task.origin);
      const loop = loops.get(task.conversationId);
      const pullRequest = pullRequests.get(task.conversationId);
      const labels =
        metaById
          .get(task.conversationId)
          ?.labels.flatMap((id) => catalogById.get(id) ?? []) ?? [];
      // A Task a station hosts says where it runs before its labels.
      if (host)
        return (
          <>
            <TaskHostChip host={host} nested testId="task-card-host" />
            {labels.length > 0 || pullRequest ? (
              <TaskBadgeChips
                labels={labels}
                onOpen={onOpen}
                origin={undefined}
                pullRequest={pullRequest}
              />
            ) : null}
          </>
        );
      if (labels.length === 0 && !pullRequest && !origin && !loop) return null;
      return (
        <TaskBadgeChips
          labels={labels}
          loop={loop}
          onOpen={onOpen}
          origin={origin}
          pullRequest={pullRequest}
        />
      );
    },
    [catalogById, hosts, loops, metaById, onOpen, pullRequests]
  );

  return { catalog, catalogById, metaById, renderTaskBadges };
}

/**
 * The chips every Task card wears: the trigger type on a Loop Task, its labels, the
 * "+N labels" fold for squeezed list rows, its pull request, then its platform. With `onOpen`
 * each chip opens the Tasks page narrowed to it; without, they are plain (a
 * hover card).
 */
export function TaskBadgeChips({
  labels,
  loop,
  onOpen,
  origin,
  pullRequest,
}: {
  labels: readonly CommaTaskLabel[];
  /** A Loop Task: one a Loop runs or ran. */
  loop?: TaskLoop | undefined;
  onOpen?: ((filter: TasksFilterLink) => void) | undefined;
  origin: TaskOriginKey | undefined;
  /** A coding Task's pull request; with `onOpen` its chip opens it, as the other chips act. */
  pullRequest?: TaskPullRequest | undefined;
}) {
  const messages = useCommaMessages();
  // A squeezed row keeps two chips; the trigger chip takes the first place.
  const folded = labels.length - (loop ? 1 : 2);
  return (
    <>
      {loop ? (
        <TaskScheduleChip
          loop={loop}
          nested
          onOpen={
            onOpen ? () => onOpen({ schedule: taskLoopFilterKey(loop) }) : undefined
          }
          testId="task-card-schedule"
        />
      ) : null}
      {labels.map((label) => (
        <TaskLabelChip
          color={label.color}
          key={label.id}
          name={label.name}
          nested
          onOpen={onOpen ? () => onOpen({ label: label.id }) : undefined}
          testId="task-card-label"
        />
      ))}
      {folded > 0 ? <TaskLabelOverflowChip count={folded} /> : null}
      {pullRequest ? (
        <TaskPullRequestChip
          nested
          onOpen={
            onOpen
              ? () => void openNativePlatformExternalUrl(pullRequest.url)
              : undefined
          }
          pullRequest={pullRequest}
        />
      ) : null}
      {origin ? (
        <TaskPlatformChip
          label={taskOriginLabel(messages, origin)}
          nested
          onOpen={onOpen ? () => onOpen({ platform: origin }) : undefined}
          origin={origin}
          testId="task-card-platform"
        />
      ) : null}
    </>
  );
}
