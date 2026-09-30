import { useCommaMessages } from "@comma/i18n/react";
import { useCallback, useMemo, type ReactNode } from "react";
import type { CommaApiClient, CommaTaskLabel, CommaTaskLabelCatalog } from "../../api";
import { useTaskLabelsCatalog } from "../chat/tasks/labels/useTaskLabelsCatalog";
import { TaskLabelChip, TaskLabelOverflowChip, TaskPlatformChip } from "./taskChips";
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
  api: CommaApiClient,
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
  const { catalog } = useTaskLabelsCatalog(api, groupId, true, labelIds);
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

  const renderTaskBadges = useCallback(
    (task: { conversationId: string; origin?: string | undefined }): ReactNode => {
      const origin = taskOriginKey(task.origin);
      const labels =
        metaById
          .get(task.conversationId)
          ?.labels.flatMap((id) => catalogById.get(id) ?? []) ?? [];
      if (labels.length === 0 && !origin) return null;
      return <TaskBadgeChips labels={labels} onOpen={onOpen} origin={origin} />;
    },
    [catalogById, metaById, onOpen]
  );

  return { catalog, catalogById, metaById, renderTaskBadges };
}

/**
 * The chips every Task card wears: its labels, then its platform, then the
 * "+N labels" fold for squeezed list rows. With `onOpen` each chip opens the
 * Tasks page narrowed to it; without, they are plain (a hover card).
 */
export function TaskBadgeChips({
  labels,
  onOpen,
  origin,
}: {
  labels: readonly CommaTaskLabel[];
  onOpen?: ((filter: TasksFilterLink) => void) | undefined;
  origin: TaskOriginKey | undefined;
}) {
  const messages = useCommaMessages();
  return (
    <>
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
      {labels.length > 2 ? <TaskLabelOverflowChip count={labels.length - 2} /> : null}
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
