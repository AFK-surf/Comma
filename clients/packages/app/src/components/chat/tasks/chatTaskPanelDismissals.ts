import { useCall, useTopic } from "@comma/core-client";
import { useCallback, useEffect, useMemo } from "react";

/**
 * Settled tasks the user has acknowledged out of the chat task panel, each
 * with the run they acknowledged (when that run started). A running task
 * always shows; once it settles, "Reveal in Chat" records the task here while
 * jumping to its announcing turn, and "Dismiss" records the same
 * acknowledgement without revealing. A task that ran again since docks again,
 * and its next settle needs a fresh acknowledgement.
 *
 * They are the account's: the core keeps them with the reader's other marks
 * and the server keeps them for every device, so a row dismissed on one
 * device stays cleared on the others. Safe to lose (a row merely re-appears).
 */
const LEGACY_STORAGE_KEY = "comma.chatTaskPanelDismissed";

/** Task id → when the acknowledged run started (0 when not known). */
export type DismissedPanelTasks = ReadonlyMap<string, number>;

const NONE: DismissedPanelTasks = new Map();

/** Acknowledgements this window kept in localStorage before the core kept them: handed over once, then dropped. */
function useLegacyDismissals() {
  const call = useCall();
  useEffect(() => {
    let ids: string[] = [];
    try {
      const raw = globalThis.localStorage?.getItem(LEGACY_STORAGE_KEY);
      if (raw === null || raw === undefined) return;
      const parsed: unknown = JSON.parse(raw);
      if (Array.isArray(parsed))
        ids = parsed.filter((id): id is string => typeof id === "string");
    } catch {
      // Blocked storage or a corrupted payload: nothing to hand over.
    }
    void call("marks.mark", { kind: "chatTaskDismissed", ids: ids.slice(-300) }).then(
      () => {
        try {
          globalThis.localStorage?.removeItem(LEGACY_STORAGE_KEY);
        } catch {
          // Handed over again next time, which changes nothing.
        }
      },
      () => undefined
    );
  }, [call]);
}

export function useDismissedPanelTasks(): DismissedPanelTasks {
  useLegacyDismissals();
  const { value } = useTopic({ topic: "marks", kind: "chatTaskDismissed" });
  const marks = value?.marks;
  return useMemo(() => (marks ? new Map(Object.entries(marks)) : NONE), [marks]);
}

/**
 * Acknowledges a settled task at the run the panel shows. A task from before
 * the server kept its runs is acknowledged at 0, never at a device's time, so
 * its next run shows it again whatever the device's clock says.
 */
export function usePanelTaskDismissal() {
  const call = useCall();
  return useCallback(
    (conversationId: string, version: number) =>
      void call("marks.mark", {
        kind: "chatTaskDismissed",
        entries: [[conversationId, version]],
      }).catch(() => undefined),
    [call]
  );
}

/**
 * Reads the acknowledgements again when the reader comes back to the window,
 * so one made on another device clears its row here. The core reads at most
 * once per 30 s however often the window comes to the front.
 */
export function useRefreshPanelDismissalsWhenAttended() {
  const call = useCall();
  useEffect(() => {
    const refresh = () => {
      if (document.visibilityState !== "visible" || !document.hasFocus()) return;
      void call("marks.refresh", { kind: "chatTaskDismissed" }).catch(() => undefined);
    };
    window.addEventListener("focus", refresh);
    document.addEventListener("visibilitychange", refresh);
    return () => {
      window.removeEventListener("focus", refresh);
      document.removeEventListener("visibilitychange", refresh);
    };
  }, [call]);
}
