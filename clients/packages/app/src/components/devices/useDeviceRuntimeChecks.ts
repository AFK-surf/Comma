import { useCallback, useEffect, useRef, useState } from "react";
import type { CommaApiClient, CommaDevice } from "../../api";

type CheckState = "pending" | "failed";
type Visit = {
  controller: AbortController;
  observed: boolean;
  observedDevices: Set<string>;
  queued: string[];
  pending: Set<string>;
  active: number;
};

export function useDeviceRuntimeChecks(
  api: CommaApiClient,
  workspaceId: string | undefined,
  enabled: boolean,
  onChecked: (device: CommaDevice) => void
) {
  const visit = useRef<Visit | undefined>(undefined);
  const [checks, setChecks] = useState<Record<string, CheckState>>({});

  useEffect(() => {
    if (!enabled || !workspaceId) return;
    setChecks({});
    const current: Visit = {
      controller: new AbortController(),
      observed: false,
      observedDevices: new Set(),
      queued: [],
      pending: new Set(),
      active: 0,
    };
    visit.current = current;
    return () => {
      current.controller.abort();
      visit.current = undefined;
    };
  }, [enabled, workspaceId]);

  const check = useCallback(
    (deviceId: string) => {
      const current = visit.current;
      if (!current || !workspaceId || current.pending.has(deviceId)) return;
      // The settings inventory holds at most 50 devices. Queue once per device,
      // with two requests in flight, rather than probing each runtime separately.
      if (current.pending.size >= 50) return;
      current.pending.add(deviceId);
      current.queued.push(deviceId);
      setChecks((previous) => ({ ...previous, [deviceId]: "pending" }));

      const drain = () => {
        if (current.controller.signal.aborted) return;
        while (current.active < 2 && current.queued.length) {
          const id = current.queued.shift()!;
          current.active += 1;
          void (async () => {
            let state: CheckState | undefined;
            try {
              const device = await api.probeDevice(workspaceId, id, {
                signal: current.controller.signal,
              });
              if (!current.controller.signal.aborted) onChecked(device);
            } catch {
              state = "failed";
            } finally {
              current.active -= 1;
              current.pending.delete(id);
              if (!current.controller.signal.aborted) {
                setChecks((previous) => {
                  const next = { ...previous };
                  if (state) next[id] = state;
                  else delete next[id];
                  return next;
                });
                drain();
              }
            }
          })();
        }
      };
      drain();
    },
    [api, onChecked, workspaceId]
  );

  const checkExpiredOnEntry = useCallback(
    (devices: readonly CommaDevice[], localDevice?: CommaDevice) => {
      const current = visit.current;
      if (!current) return;
      // Only the first successful snapshot in this visit starts automatic work.
      // Pagination, focus, and the 15-second metadata poll cannot retry checks.
      // Leaving cancels the queue; Connector requests already sent may finish.
      const initial = current.observed ? [] : devices.slice(0, 50);
      current.observed = true;
      // Native identity can arrive after the first page, including when this
      // computer is outside that page. Still inspect it once in this visit.
      if (localDevice) initial.push(localDevice);
      const now = Date.now() / 1000;
      for (const device of initial) {
        if (current.observedDevices.has(device.device_id)) continue;
        current.observedDevices.add(device.device_id);
        if (
          device.status === "connected" &&
          device.allows_operations &&
          device.device_runtimes?.some(
            (runtime) =>
              ["codex", "claude", "pi", "kimi"].includes(runtime.provider) &&
              (runtime.status === "stale" ||
                (runtime.readiness_valid_until != null &&
                  runtime.readiness_valid_until <= now) ||
                (runtime.status === "ready" && !runtime.readiness_valid_until))
          )
        ) {
          check(device.device_id);
        }
      }
    },
    [check]
  );

  return { checks, check, checkExpiredOnEntry };
}
