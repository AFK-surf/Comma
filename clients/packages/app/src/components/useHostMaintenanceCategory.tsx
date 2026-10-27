import { useCallback, useEffect, useRef, useState } from "react";
import { getNativeBridge, type HostMaintenanceState } from "@comma/native-bridge";
import { useCommaMessages } from "@comma/i18n/react";

/** `clear` deletes the local data; `reinstall_reset` reinstalls on empty data. */
type MaintenanceAction =
  | "update"
  | "reinstall"
  | "uninstall"
  | "clear"
  | "reinstall_reset";

/** Local owner state survives cloud account changes. Uses the existing visible read clock. */
export function useHostMaintenanceCategory(
  visible: boolean,
  tick: number,
  updateRequired = false
) {
  const bridge = getNativeBridge();
  const m = useCommaMessages();
  const available = bridge.platform === "electron";
  const [state, setState] = useState<HostMaintenanceState>();
  const [readingError, setReadingError] = useState(false);
  const [error, setError] = useState("");
  const [pending, setPending] = useState(false);
  /** The last "Continue maintenance" ran the request again and it failed again. */
  const [retryFailed, setRetryFailed] = useState(false);
  const reading = useRef(false);
  const mutating = useRef(false);
  const generation = useRef(0);
  const refresh = useCallback(async () => {
    if (!available || document.hidden || reading.current) return;
    reading.current = true;
    const current = generation.current;
    try {
      const next = await bridge.computeNode.hostMaintenanceState();
      if (current === generation.current) {
        setState(next);
        setReadingError(false);
        setError("");
      }
    } catch {
      if (current === generation.current) setReadingError(true);
    } finally {
      reading.current = false;
    }
  }, [available, bridge]);
  useEffect(() => {
    if (visible) void refresh();
  }, [visible, tick, refresh]);
  useEffect(
    () => () => {
      generation.current++;
    },
    []
  );
  const mutate = async (
    operation: () => Promise<HostMaintenanceState>,
    retry = false
  ) => {
    if (mutating.current) return;
    mutating.current = true;
    generation.current++;
    setPending(true);
    setError("");
    setRetryFailed(false);
    try {
      const next = await operation();
      generation.current++;
      setState(next);
      setReadingError(false);
      setRetryFailed(retry && next.operation?.outcome === "failed");
      return next;
    } catch {
      generation.current++;
      // No second request after an ambiguous result: the next read finds the receipt.
      setReadingError(true);
      setError(m.compute_maintenance_submit_failed());
    } finally {
      mutating.current = false;
      setPending(false);
    }
  };
  // While Main runs a failed request again, the person sees its preparation, not the old failure.
  const shown =
    pending && state?.operation?.outcome === "failed"
      ? {
          ...state,
          operation: {
            requestId: state.operation.requestId,
            action: state.operation.action,
            dataPolicy: state.operation.dataPolicy,
            phase: "preparing" as const,
            outcome: "pending" as const,
          },
        }
      : state;
  const operation = shown?.operation;
  const unfinished = !!operation && operation.outcome !== "succeeded";
  const failed = operation?.outcome === "failed";
  const running = operation?.outcome === "pending";
  const needsInstall = state?.installation === "not_installed";
  const needsUpdate = updateRequired || !!state?.updateAvailable;
  /** Update, repair and clearing wait for a running request; Main recovers a stuck one by itself. */
  const blocked = pending || readingError || !state || running;
  /** After the current client request returns, uninstall can replace stuck native maintenance. */
  const uninstallBlocked = pending || readingError;
  const phaseLabel: string = failed
    ? m.compute_maintenance_failed()
    : operation?.phase === "preparing"
      ? state?.preparationPhase === "downloading"
        ? m.compute_maintenance_downloading()
        : state?.preparationPhase === "extracting"
          ? m.compute_maintenance_extracting()
          : state?.preparationPhase === "building"
            ? m.compute_maintenance_building()
            : m.compute_maintenance_preparing()
      : operation?.phase === "stopping"
        ? m.compute_maintenance_stopping()
        : operation?.phase === "installing"
          ? m.compute_maintenance_installing()
          : operation?.phase === "removing"
            ? m.compute_maintenance_removing()
            : operation?.phase === "checking"
              ? m.compute_maintenance_checking()
              : operation?.outcome === "failed"
                ? m.compute_maintenance_failed()
                : m.compute_maintenance_completed();
  const title: string = readingError
    ? m.compute_maintenance_unknown()
    : unfinished
      ? phaseLabel
      : pending
        ? m.compute_maintenance_preparing()
        : needsInstall &&
            operation?.action === "uninstall" &&
            operation.outcome === "succeeded"
          ? operation.dataPolicy === "reset"
            ? m.compute_maintenance_uninstalled_reset()
            : m.compute_maintenance_uninstalled_preserve()
          : needsInstall
            ? m.compute_maintenance_not_installed()
            : needsUpdate
              ? m.compute_ui_update_available()
              : state?.installation === "installed"
                ? m.compute_maintenance_installed()
                : m.compute_maintenance_unknown();
  const submit = async (next: MaintenanceAction) => {
    const resets = next === "clear" || next === "reinstall_reset";
    // Main decides which request the new one may supersede.
    if (next === "uninstall" ? uninstallBlocked : blocked) return;
    return await mutate(() =>
      bridge.computeNode.maintainHost({
        action:
          next === "reinstall_reset"
            ? "reinstall"
            : next === "clear"
              ? needsInstall
                ? "uninstall"
                : "reinstall"
              : next,
        dataPolicy: resets ? "reset" : "preserve",
      })
    );
  };
  const resume = () => {
    if (!operation || pending) return;
    if (readingError) return void refresh();
    void mutate(
      () =>
        bridge.computeNode.resumeHostMaintenance({ requestId: operation.requestId }),
      true
    );
  };
  return {
    state: shown,
    title,
    phaseLabel,
    refresh,
    pending,
    unfinished,
    failed,
    running,
    needsInstall,
    needsUpdate,
    blocked,
    uninstallBlocked,
    error,
    readingError,
    retryFailed,
    submit,
    resume,
  };
}
