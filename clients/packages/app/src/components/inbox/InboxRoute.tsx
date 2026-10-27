import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import { Outlet, useParams } from "@tanstack/react-router";
import { useCallback, useEffect, useRef, useState, type ReactNode } from "react";
import {
  productInboxErrorMessage,
  useProductInboxProjection,
} from "../../product-inbox";
import { useSelectWorkspace, useWorkspacePreference } from "../activeWorkspace";
import { TaskSequenceSourceProvider } from "../tasks/taskSequence";
import { useInboxFilters } from "./filters/InboxFiltersState";
import { InboxView } from "./InboxView";

/** Product inbox route backed by the host-owned cross-platform projection. */
export function InboxRoute() {
  const locale = useCommaLocale();
  const params = useParams({ strict: false }) as { conversationId?: string };
  const [loadMoreState, setLoadMoreState] = useState<{
    error?: string;
    pending: boolean;
  }>({ pending: false });
  // The inbox opens on the workspace the app works in, once the core has read it.
  const activeWorkspaceId = useWorkspacePreference();
  const selectWorkspace = useSelectWorkspace();
  const [chosenWorkspaceId, setSelectedWorkspaceId] = useState<string | undefined>();
  const selectedWorkspaceId = chosenWorkspaceId ?? (activeWorkspaceId || undefined);
  const [, setFilters] = useInboxFilters();
  const requestedWorkspaceId = useRef<string | undefined>(undefined);
  const { refresh, result } = useProductInboxProjection({
    enabled: activeWorkspaceId !== undefined,
    ...(selectedWorkspaceId ? { workspaceId: selectedWorkspaceId } : {}),
  });

  const handleSelectWorkspace = useCallback(
    (workspaceId: string) => {
      requestedWorkspaceId.current = workspaceId;
      selectWorkspace(workspaceId);
      setLoadMoreState({ pending: false });
      setSelectedWorkspaceId(workspaceId);
      // A trigger rule belongs to the workspace's Loops. The other filters
      // choose by kind, platform, schedule or status, which every workspace has.
      setFilters((current) => ({ ...current, loopRule: undefined }));
    },
    [selectWorkspace, setFilters]
  );

  useEffect(() => {
    if (result?.activeWorkspaceId === requestedWorkspaceId.current) {
      requestedWorkspaceId.current = undefined;
    }
    if (
      result?.activeWorkspaceId &&
      result.activeWorkspaceId !== selectedWorkspaceId &&
      requestedWorkspaceId.current === undefined
    ) {
      selectWorkspace(result.activeWorkspaceId);
      setSelectedWorkspaceId(result.activeWorkspaceId);
    }
  }, [result?.activeWorkspaceId, selectedWorkspaceId, selectWorkspace]);

  const handleLoadMore = useCallback(async () => {
    if (
      loadMoreState.pending ||
      !result?.hasMore ||
      !result.nextCursor ||
      !result.activeWorkspaceId
    ) {
      return;
    }

    setLoadMoreState({ pending: true });
    try {
      await refresh({
        cursor: result.nextCursor,
        workspaceId: result.activeWorkspaceId,
      });
      setLoadMoreState({ pending: false });
    } catch (error) {
      // The core says why with the list's own error code.
      setLoadMoreState({
        error: productInboxErrorMessage((error as { code?: string }).code, locale),
        pending: false,
      });
    }
  }, [loadMoreState.pending, locale, refresh, result]);

  if (!result) {
    return (
      <div data-testid="inbox-loading">
        <InboxView result={null} selectedConversationId={params.conversationId} />
      </div>
    );
  }

  return (
    <InboxView
      loadMoreError={loadMoreState.error}
      loadMorePending={loadMoreState.pending}
      onLoadMore={handleLoadMore}
      result={result}
      selectedConversationId={params.conversationId}
      workspaceSelector={
        result.activeWorkspaceId && result.workspaces && result.workspaces.length > 1
          ? {
              activeWorkspaceId: result.activeWorkspaceId,
              onChange: handleSelectWorkspace,
              workspaces: result.workspaces,
            }
          : undefined
      }
    />
  );
}

/** Figma 379:5179 — Inbox conversation rail plus the selected conversation. */
export function InboxWorkspace({ children }: { children?: ReactNode }) {
  const messages = useCommaMessages();

  return (
    <section
      aria-label={messages.inbox_title()}
      className="flex min-h-0 w-full min-w-0 flex-1 bg-main-panel-bg [&_.comma-chat-column]:max-w-none [&_.comma-chat-composer-frame]:max-w-none [&_.comma-chat-thread]:pt-md"
      data-testid="inbox-workspace"
    >
      <TaskSequenceSourceProvider>
        <InboxRoute />
        <div className="flex min-h-0 min-w-0 flex-1" data-testid="inbox-detail-pane">
          {children ?? <Outlet />}
        </div>
      </TaskSequenceSourceProvider>
    </section>
  );
}
