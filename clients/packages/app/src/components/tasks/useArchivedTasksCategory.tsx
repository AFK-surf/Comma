import { LoadingIndicator, ScrollAreaLoadMore } from "@comma/ui";
import { useCallback, useEffect, useRef, useState } from "react";
import { taskActivityLabel } from "@comma/i18n";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import { type SettingsCategoryDefinition } from "@comma/ui";
import type { CommaApiClient, CommaConversation } from "../../api";
import { useCommaAuth } from "../AuthGate";
import { useProductInboxProjection } from "../../product-inbox";
import { readActiveWorkspaceId, subscribeActiveWorkspace } from "../activeWorkspace";
import { useTaskArchiveForApi } from "./useTaskArchive";

export function useArchivedTasksCategory(
  api: CommaApiClient,
  enabled: boolean
): SettingsCategoryDefinition {
  const messages = useCommaMessages(),
    locale = useCommaLocale(),
    auth = useCommaAuth();
  const [workspaceId, setWorkspaceId] = useState(readActiveWorkspaceId);
  useEffect(() => subscribeActiveWorkspace(setWorkspaceId), []);
  const { result } = useProductInboxProjection({
    enabled,
    session: auth.productLease,
    ...(workspaceId ? { workspaceId } : {}),
  });
  const workspace = result?.workspaces?.find(
    (w) => w.id === (workspaceId ?? result?.activeWorkspaceId)
  );
  const groupId = workspace?.group_id;
  const [page, setPage] = useState<{
    group?: string;
    tasks: CommaConversation[];
    cursor?: string;
    more: boolean;
  }>({ tasks: [], more: false });
  const [loading, setLoading] = useState(false),
    [error, setError] = useState<string>();
  const [pending, setPending] = useState<string>();
  const generation = useRef(0);
  const change = useTaskArchiveForApi(api);
  const load = useCallback(
    async (cursor?: string) => {
      if (!groupId) return;
      const request = ++generation.current;
      setLoading(true);
      setError(undefined);
      try {
        const next = await api.listConversationPage(groupId, {
          archive: "only",
          limit: 50,
          ...(cursor ? { cursor } : {}),
        });
        if (request !== generation.current) return;
        setPage((previous) => ({
          group: groupId,
          tasks:
            cursor && previous.group === groupId
              ? [...previous.tasks, ...next.data].filter(
                  (v, i, a) => a.findIndex((x) => x.id === v.id) === i
                )
              : next.data,
          more: next.hasMore,
          ...(next.nextCursor ? { cursor: next.nextCursor } : {}),
        }));
      } catch (failure) {
        if (request === generation.current)
          setError(failure instanceof Error ? failure.message : String(failure));
      } finally {
        if (request === generation.current) setLoading(false);
      }
    },
    [api, groupId]
  );
  const invalidate = useCallback(() => {
    generation.current++;
  }, []);
  useEffect(() => {
    if (enabled) void load();
    return invalidate;
  }, [enabled, load, invalidate]);
  const tasks = page.group === groupId ? page.tasks : [];
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
        onPress: () => {
          setPending(task.id);
          const current = generation.current;
          void change(task, "unarchive")
            .then(() => {
              if (current === generation.current)
                setPage((previous) => ({
                  ...previous,
                  tasks: previous.tasks.filter((item) => item.id !== task.id),
                }));
            })
            .catch(() => undefined)
            .finally(() => setPending(undefined));
        },
      },
    }));
  if (error)
    items.push({
      id: "archived-tasks.error",
      title: error,
      control: {
        type: "button",
        label: messages.tasks_archive_retry(),
        onPress: () => void load(),
      },
    });
  const more = page.group === groupId && page.more;
  // A later page loads as the reader scrolls to the end of the list, and shows
  // its progress there; this row covers the first page only.
  if ((loading && !more) || (enabled && !result))
    items.push({
      id: "archived-tasks.loading",
      title: messages.tasks_archive_loading(),
      layout: "stack",
      control: {
        type: "custom",
        content: <LoadingIndicator label={messages.tasks_archive_loading()} />,
      },
    });
  if (result && !loading && !error && !tasks.length && !more)
    items.push({ id: "archived-tasks.empty", title: messages.tasks_archived_empty() });
  if (more && !error)
    items.push({
      id: "archived-tasks.more",
      title: messages.tasks_archive_loading(),
      layout: "stack",
      control: {
        type: "custom",
        content: (
          <ScrollAreaLoadMore
            hasMore
            loading={loading}
            onLoadMore={() => void load(page.cursor)}
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
        title: workspace?.name ?? messages.settings_archived_tasks(),
        items,
      },
    ],
  };
}
