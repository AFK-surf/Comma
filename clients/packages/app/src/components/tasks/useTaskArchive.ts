import {
  useCall,
  useTopic,
  type TaskSummariesValue,
  type TaskSummary,
} from "@comma/core-client";
import { useCommaMessages } from "@comma/i18n/react";
import { toast } from "@comma/ui/components/toast";
import { type TaskArchiveAction } from "@comma/ui/components/task-workspace/TaskArchiveMenu";
import { useCallback, useMemo, useRef } from "react";

const NONE: ReadonlyMap<string, TaskSummary> = new Map();

/**
 * The facts of Tasks a surface refers to, by id, as the core keeps them
 * (`taskSummaries`): the list's when it has them, else the account's summary
 * cache. `fetch: false` reads nothing and shows what is known. An unchanged
 * Task keeps its object.
 */
export function useTaskSummaries(
  groupId: string,
  ids: readonly string[],
  { fetch = true }: { fetch?: boolean } = {}
): ReadonlyMap<string, TaskSummary> {
  const key = [...new Set(ids.filter(Boolean))].toSorted().join(",");
  const { value } = useTopic(
    groupId && key
      ? {
          topic: "taskSummaries",
          group: groupId,
          ids: key,
          ...(fetch ? {} : { peek: "1" }),
        }
      : null
  );
  // Another set of ids is another topic: until its first value, what the
  // last one said of the same Group stands.
  const last = useRef<{ groupId: string; value: TaskSummariesValue } | null>(null);
  if (value) last.current = { groupId, value };
  const shown =
    groupId && key
      ? (value ?? (last.current?.groupId === groupId ? last.current.value : undefined))
      : undefined;
  return useMemo(
    () =>
      shown ? new Map(shown.summaries.map((summary) => [summary.id, summary])) : NONE,
    [shown]
  );
}

/** One Task's facts: the caller renders again only when they change. */
export function useTaskSummary(
  groupId: string,
  conversationId: string,
  options: { fetch?: boolean } = {}
): TaskSummary | undefined {
  return useTaskSummaries(groupId, conversationId ? [conversationId] : [], options).get(
    conversationId
  );
}

/**
 * Archives or unarchives a Task through the core (`tasks.archive`): the list
 * stops showing an archived Task at once, and the server's answer decides
 * whether it stays gone. Says how it went.
 */
export function useTaskArchive() {
  const call = useCall();
  const messages = useCommaMessages();
  return useCallback(
    async (
      task: Pick<TaskSummary, "id" | "group_id" | "updated_at">,
      action: "archive" | "unarchive"
    ) => {
      try {
        if (!task.updated_at) throw new Error(messages.tasks_archive_unavailable());
        const changed = await call("tasks.archive", {
          group: task.group_id,
          conversation: task.id,
          action,
          version: task.updated_at,
        });
        // Another change of this Task was already under way: it says how it went.
        if (!changed) return;
        toast.success(
          action === "archive"
            ? messages.tasks_archive_success()
            : messages.tasks_unarchive_success()
        );
      } catch (error) {
        toast.error(
          error instanceof Error ? error.message : messages.tasks_archive_failed()
        );
        throw error;
      }
    },
    [call, messages]
  );
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

export function useArchiveAction(group: string, id: string): TaskArchiveAction {
  const summary = useTaskSummary(group, id),
    change = useTaskArchive(),
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
