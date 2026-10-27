import { useHostMaintenanceCategory } from "./useHostMaintenanceCategory";
import { useCallback, useEffect, useRef, useState } from "react";
import {
  getNativeBridge,
  type LocalComputeWorkloads,
  type LocalComputeOverview,
} from "@comma/native-bridge";
import { useTopicListener } from "@comma/core-client";
import { useCommaMessages } from "@comma/i18n/react";
// One visible clock. A tick reads one native page, one disk total, at most one receipt and one cloud mapping batch.
// Workload detail pages are user-triggered; each read path permits one request in flight.
export type ComputePanelDetail =
  | "local"
  | "maintenance"
  | "settings"
  | "erase"
  | "authorization";
export function useLocalComputeCategory(
  visible: boolean,
  workspaceId?: string,
  options?: {
    navigation?: {
      detail: ComputePanelDetail | undefined;
      setDetail: (detail: ComputePanelDetail | undefined) => void;
    };
    updateRequired?: boolean;
  }
) {
  const bridge = getNativeBridge();
  const m = useCommaMessages();
  const available = bridge.platform === "electron";
  const [cloudWorkloads, setCloudWorkloads] = useState<LocalComputeWorkloads>();
  const [overview, setOverview] = useState<LocalComputeOverview>();
  const [previous, setPrevious] = useState<LocalComputeOverview>();
  const [cursor, setCursor] = useState<string>();
  const [selected, setSelected] = useState<string>();
  const [ownDetail, setOwnDetail] = useState<ComputePanelDetail>();
  const detail = options?.navigation ? options.navigation.detail : ownDetail;
  const setDetail = options?.navigation?.setDetail ?? setOwnDetail;
  const managing = detail === "local";
  const setManaging = (value: boolean) => setDetail(value ? "local" : undefined);
  const [error, setError] = useState("");
  const [mutating, setMutating] = useState(false);
  const [tick, setTick] = useState(0);
  const maintenance = useHostMaintenanceCategory(
    visible,
    tick,
    options?.updateRequired || overview?.availability === "capability_missing"
  );
  const reading = useRef(false);
  const workloadReading = useRef(false);
  const epoch = useRef(0);
  const authority = useRef<string | undefined>(undefined);
  const selectedKey = useRef(selected);
  selectedKey.current = selected;
  const currentWorkspace = useRef(workspaceId);
  currentWorkspace.current = workspaceId;
  const currentCursor = useRef(cursor);
  currentCursor.current = cursor;
  const refresh = useCallback(async () => {
    if (!available || document.hidden || reading.current) return;
    const generation = epoch.current;
    reading.current = true;
    try {
      const page = await bridge.computeNode.localOverview({
        ...(currentCursor.current ? { cursor: currentCursor.current } : {}),
        ...(currentWorkspace.current ? { workspaceId: currentWorkspace.current } : {}),
      });
      if (generation !== epoch.current) return;
      setOverview(page);
      if (
        !page.environments.some(
          (row) => row.key === selectedKey.current && row.canReadWorkloads
        )
      )
        setCloudWorkloads(undefined);
      if (page.availability === "available") setPrevious(page);
    } catch {
      if (generation === epoch.current) {
        setOverview({ availability: "unavailable", environments: [] });
        setCloudWorkloads(undefined);
      }
    } finally {
      reading.current = false;
    }
  }, [available, bridge]);
  // A completed uninstall/reset invalidates guest observations, not the local receipt.
  // The next shared tick can repopulate them; never keep deleted rows as current data.
  const completedMaintenance = maintenance.state?.operation;
  const invalidatedMaintenance = useRef<string | undefined>(undefined);
  useEffect(() => {
    const operation = completedMaintenance;
    if (operation?.outcome !== "succeeded") return;
    if (operation.action !== "uninstall" && operation.dataPolicy !== "reset") return;
    if (invalidatedMaintenance.current === operation.requestId) return;
    invalidatedMaintenance.current = operation.requestId;
    epoch.current++;
    setOverview({ availability: "unavailable", environments: [] });
    setCloudWorkloads(undefined);
    if (operation.dataPolicy === "reset") setPrevious(undefined);
  }, [completedMaintenance]);
  useEffect(() => {
    if (!available) return;
    return bridge.computeNode.state.subscribe((state) => {
      if (authority.current !== state.confirmationId) {
        authority.current = state.confirmationId;
        epoch.current++;
        setCloudWorkloads(undefined);
        setOverview((page) =>
          page
            ? {
                ...page,
                environments: page.environments.map((row) => ({
                  ...row,
                  canReadWorkloads: false,
                  canOperate: false,
                })),
              }
            : page
        );
      }
    });
  }, [available, bridge]);
  useEffect(() => {
    setCloudWorkloads(undefined);
  }, [workspaceId]);
  useEffect(() => {
    epoch.current += 1;
    setSelected(undefined);
    if (visible) void refresh();
  }, [cursor, refresh, visible, workspaceId]);
  // The page's clock is the core's (`computeTick`, every 5 s while shown); a
  // hidden window lets it go and reads again as soon as it is shown.
  const [hidden, setHidden] = useState(() => document.hidden);
  useEffect(() => {
    if (!visible || !available) return;
    const seen = () => setHidden(document.hidden);
    document.addEventListener("visibilitychange", seen);
    seen();
    return () => {
      epoch.current += 1;
      document.removeEventListener("visibilitychange", seen);
    };
  }, [visible, available]);
  useTopicListener(
    visible && available && !hidden ? { topic: "computeTick" } : null,
    () => {
      void refresh();
      setTick((value) => value + 1);
    }
  );
  const mutate = async (operation: () => Promise<unknown>) => {
    if (mutating) return;
    setMutating(true);
    setError("");
    try {
      await operation();
      await refresh();
    } catch {
      setError(m.compute_local_failed());
    } finally {
      setMutating(false);
    }
  };
  const fresh = overview?.availability === "available";
  const data = fresh ? overview : previous;
  const stateLabel = (state: string): string =>
    state === "observed_active"
      ? m.compute_local_active()
      : state === "retired"
        ? m.compute_local_retired()
        : state === "vm_stopped"
          ? m.compute_local_vm_stopped()
          : m.compute_local_unknown();
  const select = (key: string) => {
    selectedKey.current = key;
    setSelected(key);
    setCloudWorkloads(undefined);
    setManaging(true);
  };
  const readWorkloads = async (key: string, nextCursor?: string) => {
    if (workloadReading.current) return;
    workloadReading.current = true;
    const generation = epoch.current;
    try {
      const result = await bridge.computeNode.localWorkloads({
        key,
        ...(nextCursor ? { cursor: nextCursor } : {}),
      });
      if (generation === epoch.current && selectedKey.current === key)
        setCloudWorkloads(result);
    } catch {
      if (generation === epoch.current) setCloudWorkloads(undefined);
    } finally {
      workloadReading.current = false;
    }
  };
  return {
    maintenance,
    overview,
    data,
    fresh,
    error,
    mutating,
    tick,
    available,
    managing,
    selected,
    select,
    cloudWorkloads,
    readWorkloads,
    stateLabel,
    refresh,
    disposal: overview?.disposal,
    nextPage: () => setCursor(overview?.nextCursor),
    firstPage: () => setCursor(undefined),
    hasPreviousPage: !!cursor,
    open: () => setManaging(true),
    close: () => setManaging(false),
    dispose: (key: string) => mutate(() => bridge.computeNode.disposeLocal({ key })),
    resumeDisposal: () =>
      overview?.disposal &&
      mutate(() =>
        bridge.computeNode.resumeLocalDisposal({
          requestId: overview.disposal!.requestId,
        })
      ),
  };
}
