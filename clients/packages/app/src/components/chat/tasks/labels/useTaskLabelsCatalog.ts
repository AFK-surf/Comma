import { useCall, useTopic } from "@comma/core-client";
import { useCallback, useEffect, useRef } from "react";
import type { CommaTaskLabelCatalog } from "@comma/core/api-schemas";

export type TaskLabelsCatalogState = {
  catalog: CommaTaskLabelCatalog | undefined;
  /** Reads the catalog again now. */
  refresh: () => Promise<void>;
};

/** The catalog together with its read status, for the surface that shows it. */
export type TaskLabelsCatalogStatusState = TaskLabelsCatalogState & {
  error: boolean;
  /** The first read is under way; a re-read of labels already kept is not reported. */
  loading: boolean;
};

/**
 * One catalog per Group, kept by the client core and shared by every surface that shows labels (Settings, the Task
 * panel, the chat's confirmation card, card chips and the inline Task's hover card): a read serves all of them, and a
 * change's catalog updates all of them at once.
 */
function useCatalog(
  groupId: string | undefined,
  enabled: boolean,
  mode: "" | "known",
  refreshKey?: string
) {
  const call = useCall();
  const { value } = useTopic(
    enabled && groupId ? { topic: "taskLabels", group: groupId, key: "", mode } : null
  );
  const refresh = useCallback(
    () =>
      groupId
        ? call("taskLabels.refresh", { group: groupId }).then(
            () => undefined,
            () => undefined
          )
        : Promise.resolve(),
    [call, groupId]
  );
  // Keep the same catalog subscription while membership changes, so the
  // picker never loses its anchor while the fresh catalog is in flight.
  const previous = useRef({ groupId, enabled: false, refreshKey });
  useEffect(() => {
    const before = previous.current;
    previous.current = { groupId, enabled, refreshKey };
    if (
      enabled &&
      groupId &&
      mode !== "known" &&
      value?.catalog &&
      before.groupId === groupId &&
      (!before.enabled || before.refreshKey !== refreshKey)
    )
      void refresh();
  }, [enabled, groupId, mode, refreshKey, refresh, value?.catalog]);
  return { value, refresh };
}

/**
 * The Group's label catalog for a surface that wants it current: the core reads it each time the surface is enabled
 * (a Task panel unfolding, the Tasks board opening) or `refreshKey` changes, and every change answers the fresh
 * catalog. While disabled the surface shows nothing.
 */
export function useTaskLabelsCatalog(
  groupId: string | undefined,
  enabled = true,
  refreshKey?: string
): TaskLabelsCatalogState {
  const { value, refresh } = useCatalog(groupId, enabled, "", refreshKey);
  return { catalog: value?.catalog ?? undefined, refresh };
}

/** The catalog with its read status, for the surface that shows loading and failure (Settings › Labels). */
export function useTaskLabelsCatalogStatus(
  groupId: string | undefined,
  enabled = true
): TaskLabelsCatalogStatusState {
  const { value, refresh } = useCatalog(groupId, enabled, "");
  return {
    catalog: value?.catalog ?? undefined,
    error: value?.error ?? false,
    loading: value?.loading ?? (enabled && !!groupId),
    refresh,
  };
}

/**
 * The same catalog for the many small readers (an inline Task's hover card): the core reads only when nothing is kept
 * yet, otherwise it rides on what the Group's other surfaces already loaded.
 */
export function useTaskLabelsCatalogShared(
  groupId: string | undefined
): TaskLabelsCatalogState {
  const { value, refresh } = useCatalog(groupId, true, "known");
  return { catalog: value?.catalog ?? undefined, refresh };
}
