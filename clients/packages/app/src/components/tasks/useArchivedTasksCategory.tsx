import { useCall, useDoing, useTopic } from "@comma/core-client";
import { LoadingIndicator } from "@comma/ui/components/LoadingIndicator";
import { ScrollAreaLoadMore } from "@comma/ui/components/scroll-area";
import { taskActivityLabel } from "@comma/i18n";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import { type SettingsCategoryDefinition } from "@comma/ui/components/settings";
import { useActiveWorkspace } from "../activeWorkspace";
import { useTaskArchive } from "./useTaskArchive";

/**
 * Settings > Archived tasks: the archived Tasks of the active Workspace, as
 * the core reads them a page at a time (`archivedTasks`), each with Unarchive.
 */
export function useArchivedTasksCategory(enabled: boolean): SettingsCategoryDefinition {
  const messages = useCommaMessages(),
    locale = useCommaLocale();
  const call = useCall();
  const resolved = useActiveWorkspace(enabled);
  const workspace = resolved?.workspace?.id ?? "";
  const { value } = useTopic(
    enabled && resolved && resolved.status !== "loading"
      ? { topic: "archivedTasks", workspace }
      : null
  );
  const change = useTaskArchive();
  const doing = useDoing("tasks.archive", { action: "unarchive" });
  const pending = doing?.stage === "running" ? doing.params.conversation : undefined;
  const tasks = value?.tasks ?? [];
  const items: SettingsCategoryDefinition["sections"][number]["items"][number][] =
    tasks.map((task) => ({
      id: `archived-task.${task.id}`,
      title: task.title,
      description: `${messages.tasks_archive_previous_status({ status: taskActivityLabel(task.archived_from_status ?? "unknown", locale) ?? task.archived_from_status ?? "—" })} · ${new Date(task.archived_at ?? 0).toLocaleString(locale)}`,
      control: {
        type: "button",
        label:
          pending === task.id
            ? messages.tasks_unarchiving()
            : messages.tasks_unarchive(),
        disabled: pending !== undefined,
        // The core takes the Task off this list once the server unarchived it.
        onPress: () => void change(task, "unarchive").catch(() => undefined),
      },
    }));
  if (value?.error)
    items.push({
      id: "archived-tasks.error",
      title: value.error,
      control: {
        type: "button",
        label: messages.tasks_archive_retry(),
        onPress: () =>
          void call("archivedTasks.refresh", { workspace }).catch(() => undefined),
      },
    });
  const more = value?.hasMore === true;
  // A later page loads as the reader scrolls to the end of the list, and shows
  // its progress there; this row covers the first page only.
  if ((value?.loading && !more) || (enabled && !value))
    items.push({
      id: "archived-tasks.loading",
      title: messages.tasks_archive_loading(),
      layout: "stack",
      control: {
        type: "custom",
        content: <LoadingIndicator label={messages.tasks_archive_loading()} />,
      },
    });
  if (value && !value.loading && !value.error && !tasks.length && !more)
    items.push({ id: "archived-tasks.empty", title: messages.tasks_archived_empty() });
  if (more && !value?.error)
    items.push({
      id: "archived-tasks.more",
      title: messages.tasks_archive_loading(),
      layout: "stack",
      control: {
        type: "custom",
        content: (
          <ScrollAreaLoadMore
            hasMore
            loading={value?.loading === true}
            onLoadMore={() =>
              void call("archivedTasks.more", { workspace }).catch(() => undefined)
            }
          />
        ),
      },
    });
  return {
    id: "archived-tasks",
    icon: "archived-tasks",
    label: messages.settings_archived_tasks(),
    sections: [
      {
        id: "archived-tasks.list",
        title: value?.workspace?.name ?? messages.settings_archived_tasks(),
        items,
      },
    ],
  };
}
