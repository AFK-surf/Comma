import { useCallback, useEffect, useRef, useState } from "react";
import { useCall, useTopic } from "@comma/core-client";
import { useCommaMessages } from "@comma/i18n/react";
import { Dialog } from "@comma/ui/components/dialog";
import type { ComputeWorkload as CommaComputeWorkload } from "@comma/core/contract";
import { useWorkspacePreference } from "./activeWorkspace";

const preparing = (w: CommaComputeWorkload) =>
  (!!w.deletion && !["complete", "cloud_retired"].includes(w.deletion.phase)) ||
  (w.desired_state === "ready" &&
    ["waiting_connection", "allocating", "starting"].includes(w.phase ?? ""));

const locationUnknown = (w: CommaComputeWorkload) =>
  w.location?.provider !== "agent_vmm" && w.location?.provider !== "cloudflare";

const workloadLabel = (w: CommaComputeWorkload) =>
  w.name || `${w.kind === "shell" ? "Shell" : w.kind} ${w.id.slice(-8)}`;

export function useComputeWorkloadsSection(
  /** Whether this app reaches the Comma cloud (the core reads Compute there). */
  cloud: boolean,
  enabled: boolean,
  observationTick?: number
) {
  const sharedObservation = observationTick !== undefined;
  const m = useCommaMessages();
  const call = useCall();
  const workspacePreference = useWorkspacePreference();
  const [workloadAfter, setWorkloadAfter] = useState("");
  const [hidden, setHidden] = useState(() => document.hidden);
  useEffect(() => {
    const visible = () => setHidden(document.hidden);
    document.addEventListener("visibilitychange", visible);
    return () => document.removeEventListener("visibilitychange", visible);
  }, []);
  // The core reads Compute while the panel shows it (and the page is not hidden).
  const { value: shown } = useTopic(
    enabled && cloud && !hidden && workspacePreference !== undefined
      ? {
          topic: "compute",
          prefer: workspacePreference,
          after: workloadAfter,
          shared: sharedObservation ? "1" : "",
        }
      : null
  );
  const workspaceId = shown?.workspace ?? workspacePreference;
  const projection = shown?.projection ?? undefined;
  const creation = shown?.creation ?? undefined;
  const accepted = shown?.accepted ?? undefined;
  const [environmentChoice, setEnvironmentChoice] = useState("");
  const environmentId = projection?.environments.some(
    (e) => e.id === environmentChoice && e.can_create
  )
    ? environmentChoice
    : (projection?.environments.find((e) => e.can_create)?.id ?? "");
  const [pending, setPending] = useState(false);
  const [actionError, setActionError] = useState("");
  const error = actionError || (shown?.error ? m.compute_read_failed() : "");
  const [mode, setMode] = useState<"create" | "workload" | "owner">();
  const [name, setName] = useState("");
  const [dialog, setDialog] = useState<"rename" | "delete">();
  const [selectedUse, setSelectedUse] =
    useState<NonNullable<CommaComputeWorkload["uses"]>[number]>();
  const [selected, setSelected] = useState<CommaComputeWorkload>();
  const [dialogTarget, setDialogTarget] = useState<CommaComputeWorkload>();
  const selectionEpoch = useRef(0);
  const lock = useRef(false);
  const scope = useRef(workspaceId);
  scope.current = workspaceId;
  useEffect(() => {
    setEnvironmentChoice("");
    setWorkloadAfter("");
    setPending(false);
    setActionError("");
    setMode(undefined);
    selectionEpoch.current++;
    setSelected(undefined);
    setSelectedUse(undefined);
    setDialogTarget(undefined);
    setDialog(undefined);
  }, [workspacePreference]);

  // The local node's tick drives the reads while it is available.
  useEffect(() => {
    if (observationTick !== undefined && enabled)
      void call("compute.observe", {}).catch(() => undefined);
  }, [call, enabled, observationTick]);
  const refresh = useCallback(
    () => void call("compute.refresh", {}).catch(() => undefined),
    [call]
  );

  const create = useCallback(async () => {
    if (!workspaceId || !cloud || lock.current) return;
    const target = creation ?? {
      environmentId,
      ...(name.trim() ? { name: name.trim() } : {}),
    };
    if (!target.environmentId) return;
    const targetScope = workspaceId;
    lock.current = true;
    try {
      setPending(true);
      setActionError("");
      await call("compute.create", {
        workspace: workspaceId,
        environment: target.environmentId,
        ...(target.name ? { name: target.name } : {}),
      });
      if (scope.current === targetScope) setMode(undefined);
    } catch (reason) {
      if (scope.current === targetScope) {
        setMode(undefined);
        const failure = reason as { code?: unknown; status?: unknown } | null;
        setActionError(
          failure?.code === "node_offline"
            ? m.compute_node_offline()
            : failure?.code === "capacity_unavailable"
              ? m.compute_capacity_unavailable()
              : failure?.code === "runtime_template_unavailable"
                ? m.compute_template_unavailable()
                : failure?.status === 403
                  ? m.compute_create_forbidden()
                  : failure?.status === 503
                    ? m.compute_creation_service_failed()
                    : m.compute_creation_unknown()
        );
      }
    } finally {
      lock.current = false;
      if (scope.current === targetScope) setPending(false);
    }
  }, [cloud, call, workspaceId, environmentId, name, creation, m]);
  const close = () => setMode(undefined);
  const stateLabel = (w: CommaComputeWorkload): string =>
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
  const row = rows.find((w) => w.id === selected?.id);
  const current =
    selected && (!row || (selected.revision ?? 0) >= (row.revision ?? 0))
      ? selected
      : row;
  const location = (w: CommaComputeWorkload): string =>
    w.location?.provider === "agent_vmm"
      ? m.compute_location_mac()
      : w.location?.provider === "cloudflare"
        ? m.compute_location_cloud()
        : m.compute_location_unknown();
  const openWorkload = (w: CommaComputeWorkload) => {
    if (!workspaceId || !cloud) return;
    const epoch = ++selectionEpoch.current;
    setSelected(w);
    setMode("workload");
    const targetScope = workspaceId;
    void call("compute.workload", { workspace: workspaceId, id: w.id }).then(
      (workload) => {
        if (scope.current === targetScope && selectionEpoch.current === epoch)
          setSelected(workload);
      },
      () => {
        if (scope.current === targetScope && selectionEpoch.current === epoch)
          setActionError(m.compute_read_failed());
      }
    );
  };
  const retry = async (w: CommaComputeWorkload) => {
    if (
      !workspaceId ||
      !cloud ||
      lock.current ||
      w.revision === undefined ||
      w.generation === undefined
    )
      return;
    const targetScope = workspaceId;
    lock.current = true;
    setPending(true);
    try {
      const workload = await call("compute.retry", {
        workspace: workspaceId,
        id: w.id,
        revision: w.revision,
        generation: w.generation,
      });
      if (scope.current === targetScope) {
        setSelected(workload);
        setActionError("");
      }
    } catch {
      if (scope.current === targetScope)
        setActionError(m.compute_workload_mutation_failed());
    } finally {
      lock.current = false;
      if (scope.current === targetScope) setPending(false);
    }
  };
  const mutate = async () => {
    const targetWorkload = dialogTarget;
    if (
      !targetWorkload ||
      !workspaceId ||
      !cloud ||
      lock.current ||
      targetWorkload.revision === undefined
    )
      return;
    lock.current = true;
    setPending(true);
    setActionError("");
    const targetScope = workspaceId;
    try {
      let workload: CommaComputeWorkload;
      if (dialog === "rename") {
        workload = await call("compute.rename", {
          workspace: workspaceId,
          id: targetWorkload.id,
          revision: targetWorkload.revision,
          name: name.trim(),
        });
      } else {
        if (targetWorkload.generation === undefined) return;
        workload = await call("compute.delete", {
          workspace: workspaceId,
          id: targetWorkload.id,
          revision: targetWorkload.revision,
          generation: targetWorkload.generation,
          ...(targetWorkload.deletion?.request_id
            ? { request: targetWorkload.deletion.request_id }
            : {}),
        });
      }
      if (scope.current === targetScope) {
        setSelected(workload);
        setDialog(undefined);
      }
    } catch {
      if (scope.current === targetScope)
        setActionError(m.compute_workload_mutation_failed());
    } finally {
      lock.current = false;
      if (scope.current === targetScope) setPending(false);
    }
  };
  const canManage = !!projection && projection.can_manage !== false;
  const canPrepare = canManage && !!environmentId;
  const canCreate = canPrepare && !pending && !creation;
  const createUnavailable = (): string => {
    if (!workspaceId) return m.compute_no_workspace();
    const reason = projection?.environments[0]?.create_unavailable_reason;
    if (reason === "template_unavailable") return m.compute_template_unavailable();
    if (reason === "node_unavailable") return m.compute_connection_problem();
    if (reason === "node_not_enabled") return m.compute_node_not_enabled();
    return m.compute_create_unavailable();
  };
  const openCreate = () => {
    if (creation) return;
    setName(m.compute_ui_new_name());
    setMode("create");
  };
  const openDialog = (kind: "rename" | "delete", workload: CommaComputeWorkload) => {
    selectionEpoch.current++;
    setDialogTarget(workload);
    setSelected(workload);
    setName(workloadLabel(workload));
    setDialog(kind);
  };
  const deleteLabel = (w: CommaComputeWorkload): string =>
    w.kind === "shell" ? m.compute_delete_shell() : m.compute_ui_delete_section();
  const openUse = (use: NonNullable<CommaComputeWorkload["uses"]>[number]) => {
    setSelectedUse(use);
    setMode("owner");
  };
  const overlay =
    dialog && dialogTarget ? (
      <Dialog
        isOpen
        isDismissable={!pending}
        title={dialog === "rename" ? m.compute_rename() : deleteLabel(dialogTarget)}
        description={
          dialog === "delete"
            ? m.compute_delete_shell_confirm({ name: workloadLabel(dialogTarget) })
            : undefined
        }
        variant={dialog === "rename" ? "input" : "default"}
        {...(dialog === "rename"
          ? {
              input: {
                label: m.compute_name(),
                value: name,
                maxLength: 80,
                autoFocus: true,
                onChange: (event) => setName(event.target.value),
              },
            }
          : {})}
        onOpenChange={(open) => {
          if (!open) setDialog(undefined);
        }}
        actions={[
          {
            label: m.settings_profile_cancel(),
            hierarchy: "secondary-gray",
            disabled: pending,
            onPress: () => setDialog(undefined),
          },
          {
            label:
              dialog === "rename"
                ? m.compute_save_name()
                : m.compute_ui_delete_section(),
            hierarchy: dialog === "delete" ? "destructive" : "primary",
            disabled: pending || (dialog === "rename" && !name.trim()),
            onPress: () => void mutate(),
          },
        ]}
      >
        {dialog === "delete" && (
          <p className="break-words text-xs font-regular text-quaternary">
            {m.compute_location()}: {location(dialogTarget)}.
            {locationUnknown(dialogTarget) &&
              ` ${m.compute_delete_shell_node_unknown()}`}
          </p>
        )}
        {error ? <p role="alert">{error}</p> : null}
      </Dialog>
    ) : undefined;
  return {
    overlay,
    close,
    workspaceName: projection?.workspace_name,
    projection,
    rows,
    current,
    mode,
    name,
    setName,
    pending,
    error,
    creation,
    canCreate,
    canPrepare,
    canManage,
    createUnavailable,
    create,
    openCreate,
    openWorkload,
    openDialog,
    openUse,
    selectedUse,
    backToWorkload: () => setMode("workload"),
    retry,
    refresh,
    workloadLabel,
    deleteLabel,
    stateLabel,
    location,
    firstPage: () => setWorkloadAfter(""),
    nextPage: () => setWorkloadAfter(projection?.next_workload_cursor ?? ""),
    hasPreviousPage: !!workloadAfter,
  };
}
