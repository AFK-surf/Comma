import { useEffect, useSyncExternalStore } from "react";
import { useProductInboxSnapshot } from "../../../product-inbox/react";
import { markTaskReviewSeen } from "../../tasks/taskReviewAttention";

const subscribeDocumentVisibility = (listener: () => void) => {
  if (typeof document === "undefined") return () => undefined;
  document.addEventListener("visibilitychange", listener);
  return () => document.removeEventListener("visibilitychange", listener);
};

const documentIsVisible = () =>
  typeof document === "undefined" || document.visibilityState !== "hidden";

const normalizeRevision = (timestamp: number | undefined) => {
  if (timestamp === undefined || !Number.isFinite(timestamp)) return undefined;
  return timestamp > 0 && timestamp < 10_000_000_000 ? timestamp * 1_000 : timestamp;
};

/**
 * Advances a Task's renderer-local seen revision only after its matching
 * conversation snapshot has reached a surface the reader can actually see.
 */
export function useMarkLoadedTaskReviewSeen({
  conversationId,
  enabled,
  groupId,
  renderedUpdatedAt,
  workspaceId,
}: {
  conversationId?: string | undefined;
  enabled: boolean;
  groupId?: string | undefined;
  renderedUpdatedAt?: number | undefined;
  workspaceId?: string | undefined;
}) {
  const productInbox = useProductInboxSnapshot();
  const visible = useSyncExternalStore(
    subscribeDocumentVisibility,
    documentIsVisible,
    documentIsVisible
  );
  const projectionUpdatedAt = productInbox?.snapshot.items.find(
    (item) =>
      item.kind === "agent_task" &&
      item.workspaceId === workspaceId &&
      item.groupId === groupId &&
      item.conversationId === conversationId
  )?.updatedAt;
  const renderedRevision = normalizeRevision(renderedUpdatedAt);
  const seenRevision =
    projectionUpdatedAt !== undefined &&
    renderedRevision !== undefined &&
    renderedRevision >= projectionUpdatedAt
      ? projectionUpdatedAt
      : undefined;

  useEffect(() => {
    if (!enabled || !visible || !conversationId || seenRevision === undefined) return;
    markTaskReviewSeen(conversationId, seenRevision);
  }, [conversationId, enabled, seenRevision, visible]);
}
