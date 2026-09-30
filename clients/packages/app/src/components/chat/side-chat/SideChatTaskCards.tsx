import { useCallback, useMemo, type MouseEvent as ReactMouseEvent } from "react";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import {
  SideChatCardsPanel,
  taskStatusBucket,
  type SideChatCardsCapabilityState,
  type SideChatTask,
} from "@comma/ui";
import type { CommaApiClient } from "../../../api";
import type { ProductInboxItem } from "../../../runtime-side-chat/nativeSideChat";
import {
  productInboxErrorMessage,
  useProductInboxProjection,
} from "../../../product-inbox";
import { useCommaAuth } from "../../AuthGate";
import {
  useTaskArchiveForApi,
  archiveDisabledReason,
} from "../../tasks/useTaskArchive";
import { useTaskBadges } from "../../tasks/useTaskBadges";
import { openSideChatTaskWindow } from "./sideChatInlineTaskLink";

// Retained for a future entry point; the Side Chat route does not mount this panel.
export function SideChatTaskCards({
  api,
  workspaceId,
  onRequiredHeight,
}: {
  api: CommaApiClient;
  workspaceId: string;
  onRequiredHeight?: (height: number) => void;
}) {
  const capability = useSideChatTasks({ api, workspaceId });
  const handleOpenTask = useCallback(
    (task: SideChatTask, event: ReactMouseEvent<HTMLButtonElement>) => {
      openSideChatTaskWindow(task, event.currentTarget);
    },
    []
  );
  return (
    <SideChatCardsPanel
      capability={capability}
      onOpenTask={handleOpenTask}
      {...(onRequiredHeight ? { onRequiredHeight } : {})}
    />
  );
}

function useSideChatTasks({
  api,
  workspaceId,
}: {
  workspaceId: string;
  api: CommaApiClient;
}): SideChatCardsCapabilityState {
  const archive = useTaskArchiveForApi(api),
    messages = useCommaMessages();
  const locale = useCommaLocale();
  const { productLease } = useCommaAuth();
  const { refresh: refreshTasks, result } = useProductInboxProjection({
    enabled: true,
    session: productLease,
    workspaceId,
  });

  const refresh = useCallback(async () => {
    try {
      await refreshTasks({ limit: 50, workspaceId });
      return true;
    } catch {
      return false;
    }
  }, [refreshTasks, workspaceId]);
  // The same label and platform chips the Tasks board wears; this window has
  // no router, so the chips are plain.
  const taskItems = useMemo(
    () =>
      (result?.items ?? []).filter(
        (item) => item.kind === "agent_task" && item.status !== "archived"
      ),
    [result]
  );
  const { renderTaskBadges } = useTaskBadges(api, taskItems[0]?.groupId, taskItems);

  if (!result) return { status: "loading" };
  if (result.source === "error" || result.source === "unavailable") {
    return {
      message: productInboxErrorMessage(result.errorCode, locale),
      onRefresh: refresh,
      status: "error",
    };
  }
  return {
    refreshing: false,
    status: "ready",
    tasks: taskItems.map((item) => ({
      ...toSideChatTask(item),
      badges: renderTaskBadges(item),
      archiveAction: {
        disabledReason: item.archiveAvailability?.allowed
          ? undefined
          : archiveDisabledReason(item.archiveAvailability?.reason, messages),
        run: () =>
          archive(
            {
              id: item.conversationId,
              group_id: item.groupId,
              updated_at: item.archiveVersion,
            },
            "archive"
          ),
      },
    })),
  };
}

function toSideChatTask(item: ProductInboxItem): SideChatTask {
  return {
    activityStatus: item.status,
    conversationId: item.conversationId,
    createdAt: item.updatedAt,
    groupId: item.groupId,
    id: item.id,
    statusBucket: taskStatusBucket(item.status) as Exclude<
      ReturnType<typeof taskStatusBucket>,
      "archived"
    >,
    title: item.title,
    workspaceId: item.workspaceId,
  };
}
