import { useCall, useDoing, useTopic } from "@comma/core-client";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import { LoadingIndicator } from "@comma/ui/components/LoadingIndicator";
import { ScrollAreaLoadMore } from "@comma/ui/components/scroll-area";
import { toast } from "@comma/ui/components/toast";
import { type SettingsCategoryDefinition } from "@comma/ui/components/settings";
import { useActiveWorkspace } from "../activeWorkspace";

/**
 * Settings > Shared tasks: the active public links of the Workspace's Group,
 * most recently shared first, each with a Stop sharing action. The core reads
 * one bounded page at a time (`taskShares`), as Archived tasks does.
 */
export function useSharedTasksCategory(enabled: boolean): SettingsCategoryDefinition {
  const messages = useCommaMessages(),
    locale = useCommaLocale();
  const call = useCall();
  const resolved = useActiveWorkspace(enabled);
  const workspace = resolved?.workspace?.id ?? "";
  const { value } = useTopic(
    enabled && resolved && resolved.status !== "loading"
      ? { topic: "taskShares", workspace }
      : null
  );
  const doing = useDoing("taskShare.revoke");
  const pending = doing?.stage === "running" ? doing.params.conversation : undefined;
  const groupId = value?.workspace?.group_id;
  const shares = value?.shares ?? [];
  const items: SettingsCategoryDefinition["sections"][number]["items"][number][] =
    shares.map(({ artifact_count, id, shared_at, title }) => ({
      id: `shared-task.${id}`,
      title,
      description: [
        messages.task_share_shared_on({
          date: new Date(shared_at * 1000).toLocaleString(locale),
        }),
        ...(artifact_count > 0
          ? [
              messages.task_share_file_count({
                count: artifact_count,
                formattedCount: artifact_count.toLocaleString(locale),
              }),
            ]
          : []),
      ].join(" · "),
      control: {
        type: "button",
        label:
          pending === id ? messages.task_share_stopping() : messages.task_share_stop(),
        disabled: pending !== undefined,
        onPress: () => {
          if (!groupId) return;
          // The core takes the row off every page once the link is gone.
          void call("taskShare.revoke", { group: groupId, conversation: id }).catch(
            () => {
              toast.error(messages.task_share_failed());
            }
          );
        },
      },
    }));
  if (value?.error)
    items.push({
      id: "shared-tasks.error",
      title: value.error,
      control: {
        type: "button",
        label: messages.tasks_archive_retry(),
        onPress: () =>
          void call("taskShares.refresh", { workspace }).catch(() => undefined),
      },
    });
  const more = value?.hasMore === true;
  // A later page loads as the reader scrolls to the end of the list, and shows
  // its progress there; this row covers the first page only.
  if ((value?.loading && !more) || (enabled && !value))
    items.push({
      id: "shared-tasks.loading",
      title: messages.task_share_list_loading(),
      layout: "stack",
      control: {
        type: "custom",
        content: <LoadingIndicator label={messages.task_share_list_loading()} />,
      },
    });
  if (value && !value.loading && !value.error && !shares.length && !more)
    items.push({ id: "shared-tasks.empty", title: messages.task_share_list_empty() });
  if (more && !value?.error)
    items.push({
      id: "shared-tasks.more",
      title: messages.task_share_list_loading(),
      layout: "stack",
      control: {
        type: "custom",
        content: (
          <ScrollAreaLoadMore
            hasMore
            loading={value?.loading === true}
            onLoadMore={() =>
              void call("taskShares.more", { workspace }).catch(() => undefined)
            }
          />
        ),
      },
    });
  return {
    id: "shared-tasks",
    icon: "shared-tasks",
    label: messages.settings_shared_tasks(),
    sections: [
      {
        id: "shared-tasks.list",
        title: value?.workspace?.name ?? messages.settings_shared_tasks(),
        items,
      },
    ],
  };
}
