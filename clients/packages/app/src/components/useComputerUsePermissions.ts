import {
  getNativeBridge,
  type ComputerUsePermissionFlowResult,
} from "@comma/native-bridge";
import { useCallback, useEffect, useRef, useState } from "react";

export function useComputerUsePermissions(active: boolean) {
  const bridge = getNativeBridge();
  const available = bridge.platform === "electron" && bridge.os === "macos";
  const [permissions, setPermissions] =
    useState<ComputerUsePermissionFlowResult["permissions"]>();
  const [error, setError] = useState<string>();
  const [pending, setPending] = useState(false);
  const inFlight = useRef(false);
  const run = useCallback(
    async (open: boolean) => {
      if (!available || inFlight.current) return;
      inFlight.current = true;
      setPending(true);
      setError(undefined);
      try {
        if (open) {
          const result = await bridge.computerUse.openPermissionFlow();
          if (!result.ok)
            throw new Error(result.error || "Could not open permissions.");
        }
        const result = await bridge.computerUse.getPermissions();
        if (!result.ok || !result.permissions)
          throw new Error(result.error || "Could not read permissions.");
        setPermissions(result.permissions);
      } catch (reason) {
        setPermissions(undefined);
        setError(reason instanceof Error ? reason.message : String(reason));
      } finally {
        inFlight.current = false;
        setPending(false);
      }
    },
    [available, bridge]
  );

  useEffect(() => {
    if (!active || !available) return;
    // One helper per Mac: one request on entry/focus, at most one in flight.
    // No timers, per-device fan-out, or persistent permission mirror.
    const refresh = () => {
      void run(false);
    };
    refresh();
    window.addEventListener("focus", refresh);
    return () => window.removeEventListener("focus", refresh);
  }, [active, available, run]);

  return {
    available,
    permissions,
    error,
    pending,
    refresh: () => {
      void run(false);
    },
    open: () => {
      void run(true);
    },
  };
}
