import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import { Outlet, useParams } from "@tanstack/react-router";
import { useCallback, useEffect, useRef, useState, type ReactNode } from "react";
import {
  productInboxErrorMessage,
  useProductInboxProjection,
} from "../../product-inbox";
import { readActiveWorkspaceId, writeActiveWorkspaceId } from "../activeWorkspace";
import { useCommaAuth } from "../AuthGate";
import { InboxView } from "./InboxView";

/** Product inbox route backed by the host-owned cross-platform projection. */
export function InboxRoute() {
  const locale = useCommaLocale();
  const params = useParams({ strict: false }) as { conversationId?: string };
  const auth = useCommaAuth();
  const [loadMoreState, setLoadMoreState] = useState<{
    error?: string;
    pending: boolean;
  }>({ pending: false });
  const [selectedWorkspaceId, setSelectedWorkspaceId] = useState<string | undefined>(
    () => readActiveWorkspaceId()
  );
  const requestedWorkspaceId = useRef<string | undefined>(undefined);
  const { refresh, result } = useProductInboxProjection({
    enabled: true,
    session: auth.productLease,
    ...(selectedWorkspaceId ? { workspaceId: selectedWorkspaceId } : {}),
  });

  const handleSelectWorkspace = useCallback((workspaceId: string) => {
    requestedWorkspaceId.current = workspaceId;
    writeActiveWorkspaceId(workspaceId);
    setLoadMoreState({ pending: false });
    setSelectedWorkspaceId(workspaceId);
  }, []);

  useEffect(() => {
    if (result?.activeWorkspaceId === requestedWorkspaceId.current) {
      requestedWorkspaceId.current = undefined;
    }
    if (
      result?.activeWorkspaceId &&
      result.activeWorkspaceId !== selectedWorkspaceId &&
      requestedWorkspaceId.current === undefined
    ) {
      writeActiveWorkspaceId(result.activeWorkspaceId);
      setSelectedWorkspaceId(result.activeWorkspaceId);
    }
  }, [result?.activeWorkspaceId, selectedWorkspaceId]);

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
      const envelope = await refresh({
        cursor: result.nextCursor,
        limit: 50,
        workspaceId: result.activeWorkspaceId,
      });
      if (envelope.snapshot.source !== "live-sync") {
        throw new Error(productInboxErrorMessage(envelope.snapshot.errorCode, locale));
      }
      setLoadMoreState({ pending: false });
    } catch (error) {
      setLoadMoreState({ error: errorMessage(error), pending: false });
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
      <InboxRoute />
      <div className="flex min-h-0 min-w-0 flex-1" data-testid="inbox-detail-pane">
        {children ?? <Outlet />}
      </div>
    </section>
  );
}

function errorMessage(error: unknown) {
  return error instanceof Error ? error.message : String(error);
}
