import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import {
  LoadingIndicator,
  ScrollAreaLoadMore,
  toast,
  type SettingsCategoryDefinition,
} from "@comma/ui";
import { useCallback, useEffect, useRef, useState } from "react";
import type { CommaApiClient, CommaTaskShareEntry } from "../../api";
import { useCommaAuth } from "../AuthGate";
import { useProductInboxProjection } from "../../product-inbox";
import { readActiveWorkspaceId, subscribeActiveWorkspace } from "../activeWorkspace";

/**
 * Settings > Shared tasks: the active public links of the Workspace's Group,
 * most recently shared first, each with a Stop sharing action. It reads one
 * bounded page at a time, as Archived tasks does.
 */
export function useSharedTasksCategory(
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
    shares: CommaTaskShareEntry[];
    cursor?: string;
    more: boolean;
  }>({ shares: [], more: false });
  const [loading, setLoading] = useState(false),
    [error, setError] = useState<string>();
  const [pending, setPending] = useState<string>();
  const generation = useRef(0);
  const load = useCallback(
    async (cursor?: string) => {
      if (!groupId) return;
      const request = ++generation.current;
      setLoading(true);
      setError(undefined);
      try {
        const next = await api.listTaskShares(groupId, cursor ? { cursor } : {});
        if (request !== generation.current) return;
        setPage((previous) => ({
          group: groupId,
          shares:
            cursor && previous.group === groupId
              ? [...previous.shares, ...next.data].filter(
                  (v, i, a) =>
                    a.findIndex((x) => x.conversation.id === v.conversation.id) === i
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
  const shares = page.group === groupId ? page.shares : [];
  const items: SettingsCategoryDefinition["sections"][number]["items"][number][] =
    shares.map(({ artifact_count, conversation, shared_at }) => ({
      id: `shared-task.${conversation.id}`,
      title: conversation.title,
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
          pending === conversation.id
            ? messages.task_share_stopping()
            : messages.task_share_stop(),
        disabled: pending !== undefined,
        onPress: () => {
          if (!groupId) return;
          setPending(conversation.id);
          // A page load may start while the link stops; the row leaves the
          // list regardless, since its link is gone from every page.
          void api
            .revokeTaskShare(groupId, conversation.id)
            .then(() => {
              setPage((previous) => ({
                ...previous,
                shares: previous.shares.filter(
                  (item) => item.conversation.id !== conversation.id
                ),
              }));
            })
            .catch(() => {
              toast.error(messages.task_share_failed());
            })
            .finally(() => setPending(undefined));
        },
      },
    }));
  if (error)
    items.push({
      id: "shared-tasks.error",
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
      id: "shared-tasks.loading",
      title: messages.task_share_list_loading(),
      layout: "stack",
      control: {
        type: "custom",
        content: <LoadingIndicator label={messages.task_share_list_loading()} />,
      },
    });
  if (result && !loading && !error && !shares.length && !more)
    items.push({ id: "shared-tasks.empty", title: messages.task_share_list_empty() });
  if (more && !error)
    items.push({
      id: "shared-tasks.more",
      title: messages.task_share_list_loading(),
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
    id: "shared-tasks",
    icon: "shared-tasks",
    label: messages.settings_shared_tasks(),
    sections: [
      {
        id: "shared-tasks.list",
        title: workspace?.name ?? messages.settings_shared_tasks(),
        items,
      },
    ],
  };
}
