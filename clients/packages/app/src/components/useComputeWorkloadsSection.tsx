import { useCallback, useContext, useEffect, useRef, useState } from "react";
import { useCommaMessages } from "@comma/i18n/react";
import {
  Button,
  type SettingsCategoryDetail,
  type SettingsPanelSection,
} from "@comma/ui";
import {
  CommaApiError,
  type CommaApiClient,
  type CommaComputeProjection,
  type CommaComputeWorkload,
} from "../api";
import { readActiveWorkspaceId, subscribeActiveWorkspace } from "./activeWorkspace";
import { CommaAuthContext } from "./auth-context";

type Creation = { requestId: string; environmentId: string };
function readCreation(key: string): Creation | undefined {
  try {
    const value: unknown = JSON.parse(localStorage.getItem(key) ?? "null");
    if (
      value &&
      typeof value === "object" &&
      "requestId" in value &&
      "environmentId" in value &&
      typeof value.requestId === "string" &&
      typeof value.environmentId === "string" &&
      value.requestId.length > 0 &&
      value.requestId.length <= 160 &&
      value.environmentId.length > 0 &&
      value.environmentId.length <= 160
    )
      return { requestId: value.requestId, environmentId: value.environmentId };
  } catch {
    /* A damaged record has no recoverable request identity. */
  }
  return undefined;
}
function clearCreation(key: string, requestId: string) {
  const current = readCreation(key);
  if (current && current.requestId !== requestId) return false;
  if (current) localStorage.removeItem(key);
  return true;
}
const preparing = (w: CommaComputeWorkload) =>
  w.desired_state === "ready" &&
  ["waiting_connection", "allocating", "starting"].includes(w.phase ?? "");

const workloadLabel = (w: CommaComputeWorkload) =>
  `${w.kind === "shell" ? "Shell" : w.kind} ${w.id.slice(-8)}`;

export function useComputeWorkloadsSection(
  api: CommaApiClient,
  enabled: boolean,
  observationTick?: number
) {
  const sharedObservation = observationTick !== undefined;
  const m = useCommaMessages();
  const auth = useContext(CommaAuthContext);
  const [workspaceId, setWorkspaceId] = useState(readActiveWorkspaceId);
  const storageKey = `comma.compute.creation:${encodeURIComponent(auth?.apiBaseUrl ?? "")}:${encodeURIComponent(auth?.userId ?? auth?.userEmail ?? "")}:${workspaceId}`;
  const [projection, setProjection] = useState<CommaComputeProjection>();
  const [environmentId, setEnvironmentId] = useState("");
  const [workloadAfter, setWorkloadAfter] = useState("");
  const [creation, setCreation] = useState<Creation>();
  const [accepted, setAccepted] = useState<CommaComputeWorkload>();
  const [pending, setPending] = useState(false);
  const [error, setError] = useState("");
  const [revision, setRevision] = useState(0);
  const [mode, setMode] = useState<"advanced" | "create" | "workload">();
  const [selected, setSelected] = useState<CommaComputeWorkload>();
  const lock = useRef(false);
  const scope = useRef(storageKey);
  scope.current = storageKey;
  const submitted = useRef<Creation | undefined>(undefined);
  const rounds = useRef(0);
  useEffect(() => subscribeActiveWorkspace(setWorkspaceId), []);
  useEffect(() => {
    setProjection(undefined);
    setEnvironmentId("");
    setWorkloadAfter("");
    setCreation(readCreation(storageKey));
    setAccepted(undefined);
    setPending(false);
    setError("");
    setMode(undefined);
    submitted.current = undefined;
    rounds.current = 0;
  }, [storageKey]);

  const sharedObservationNeeded = useRef(true);
  const loadRef = useRef<(() => Promise<void>) | undefined>(undefined);
  useEffect(() => {
    if (observationTick !== undefined && sharedObservationNeeded.current)
      void loadRef.current?.();
  }, [observationTick]);
  const refresh = useCallback(() => {
    rounds.current = 0;
    sharedObservationNeeded.current = true;
    setRevision((value) => value + 1);
  }, []);
  useEffect(() => {
    if (!enabled || !workspaceId) return;
    const controller = new AbortController();
    let timer: ReturnType<typeof setTimeout> | undefined;
    let reading = false;
    const load = async () => {
      if (
        controller.signal.aborted ||
        document.hidden ||
        reading ||
        rounds.current >= 60
      )
        return;
      if (timer) clearTimeout(timer);
      timer = undefined;
      reading = true;
      rounds.current += 1;
      try {
        const value = await api.getCompute(workspaceId, {
          signal: controller.signal,
          workloadAfter,
        });
        if (controller.signal.aborted) return;
        setProjection(value);
        setError("");
        setEnvironmentId((previous) =>
          value.environments.some((e) => e.id === previous && e.can_create)
            ? previous
            : (value.environments.find((e) => e.can_create)?.id ?? "")
        );
        const saved = readCreation(storageKey) ?? submitted.current;
        let awaiting = false;
        if (saved) {
          submitted.current = saved;
          setCreation(saved);
          try {
            const result = await api.getComputeCreation(workspaceId, saved.requestId, {
              signal: controller.signal,
            });
            if (controller.signal.aborted) return;
            if (clearCreation(storageKey, saved.requestId)) {
              submitted.current = saved;
              setCreation(undefined);
              setAccepted(result.workload);
              awaiting = preparing(result.workload);
            } else {
              setCreation(readCreation(storageKey));
              awaiting = true;
            }
          } catch (reason) {
            if (controller.signal.aborted) return;
            // A not-found read can race the original commit. Keep the same key.
            awaiting = true;
            if (!(reason instanceof CommaApiError && reason.status === 404))
              setError(m.compute_read_failed());
          }
        }
        sharedObservationNeeded.current = awaiting || value.workloads.some(preparing);
        if (
          !document.hidden &&
          (awaiting || value.workloads.some(preparing)) &&
          rounds.current < 60 &&
          !sharedObservation
        )
          timer = setTimeout(() => void load(), 5_000);
      } catch {
        if (!controller.signal.aborted) {
          setError(m.compute_read_failed());
          sharedObservationNeeded.current = true;
          if (!document.hidden && rounds.current < 60 && !sharedObservation)
            timer = setTimeout(() => void load(), 5_000);
        }
      } finally {
        reading = false;
      }
    };
    loadRef.current = load;
    const visible = () => {
      if (!document.hidden) void load();
      else if (timer) clearTimeout(timer);
    };
    document.addEventListener("visibilitychange", visible);
    void load();
    return () => {
      if (loadRef.current === load) loadRef.current = undefined;
      controller.abort();
      if (timer) clearTimeout(timer);
      document.removeEventListener("visibilitychange", visible);
    };
  }, [
    api,
    enabled,
    workspaceId,
    storageKey,
    workloadAfter,
    revision,
    m,
    sharedObservation,
  ]);

  const create = useCallback(async () => {
    if (!workspaceId || lock.current) return;
    const targetKey = storageKey;
    const target = readCreation(targetKey) ??
      creation ??
      submitted.current ?? {
        requestId: crypto.randomUUID(),
        environmentId,
      };
    if (!target.environmentId) return;
    lock.current = true;
    try {
      // Persist before dispatch. If persistence fails, do not send an untracked mutation.
      localStorage.setItem(targetKey, JSON.stringify(target));
      submitted.current = target;
      setCreation(target);
      setPending(true);
      setError("");
      const result = await api.createShellWorkload(
        workspaceId,
        target.environmentId,
        target.requestId
      );
      const currentRequest = clearCreation(targetKey, target.requestId);
      if (scope.current === targetKey && currentRequest) {
        setAccepted(result.workload);
        setCreation(undefined);
        setMode(undefined);
        refresh();
      }
    } catch {
      if (scope.current === targetKey) setError(m.compute_creation_unknown());
    } finally {
      lock.current = false;
      if (scope.current === targetKey) setPending(false);
    }
  }, [api, workspaceId, storageKey, environmentId, creation, m, refresh]);
  const close = () => setMode(undefined);
  const stateLabel = (w: CommaComputeWorkload) =>
    w.desired_state === "draining" || w.observed_state === "draining"
      ? m.compute_work_draining()
      : w.desired_state === "stopped" || w.observed_state === "stopped"
        ? m.compute_work_stopped()
        : w.phase === "waiting_connection"
          ? m.compute_work_waiting_connection()
          : w.phase === "action_required"
            ? m.compute_work_failed()
            : preparing(w)
              ? m.compute_work_preparing()
              : w.observed_state === "ready"
                ? m.compute_work_ready()
                : w.observed_state === "failed"
                  ? m.compute_work_failed()
                  : m.compute_work_other();
  const rows = [...(projection?.workloads ?? [])];
  if (accepted && !rows.some((w) => w.id === accepted.id)) rows.unshift(accepted);
  const section: SettingsPanelSection = {
    id: "compute-node.workloads",
    title: m.compute_workspace_title(),
    items: [
      {
        id: "compute-node.workload-summary",
        title:
          projection?.workspace_name ||
          (workspaceId
            ? m.compute_workspace_label({ id: workspaceId.slice(-8) })
            : m.compute_no_workspace()),
        description:
          error ||
          (!projection
            ? m.compute_loading()
            : rows.length === 0
              ? m.compute_work_empty()
              : m.compute_workspace_description()),
        control: {
          type: "button",
          label: m.compute_workloads_refresh(),
          disabled: !workspaceId || pending,
          onPress: refresh,
        },
      },
      ...(creation
        ? [
            {
              id: "compute-node.creation",
              title: pending
                ? m.compute_workloads_creating()
                : m.compute_creation_unknown(),
              description: m.compute_creation_recovery(),
              control: {
                type: "button" as const,
                label: m.compute_retry_creation(),
                disabled: pending,
                onPress: () => void create(),
              },
            },
          ]
        : []),
      ...rows.map((w) => ({
        id: `compute-node.workload.${w.id}`,
        title: workloadLabel(w),
        description: stateLabel(w),
        control: {
          type: "button" as const,
          label: m.compute_details(),
          onPress: () => {
            setSelected(w);
            setMode("workload");
          },
        },
      })),
      ...(projection?.next_workload_cursor || workloadAfter
        ? [
            {
              id: "compute-node.workload-pages",
              title: m.compute_pages(),
              control: {
                type: "menu" as const,
                label: m.compute_pages(),
                items: [
                  ...(workloadAfter
                    ? [
                        {
                          id: "first",
                          label: m.compute_first_page(),
                          onPress: () => {
                            setWorkloadAfter("");
                            refresh();
                          },
                        },
                      ]
                    : []),
                  ...(projection?.next_workload_cursor
                    ? [
                        {
                          id: "next",
                          label: m.compute_next_page(),
                          onPress: () => {
                            setWorkloadAfter(projection.next_workload_cursor!);
                            refresh();
                          },
                        },
                      ]
                    : []),
                ],
              },
            },
          ]
        : []),
      {
        id: "compute-node.advanced",
        title: m.compute_advanced(),
        description: m.compute_advanced_description(),
        control: {
          type: "button",
          label: m.compute_manage(),
          onPress: () => setMode("advanced"),
        },
      },
    ],
  };
  let detail: SettingsCategoryDetail | undefined;
  if (mode === "advanced" || mode === "create") {
    detail = {
      id: `compute-${mode}`,
      title: mode === "create" ? m.compute_workloads_create() : m.compute_advanced(),
      backLabel: m.compute_back(),
      onBack: close,
      description:
        mode === "create"
          ? m.compute_create_confirm()
          : m.compute_advanced_description(),
      sections: [
        {
          id: "compute-node.shell-form",
          title: m.compute_workloads_environment(),
          items: [
            {
              id: "compute-node.workload-environment",
              title: m.compute_workloads_environment(),
              description: m.compute_workloads_description(),
              control: {
                type: "dropdown",
                value: creation?.environmentId ?? environmentId,
                disabled: pending || !!creation,
                items: (projection?.environments ?? []).map((e) => ({
                  id: e.id,
                  label: `${e.id.slice(-8)} · ${e.can_create ? m.compute_environment_configured() : m.compute_environment_unavailable()}`,
                  disabled: !e.can_create,
                })),
                onChange: setEnvironmentId,
              },
            },
            ...(error ? [{ id: "compute-node.create-error", title: error }] : []),
          ],
        },
      ],
      actions: (
        <Button
          hierarchy="primary"
          isDisabled={pending || !!creation || !environmentId}
          onPress={() => {
            if (mode === "advanced") {
              submitted.current = undefined;
              setMode("create");
            } else void create();
          }}
        >
          {pending
            ? m.compute_workloads_creating()
            : mode === "create"
              ? m.compute_confirm_create()
              : accepted || rows.length
                ? m.compute_create_another()
                : m.compute_workloads_create()}
        </Button>
      ),
    };
  } else if (mode === "workload" && selected) {
    const current = rows.find((w) => w.id === selected.id) ?? selected;
    detail = {
      id: "compute-workload-detail",
      title: workloadLabel(current),
      backLabel: m.compute_back(),
      onBack: close,
      sections: [
        {
          id: "compute-node.workload-detail",
          title: m.compute_details(),
          items: [
            {
              id: "compute-node.workload-state",
              title: stateLabel(current),
              description: error || m.compute_workspace_description(),
            },
            {
              id: "compute-node.workload-id",
              title: m.compute_identifier(),
              description: current.id,
            },
            {
              id: "compute-node.workload-env",
              title: m.compute_workloads_environment(),
              description: current.environment_id,
            },
            {
              id: "compute-node.workload-raw-state",
              title: m.compute_diagnostics(),
              description: `${current.desired_state ?? "unknown"} / ${current.observed_state}`,
            },
            ...(current.updated_at
              ? [
                  {
                    id: "compute-node.workload-time",
                    title: m.compute_last_check(),
                    description: current.updated_at,
                  },
                ]
              : []),
          ],
        },
      ],
      actions: <Button onPress={refresh}>{m.compute_workloads_refresh()}</Button>,
    };
  }
  return { section, detail, close, workspaceName: projection?.workspace_name };
}
