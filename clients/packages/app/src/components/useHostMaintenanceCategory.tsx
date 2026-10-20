import { useCallback, useEffect, useRef, useState } from "react";
import { getNativeBridge, type HostMaintenanceState } from "@comma/native-bridge";
import { useCommaMessages } from "@comma/i18n/react";

type MaintenanceAction = "update" | "reinstall" | "uninstall" | "clear";

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
  const mutate = async (operation: () => Promise<HostMaintenanceState>) => {
    if (mutating.current) return;
    mutating.current = true;
    generation.current++;
    setPending(true);
    setError("");
    try {
      const next = await operation();
      generation.current++;
      setState(next);
      setReadingError(false);
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
  const operation = state?.operation;
  const unfinished = !!operation && operation.outcome !== "succeeded";
  const failed = operation?.outcome === "failed";
  const running = operation?.outcome === "pending";
  const needsInstall = state?.installation === "not_installed";
  const needsUpdate = updateRequired || !!state?.updateAvailable;
  const blocked = pending || readingError || !state || running;
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
    if (blocked || (unfinished && next !== "uninstall" && next !== "clear")) return;
    return await mutate(() =>
      bridge.computeNode.maintainHost({
        action: next === "clear" ? (needsInstall ? "uninstall" : "reinstall") : next,
        dataPolicy: next === "clear" ? "reset" : "preserve",
      })
    );
  };
  const resume = () => {
    if (!operation || pending) return;
    if (readingError) return void refresh();
    void mutate(() =>
      bridge.computeNode.resumeHostMaintenance({ requestId: operation.requestId })
    );
  };
  return {
    state,
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
    error,
    readingError,
    submit,
    resume,
  };
}
