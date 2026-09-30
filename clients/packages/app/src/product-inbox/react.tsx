import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useSyncExternalStore,
  type ReactNode,
} from "react";
import type { SessionProductLease } from "@comma/session-contract";
import {
  productInboxUnavailableResult,
  type ProductInboxArchiveIntent,
  type ProductInboxArchiveStage,
  type ProductInboxProjectionController,
  type ProductInboxProjectionEnvelope,
  type ProductInboxRefresh,
} from "./controller";

const ProductInboxProjectionContext = createContext<
  ProductInboxProjectionController | undefined
>(undefined);

const subscribeUnavailable = () => () => undefined;
const getUnavailableSnapshot = () => null;

export function ProductInboxProjectionProvider({
  children,
  controller,
}: {
  children: ReactNode;
  controller: ProductInboxProjectionController;
}) {
  return (
    <ProductInboxProjectionContext.Provider value={controller}>
      {children}
    </ProductInboxProjectionContext.Provider>
  );
}

export function useProductInboxProjection(input: {
  enabled: boolean;
  session: SessionProductLease;
  workspaceId?: string | undefined;
}) {
  const controller = useContext(ProductInboxProjectionContext);
  const sessionIdentity = productLeaseIdentity(input.session);
  const stableSession = useMemo<SessionProductLease>(
    () => ({
      audience: input.session.audience,
      authorityInstanceId: input.session.authorityInstanceId,
      generation: input.session.generation,
      sessionId: input.session.sessionId,
    }),
    [
      input.session.audience,
      input.session.authorityInstanceId,
      input.session.generation,
      input.session.sessionId,
    ]
  );
  const retention = useMemo(() => ({ session: stableSession }), [stableSession]);
  const snapshot = useSyncExternalStore(
    controller ? (listener) => controller.subscribe(listener) : subscribeUnavailable,
    controller ? () => controller.getSnapshotSync() : getUnavailableSnapshot,
    getUnavailableSnapshot
  );

  useEffect(() => {
    if (!input.enabled || !controller) {
      return undefined;
    }
    return controller.retain(retention);
  }, [controller, input.enabled, retention]);

  useEffect(() => {
    if (!input.enabled || !controller || !input.workspaceId) {
      return;
    }
    void controller.refresh({ workspaceId: input.workspaceId }).catch(() => undefined);
  }, [controller, input.enabled, input.workspaceId, sessionIdentity]);

  const refresh = useCallback(
    (refreshInput?: ProductInboxRefresh) => {
      if (!controller) {
        return Promise.reject(
          new Error("The ProductInbox projection controller is unavailable.")
        );
      }
      return controller.refresh(refreshInput);
    },
    [controller]
  );

  const matchingSnapshot =
    snapshot && productLeaseIdentity(snapshot.session) === sessionIdentity
      ? snapshot.snapshot
      : null;

  return {
    refresh,
    result:
      matchingSnapshot ??
      (input.enabled && !controller
        ? productInboxUnavailableResult("utility_unavailable")
        : null),
  };
}

/** Requests a canonical reread without retaining another projection demand. */
export function useProductInboxRefresh() {
  const controller = useContext(ProductInboxProjectionContext);
  return useCallback(
    (input?: ProductInboxRefresh) => {
      if (!controller) return Promise.reject(new Error("ProductInbox is unavailable"));
      return controller.refresh(input);
    },
    [controller]
  );
}

/**
 * Stages a Task the user just archived on the projected list. Without a host
 * projection there is nothing local to update, so the decision is simply not
 * shown early and the authority still decides it.
 */
export function useStageTaskArchived() {
  const controller = useContext(ProductInboxProjectionContext);
  return useCallback(
    (input: ProductInboxArchiveIntent): ProductInboxArchiveStage =>
      controller
        ? controller.stageTaskArchived(input)
        : { confirm: () => undefined, rollback: () => undefined },
    [controller]
  );
}

/**
 * Runs `observe` on each owner read as it lands, including a reread that
 * repeats the published list, without rendering the caller. A cache of facts
 * outside the owner's page uses it to revalidate them.
 */
export function useProductInboxOwnerReads(
  observe: (snapshot: ProductInboxProjectionEnvelope) => void
) {
  const controller = useContext(ProductInboxProjectionContext);
  useEffect(() => {
    if (!controller) return undefined;
    const notify = () => {
      const snapshot = controller.getOwnerSnapshotSync();
      if (snapshot) observe(snapshot);
    };
    notify();
    return controller.subscribeOwnerSnapshot(notify);
  }, [controller, observe]);
}

/**
 * Reads one Task's item from the host owner's projection. The caller renders
 * again only when that Task's facts change, not when another Task's do.
 */
export function useProductInboxItem(groupId: string, conversationId: string) {
  const controller = useContext(ProductInboxProjectionContext);
  const subscribe = useCallback(
    (listener: () => void) =>
      controller ? controller.subscribe(listener) : subscribeUnavailable(),
    [controller]
  );
  return useSyncExternalStore(
    subscribe,
    () =>
      controller
        ?.getSnapshotSync()
        ?.snapshot.items.find(
          (item) => item.groupId === groupId && item.conversationId === conversationId
        ),
    () => undefined
  );
}

/** Reads which Workspace the host owner's projection shows, without its list. */
export function useProductInboxActiveWorkspaceId() {
  const controller = useContext(ProductInboxProjectionContext);
  const subscribe = useCallback(
    (listener: () => void) =>
      controller ? controller.subscribe(listener) : subscribeUnavailable(),
    [controller]
  );
  return useSyncExternalStore(
    subscribe,
    () => controller?.getSnapshotSync()?.snapshot.activeWorkspaceId,
    () => undefined
  );
}

/** Reads the host owner's replay-last projection without adding demand. */
export function useProductInboxSnapshot() {
  const controller = useContext(ProductInboxProjectionContext);
  return useSyncExternalStore(
    controller ? (listener) => controller.subscribe(listener) : subscribeUnavailable,
    controller ? () => controller.getSnapshotSync() : getUnavailableSnapshot,
    getUnavailableSnapshot
  );
}

function productLeaseIdentity(session: SessionProductLease) {
  return JSON.stringify([
    session.authorityInstanceId,
    session.generation,
    session.sessionId,
    session.audience,
  ]);
}
