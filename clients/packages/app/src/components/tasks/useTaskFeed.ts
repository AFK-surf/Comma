import { useCall, useTopic, type TaskFeedEntry } from "@comma/core-client";
import { useCommaMessages } from "@comma/i18n/react";
import { toast } from "@comma/ui/components/toast";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";

export interface UseTaskFeedOptions {
  attentionOnly?: boolean;
  enabled?: boolean;
  workspaceId?: string | undefined;
}

export interface TaskFeedState {
  approveEntry: (entry: TaskFeedEntry) => Promise<void>;
  entries: readonly TaskFeedEntry[];
  hasMore: boolean;
  lastSeenAt: number | undefined;
  loadError: string | undefined;
  loadMore: () => Promise<void>;
  loadMoreError: string | undefined;
  loadMorePending: boolean;
  loading: boolean;
  markCaughtUp: () => Promise<void>;
  refresh: () => Promise<void>;
  replyEntry: (entry: TaskFeedEntry, text: string) => Promise<void>;
  workspaceId: string | undefined;
}

const EMPTY_ENTRIES: readonly TaskFeedEntry[] = [];

export function useTaskFeed({
  attentionOnly = false,
  enabled = true,
  workspaceId,
}: UseTaskFeedOptions = {}): TaskFeedState {
  const call = useCall();
  const messages = useCommaMessages();
  const [loadMoreState, setLoadMoreState] = useState<{
    error?: string;
    pending: boolean;
  }>({ pending: false });

  const { error: topicError, value: snapshot } = useTopic(
    enabled
      ? {
          topic: "taskFeed",
          workspace: workspaceId ?? "",
          attention: attentionOnly ? "1" : "",
        }
      : null
  );

  const resolvedWorkspaceId = snapshot?.workspaceId ?? workspaceId;
  const entries = snapshot?.entries ?? EMPTY_ENTRIES;
  const latestOccurredAt = entries[0]?.occurredAt;

  // Capture the reader's pre-visit watermark per workspace so the "Caught up
  // to here" divider stays anchored during the current reading session instead
  // of disappearing as soon as the feed is opened.
  const [sessionSeen, setSessionSeen] = useState<{
    workspaceKey: string;
    at: number | undefined;
  } | null>(null);
  const workspaceKey = resolvedWorkspaceId ?? "";

  useEffect(() => {
    if (!enabled) {
      setSessionSeen(null);
      return;
    }
    if (!snapshot?.loaded) return;
    setSessionSeen((current) =>
      current && current.workspaceKey === workspaceKey
        ? current
        : { workspaceKey, at: snapshot.lastSeenAt }
    );
  }, [enabled, snapshot?.lastSeenAt, snapshot?.loaded, workspaceKey]);

  // Persist the latest seen timestamp when leaving the Feed surface.
  const latestRef = useRef<{
    enabled: boolean;
    workspaceId: string | undefined;
    latestOccurredAt: number | undefined;
    persistedLastSeenAt: number | undefined;
  }>({
    enabled,
    workspaceId: resolvedWorkspaceId,
    latestOccurredAt,
    persistedLastSeenAt: snapshot?.lastSeenAt,
  });
  latestRef.current = {
    enabled,
    workspaceId: resolvedWorkspaceId,
    latestOccurredAt,
    persistedLastSeenAt: snapshot?.lastSeenAt,
  };

  useEffect(() => {
    if (!enabled) return undefined;
    return () => {
      const current = latestRef.current;
      if (
        current.latestOccurredAt !== undefined &&
        (current.persistedLastSeenAt === undefined ||
          current.latestOccurredAt > current.persistedLastSeenAt)
      ) {
        void call("taskFeed.markSeen", {
          ...(current.workspaceId ? { workspace: current.workspaceId } : {}),
          at: current.latestOccurredAt,
        }).catch(() => undefined);
      }
    };
  }, [call, enabled]);

  const refresh = useCallback(async () => {
    setLoadMoreState((prev) =>
      prev.pending || prev.error !== undefined ? { pending: false } : prev
    );
    await call("taskFeed.refresh", {
      ...(resolvedWorkspaceId ? { workspace: resolvedWorkspaceId } : {}),
      attention: attentionOnly,
    }).catch(() => undefined);
  }, [attentionOnly, call, resolvedWorkspaceId]);

  const loadMore = useCallback(async () => {
    if (loadMoreState.pending || !snapshot?.hasMore || !snapshot.nextCursor) return;
    setLoadMoreState({ pending: true });
    try {
      await call("taskFeed.loadMore", {
        ...(resolvedWorkspaceId ? { workspace: resolvedWorkspaceId } : {}),
        attention: attentionOnly,
        cursor: snapshot.nextCursor,
      });
      setLoadMoreState({ pending: false });
    } catch {
      setLoadMoreState({
        error: messages.task_feed_error_description(),
        pending: false,
      });
    }
  }, [
    attentionOnly,
    call,
    loadMoreState.pending,
    messages,
    resolvedWorkspaceId,
    snapshot?.hasMore,
    snapshot?.nextCursor,
  ]);

  const markCaughtUp = useCallback(async () => {
    if (latestOccurredAt === undefined) return;
    setSessionSeen({ workspaceKey, at: latestOccurredAt });
    await call("taskFeed.markSeen", {
      ...(resolvedWorkspaceId ? { workspace: resolvedWorkspaceId } : {}),
      at: latestOccurredAt,
    });
  }, [call, latestOccurredAt, resolvedWorkspaceId, workspaceKey]);

  const approveEntry = useCallback(
    async (entry: TaskFeedEntry) => {
      if (entry.reviewVersion === undefined) return;
      try {
        await call("tasks.accept", {
          group: entry.groupId,
          conversation: entry.conversationId,
          reviewVersion: entry.reviewVersion,
        });
        await refresh();
      } catch {
        toast.error(messages.task_feed_approve_failed(), {
          id: "comma-task-feed-approve-failed",
        });
      }
    },
    [call, messages, refresh]
  );

  const replyEntry = useCallback(
    async (entry: TaskFeedEntry, text: string) => {
      const targetWorkspaceId = resolvedWorkspaceId;
      if (!targetWorkspaceId) {
        toast.error(messages.task_feed_reply_failed(), {
          id: "comma-task-feed-reply-failed",
        });
        throw new Error(messages.task_feed_reply_failed());
      }
      try {
        await call("chat.sendDetached", {
          workspaceId: targetWorkspaceId,
          groupId: entry.groupId,
          conversationId: entry.conversationId,
          text,
        });
        await refresh();
      } catch (error) {
        toast.error(messages.task_feed_reply_failed(), {
          id: "comma-task-feed-reply-failed",
        });
        throw error;
      }
    },
    [call, messages, refresh, resolvedWorkspaceId]
  );

  const loadError =
    topicError ||
    (snapshot && (snapshot.source === "error" || snapshot.source === "unavailable"))
      ? messages.task_feed_error_description()
      : undefined;

  const hasMore = snapshot?.hasMore === true;
  const lastSeenAt =
    sessionSeen?.workspaceKey === workspaceKey ? sessionSeen.at : snapshot?.lastSeenAt;
  const loading = enabled && !loadError && (!snapshot || !snapshot.loaded);

  return useMemo(
    () => ({
      approveEntry,
      entries,
      hasMore,
      lastSeenAt,
      loadError,
      loadMore,
      loadMoreError: loadMoreState.error,
      loadMorePending: loadMoreState.pending,
      loading,
      markCaughtUp,
      refresh,
      replyEntry,
      workspaceId: resolvedWorkspaceId,
    }),
    [
      approveEntry,
      entries,
      hasMore,
      lastSeenAt,
      loadError,
      loadMore,
      loadMoreState.error,
      loadMoreState.pending,
      loading,
      markCaughtUp,
      refresh,
      replyEntry,
      resolvedWorkspaceId,
    ]
  );
}
