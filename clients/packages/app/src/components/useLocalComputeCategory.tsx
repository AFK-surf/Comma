import { useHostMaintenanceCategory } from "./useHostMaintenanceCategory";
import { useCallback, useEffect, useRef, useState } from "react";
import {
  getNativeBridge,
  type LocalComputeWorkloads,
  type LocalComputeOverview,
} from "@comma/native-bridge";
import { useCommaMessages } from "@comma/i18n/react";
import {
  Button,
  ComputeDiskUsage,
  formatComputeBytes,
  type SettingsCategoryDefinition,
  type SettingsPanelSection,
} from "@comma/ui";

// One visible clock. A tick reads one native page, one disk total, at most one receipt and one cloud mapping batch.
// Workload detail pages are user-triggered; each read path permits one request in flight.
export type ComputePanelDetail = "local" | "maintenance" | "workspace" | "diagnostics";
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
    () => setDetail("maintenance"),
    () => setDetail(undefined),
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
  useEffect(() => {
    if (!visible || !available) return;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const observe = () => {
      if (timer) clearTimeout(timer);
      if (document.hidden) return;
      void refresh();
      setTick((value) => value + 1);
      timer = setTimeout(observe, 5_000);
    };
    document.addEventListener("visibilitychange", observe);
    observe();
    return () => {
      if (timer) clearTimeout(timer);
      epoch.current += 1;
      document.removeEventListener("visibilitychange", observe);
    };
  }, [visible, available, refresh]);
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
  const stateLabel = (state: string) =>
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
  const section: SettingsPanelSection = {
    id: "compute-node.local-resources",
    title: m.compute_disk_title(),
    items: [
      {
        id: "compute-node.local-disk",
        title: m.compute_disk_title(),
        description:
          overview?.availability === "capability_missing"
            ? m.compute_host_update_required()
            : data?.collectedAt
              ? fresh
                ? m.compute_disk_read_at({
                    time: new Date(data.collectedAt).toLocaleString(),
                  })
                : m.compute_disk_old_at({
                    time: new Date(data.collectedAt).toLocaleString(),
                  })
              : m.compute_disk_unavailable(),
        control: {
          type: "button",
          label: m.compute_local_manage(),
          onPress: () => setManaging(true),
        },
        content:
          data?.disk && data.collectedAt ? (
            <>
              <ComputeDiskUsage
                usedBytes={data.disk.usedBytes}
                capacityBytes={data.disk.capacityBytes}
                collectedAt={data.collectedAt}
                environments={
                  fresh
                    ? data.environments.flatMap((row) =>
                        row.privateDiskBytes !== undefined && row.sampledAt
                          ? [
                              {
                                key: row.key,
                                label: m.compute_local_environment({ id: row.label }),
                                bytes: row.privateDiskBytes,
                                sampledAt: row.sampledAt,
                              },
                            ]
                          : []
                      )
                    : []
                }
                onSelect={select}
                labels={{
                  used: m.compute_disk_used(),
                  otherUsed: m.compute_disk_other(),
                  remaining: m.compute_disk_remaining(),
                  detailUnavailable: m.compute_disk_detail_unavailable(),
                  summary: (used, capacity) =>
                    m.compute_disk_summary({ used, capacity }),
                }}
              />
              <p>
                {m.compute_disk_reservation({
                  value: formatComputeBytes(data.disk.importReservationBytes),
                })}
              </p>
            </>
          ) : null,
      },
    ],
  };
  const receipt = overview?.disposal;
  const management: SettingsPanelSection[] = [
    {
      id: "compute-node.local-management",
      title: m.compute_local_manage(),
      items: [
        {
          id: "compute-node.local-refresh",
          title: m.compute_disk_title(),
          description: fresh ? m.compute_local_delete_note() : m.compute_local_failed(),
          control: {
            type: "button",
            label: m.compute_check_status(),
            onPress: () => {
              void refresh();
            },
          },
        },
        ...(error
          ? [
              {
                id: "compute-node.local-error",
                title: m.compute_attention(),
                description: error,
              },
            ]
          : []),
        ...(receipt
          ? [
              {
                id: "compute-node.local-receipt",
                title:
                  receipt.outcome === "completed"
                    ? m.compute_local_delete_completed()
                    : receipt.outcome === "superseded"
                      ? m.compute_local_delete_superseded()
                      : receipt.outcome === "pending"
                        ? m.compute_local_delete_pending()
                        : m.compute_local_delete_unknown(),
                ...(receipt.outcome !== "completed" && receipt.outcome !== "superseded"
                  ? {
                      control: {
                        type: "button" as const,
                        label: m.compute_check_status(),
                        disabled: mutating,
                        onPress: () => {
                          void mutate(() =>
                            bridge.computeNode.resumeLocalDisposal({
                              requestId: receipt.requestId,
                            })
                          );
                        },
                      },
                    }
                  : {}),
              },
            ]
          : []),
        ...(data?.environments ?? []).map((row) => ({
          id: `local-environment.${row.key}`,
          title: m.compute_local_environment({ id: row.label }),
          description: `${fresh ? stateLabel(row.state) : m.compute_local_unknown()} · ${row.privateDiskBytes !== undefined ? formatComputeBytes(row.privateDiskBytes) : m.compute_disk_detail_unavailable()}`,
          content:
            selected === row.key ? (
              <>
                {cloudWorkloads && row.canReadWorkloads ? (
                  <>
                    {cloudWorkloads.workloads.map((work) => (
                      <p key={work.label}>
                        {work.label} ·{" "}
                        {work.state === "ready"
                          ? m.compute_work_ready()
                          : work.state === "stopped"
                            ? m.compute_work_stopped()
                            : work.state === "action_required"
                              ? m.compute_work_failed()
                              : work.state === "waiting_connection"
                                ? m.compute_work_waiting_connection()
                                : work.state === "starting" ||
                                    work.state === "allocating"
                                  ? m.compute_work_preparing()
                                  : work.state === "draining"
                                    ? m.compute_work_draining()
                                    : m.compute_activity_unknown()}
                      </p>
                    ))}
                    {cloudWorkloads.nextCursor ? (
                      <Button
                        hierarchy="tertiary-gray"
                        onPress={() =>
                          void readWorkloads(row.key, cloudWorkloads.nextCursor)
                        }
                      >
                        {m.compute_local_next()}
                      </Button>
                    ) : null}
                  </>
                ) : (
                  <p>{m.compute_local_no_workloads()}</p>
                )}
              </>
            ) : null,
          control: {
            type: "menu" as const,
            label: m.compute_more(),
            disabled:
              !fresh || mutating || maintenance.pending || maintenance.unfinished,
            items: [
              {
                id: "details",
                label: m.compute_details(),
                onPress: () => select(row.key),
              },
              ...(row.canReadWorkloads
                ? [
                    {
                      id: "workloads",
                      label: m.compute_workspace_title(),
                      onPress: () => {
                        select(row.key);
                        void readWorkloads(row.key);
                      },
                    },
                  ]
                : []),
              ...(row.canDisposeLocal
                ? [
                    {
                      id: "delete",
                      label: m.compute_local_delete(),
                      tone: "destructive" as const,
                      onPress: () => {
                        void mutate(() =>
                          bridge.computeNode.disposeLocal({ key: row.key })
                        );
                      },
                    },
                  ]
                : []),
            ],
          },
        })),
        ...(overview?.nextCursor
          ? [
              {
                id: "compute-node.local-next",
                title: m.compute_local_next(),
                control: {
                  type: "button" as const,
                  label: m.compute_local_next(),
                  onPress: () => setCursor(overview.nextCursor),
                },
              },
            ]
          : []),
        ...(cursor
          ? [
              {
                id: "compute-node.local-first",
                title: m.compute_local_previous(),
                control: {
                  type: "button" as const,
                  label: m.compute_local_previous(),
                  onPress: () => setCursor(undefined),
                },
              },
            ]
          : []),
      ],
    },
  ];
  const category: SettingsCategoryDefinition = {
    id: "local-compute",
    icon: "devices",
    label: m.compute_local_manage(),
    sections: [...(available ? [maintenance.section] : []), section],
    ...(detail === "maintenance"
      ? { detail: maintenance.detail }
      : managing
        ? {
            detail: {
              id: "local-compute-management",
              title: m.compute_local_manage(),
              backLabel: m.compute_back(),
              onBack: () => setManaging(false),
              sections: management,
            },
          }
        : {}),
  };
  return {
    category,
    section,
    maintenance,
    disposal: overview?.disposal,
    open: () => setManaging(true),
    tick,
    available,
    managing,
    close: () => setManaging(false),
  };
}
