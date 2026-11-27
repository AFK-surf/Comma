import { useCall, useDoing, useTopic, type SharedDocument } from "@comma/core-client";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import { LoadingIndicator } from "@comma/ui/components/LoadingIndicator";
import { ScrollAreaLoadMore } from "@comma/ui/components/scroll-area";
import { toast } from "@comma/ui/components/toast";
import { type SettingsCategoryDefinition } from "@comma/ui/components/settings";
import { useCallback, useEffect, useState } from "react";
import { useActiveWorkspace } from "../activeWorkspace";

type SettingsItem = SettingsCategoryDefinition["sections"][number]["items"][number];

type SharedDocuments = {
  group: string;
  shares: SharedDocument[];
  /** Where the next page starts; null at the list's end. */
  cursor: string | null;
  status: "loading" | "ready" | "failed";
  /** The document whose link is being stopped: its Task and file name. */
  stopping?: string | undefined;
};

const documentKey = (share: Pick<SharedDocument, "conversation" | "fileName">) =>
  `${share.conversation}\u0000${share.fileName}`;

/**
 * The Group's active document links, most recently shared first: one page of at most 50 when the section shows,
 * and the next as the reader reaches the list's end. The list is this section's own: a link stopped here leaves it.
 */
function useSharedDocuments(group: string | undefined) {
  const call = useCall();
  const [list, setList] = useState<SharedDocuments>();
  const load = useCallback(
    async (cursor?: string) => {
      if (!group) return;
      setList((current) => ({
        group,
        shares: cursor && current?.group === group ? current.shares : [],
        cursor: null,
        status: "loading",
      }));
      try {
        const { shares, cursor: next } = await call("documentShares.list", {
          group,
          ...(cursor ? { cursor } : {}),
        });
        setList((current) =>
          current?.group === group
            ? {
                group,
                shares: cursor ? [...current.shares, ...shares] : shares,
                cursor: next,
                status: "ready",
              }
            : current
        );
      } catch {
        setList((current) =>
          current?.group === group
            ? { ...current, cursor: cursor ?? null, status: "failed" }
            : current
        );
      }
    },
    [call, group]
  );
  useEffect(() => {
    void load();
  }, [load]);
  const stop = useCallback(
    async (share: SharedDocument) => {
      if (!group) return false;
      const key = documentKey(share);
      setList((current) => (current ? { ...current, stopping: key } : current));
      try {
        await call("documentShare.revoke", {
          group,
          conversation: share.conversation,
          fileName: share.fileName,
        });
        setList((current) =>
          current
            ? {
                ...current,
                stopping: undefined,
                shares: current.shares.filter((one) => documentKey(one) !== key),
              }
            : current
        );
        return true;
      } catch {
        setList((current) => (current ? { ...current, stopping: undefined } : current));
        return false;
      }
    },
    [call, group]
  );
  return { list: list?.group === group ? list : undefined, load, stop };
}

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
  const documents = useSharedDocuments(enabled ? groupId : undefined);
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
  // The documents with a link of their own: each is one file of a Task, shared apart from the Task.
  const shown = documents.list;
  const documentItems: SettingsItem[] = (shown?.shares ?? []).map((share) => ({
    id: `shared-document.${documentKey(share)}`,
    title: share.fileName,
    description: [
      messages.document_share_in_task({ task: share.task }),
      messages.task_share_shared_on({
        date: new Date(share.shared_at * 1000).toLocaleString(locale),
      }),
    ].join(" · "),
    control: {
      type: "button",
      label:
        shown?.stopping === documentKey(share)
          ? messages.task_share_stopping()
          : messages.task_share_stop(),
      disabled: shown?.stopping !== undefined,
      onPress: () =>
        void documents.stop(share).then((stopped) => {
          if (!stopped) toast.error(messages.task_share_failed());
        }),
    },
  }));
  if (shown?.status === "failed")
    documentItems.push({
      id: "shared-documents.error",
      title: messages.task_share_load_failed(),
      control: {
        type: "button",
        label: messages.tasks_archive_retry(),
        onPress: () => void documents.load(shown.cursor ?? undefined),
      },
    });
  if (groupId && (!shown || (shown.status === "loading" && !shown.shares.length)))
    documentItems.push({
      id: "shared-documents.loading",
      title: messages.common_loading(),
      layout: "stack",
      control: {
        type: "custom",
        content: <LoadingIndicator label={messages.common_loading()} />,
      },
    });
  if (shown?.status === "ready" && !shown.shares.length)
    documentItems.push({
      id: "shared-documents.empty",
      title: messages.document_share_list_empty(),
    });
  if (shown && shown.status !== "failed" && shown.shares.length > 0 && shown.cursor)
    documentItems.push({
      id: "shared-documents.more",
      title: messages.common_loading(),
      layout: "stack",
      control: {
        type: "custom",
        content: (
          <ScrollAreaLoadMore
            hasMore
            loading={shown.status === "loading"}
            onLoadMore={() => void documents.load(shown.cursor ?? undefined)}
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
      {
        id: "shared-documents.list",
        title: messages.document_share_section(),
        items: documentItems,
      },
    ],
  };
}
