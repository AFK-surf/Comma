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

const workloadLabel = (w: CommaComputeWorkload) =>
  w.name || `${w.kind === "shell" ? "Shell" : w.kind} ${w.id.slice(-8)}`;

/** The server says whether a member may retry; business owners recover their own Workloads. */
const needsRetry = (w: Pick<CommaComputeWorkload, "actions" | "generation">) =>
  w.actions?.retry === true && w.generation !== undefined;

/** The devices list's names, by Comma Device id, and this device's id. */
export interface ComputeWorkloadDevices {
  names: ReadonlyMap<string, string>;
  localId?: string | undefined;
}

export function useComputeWorkloadsSection(
  /** Whether this app reaches the Comma cloud (the core reads Compute there). */
  cloud: boolean,
  enabled: boolean,
  observationTick?: number,
  devices?: ComputeWorkloadDevices
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
  const [createActionError, setCreateError] = useState("");
  const createError: string =
    createActionError ||
    (shown?.creationReadError ? m.compute_detail_read_failed() : "");
  const [detailError, setDetailError] = useState("");
  const [dialogError, setDialogError] = useState("");
  const [retryError, setRetryError] = useState<{
    id: string;
    message: string;
    revision?: number | undefined;
    generation?: number | undefined;
  }>();
  const error: string = shown?.error ? m.compute_read_failed() : "";
  const deletion = shown?.deletion;
  const rowActionError: { id: string; message: string } | undefined =
    deletion?.uncertain
      ? { id: deletion.workloadId, message: m.compute_operation_unknown() }
      : retryError;
  const [mode, setMode] = useState<"create" | "workload">();
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
    setCreateError("");
    setDetailError("");
    setDialogError("");
    setRetryError(undefined);
    setMode(undefined);
    selectionEpoch.current++;
    setSelected(undefined);
    setSelectedUse(undefined);
    setDialogTarget(undefined);
    setDialog(undefined);
  }, [workspacePreference]);

  // The local node's tick drives the reads while it is available.
  useEffect(() => {
    if (observationTick !== undefined && enabled && !hidden)
      void call("compute.observe", {}).catch(() => undefined);
  }, [call, enabled, hidden, observationTick]);
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
      setCreateError("");
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
        setCreateError(
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
  const close = () => {
    selectionEpoch.current++;
    setDetailError("");
    setMode(undefined);
  };
  const observedCreation = useRef<string | undefined>(undefined);
  useEffect(() => {
    if (creation) observedCreation.current = creation.requestId;
    else if (observedCreation.current) {
      observedCreation.current = undefined;
      setCreateError("");
    }
  }, [creation]);
  useEffect(() => {
    if (!retryError) return;
    const row = projection?.workloads.find((w) => w.id === retryError.id);
    if (
      row &&
      row.generation === retryError.generation &&
      (row.revision ?? 0) > (retryError.revision ?? 0) &&
      ((row.phase === "ready" && row.observed_state === "ready" && !row.problem) ||
        ["deleted", "cloud_retired"].includes(row.phase ?? ""))
    )
      setRetryError(undefined);
  }, [projection, retryError]);
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
  const observed = deletion?.workload;
  const terminalTarget = (w: CommaComputeWorkload) =>
    !!deletion?.terminal &&
    w.id === deletion.workloadId &&
    w.generation === deletion.generation;
  const rows = [...(projection?.workloads ?? [])]
    .map((row) =>
      observed?.id === row.id && (observed.revision ?? 0) >= (row.revision ?? 0)
        ? observed
        : row
    )
    .filter(
      (row) =>
        !terminalTarget(row) &&
        !["deleted", "cloud_retired"].includes(row.phase ?? "") &&
        !["complete", "cloud_retired"].includes(row.deletion?.phase ?? "")
    );
  if (
    observed &&
    !["deleted", "cloud_retired"].includes(observed.phase ?? "") &&
    !["complete", "cloud_retired"].includes(observed.deletion?.phase ?? "") &&
    !rows.some((row) => row.id === observed.id)
  )
    rows.unshift(observed);
  if (
    accepted &&
    !terminalTarget(accepted) &&
    !["deleted", "cloud_retired"].includes(accepted.phase ?? "") &&
    !["complete", "cloud_retired"].includes(accepted.deletion?.phase ?? "") &&
    !rows.some((w) => w.id === accepted.id)
  )
    rows.unshift(accepted);
  const row = rows.find((w) => w.id === selected?.id);
  const observedDeletion =
    selected && deletion?.workload?.id === selected.id ? deletion.workload : undefined;
  const listedCurrent =
    selected && (!row || (selected.revision ?? 0) >= (row.revision ?? 0))
      ? selected
      : row && selected?.generation === row.generation
        ? { ...selected, ...row }
        : row;
  // Lists omit detail-only facts. An exact detail wins ties; matching owner receipts can still advance its status.
  const current =
    observedDeletion &&
    (!listedCurrent ||
      observedDeletion.generation === undefined ||
      listedCurrent.generation === undefined ||
      observedDeletion.generation >= listedCurrent.generation) &&
    (!listedCurrent ||
      (observedDeletion.revision ?? 0) >= (listedCurrent.revision ?? 0))
      ? listedCurrent && listedCurrent.generation === observedDeletion.generation
        ? {
            ...listedCurrent,
            ...observedDeletion,
            name: observedDeletion.name ?? listedCurrent.name,
            location: observedDeletion.location ?? listedCurrent.location,
          }
        : observedDeletion
      : listedCurrent;
  const location = (w: Pick<CommaComputeWorkload, "location">): string => {
    if (w.location?.provider === "cloudflare") return m.compute_location_cloud();
    if (w.location?.provider !== "agent_vmm") return m.compute_location_unknown();
    const device = w.location.device_id;
    if (device && device === devices?.localId) return m.compute_location_this_device();
    return (device && devices?.names.get(device)) || m.compute_location_device();
  };
  /** One short reason while the current generation has a problem. */
  const problemReason = (
    w: Pick<CommaComputeWorkload, "problem">
  ): string | undefined => {
    switch (w.problem?.code) {
      case undefined:
        return undefined;
      case "capacity_unavailable":
        return m.compute_workload_problem_capacity_unavailable();
      case "image_unavailable":
        return m.compute_workload_problem_image_unavailable();
      case "runtime_instance_changed":
        return m.compute_workload_problem_runtime_instance_changed();
      case "host_unreachable":
        return m.compute_workload_problem_host_unreachable();
      default:
        return m.compute_workload_problem_other();
    }
  };
  const openWorkload = (w: CommaComputeWorkload) => {
    if (!workspaceId || !cloud) return;
    const epoch = ++selectionEpoch.current;
    setSelected(w);
    setCreateError("");
    setDetailError("");
    setMode("workload");
    const targetScope = workspaceId;
    void call("compute.workload", { workspace: workspaceId, id: w.id }).then(
      (workload) => {
        if (scope.current === targetScope && selectionEpoch.current === epoch) {
          setSelected(workload);
          setDetailError("");
        }
      },
      () => {
        if (scope.current === targetScope && selectionEpoch.current === epoch)
          setDetailError(m.compute_detail_read_failed());
      }
    );
  };
  const refreshDetail = () => {
    if (selected) openWorkload(selected);
  };
  const retry = async (w: Pick<CommaComputeWorkload, "id" | "generation">) => {
    if (!workspaceId || !cloud || lock.current || w.generation === undefined) return;
    const targetScope = workspaceId;
    lock.current = true;
    setPending(true);
    try {
      const workload = await call("compute.retry", {
        workspace: workspaceId,
        id: w.id,
        generation: w.generation,
      });
      if (scope.current === targetScope) {
        setSelected(workload);
        setRetryError(undefined);
      }
    } catch {
      if (scope.current === targetScope)
        setRetryError({
          id: w.id,
          message: m.compute_workload_mutation_failed(),
          revision: projection?.workloads.find((candidate) => candidate.id === w.id)
            ?.revision,
          generation: w.generation,
        });
    } finally {
      lock.current = false;
      if (scope.current === targetScope) setPending(false);
    }
  };
  const mutate = async () => {
    const targetWorkload = dialogTarget;
    if (!targetWorkload || !workspaceId || !cloud || lock.current) return;
    lock.current = true;
    setPending(true);
    setDialogError("");
    const targetScope = workspaceId;
    try {
      let workload: CommaComputeWorkload;
      if (dialog === "rename") {
        workload = await call("compute.rename", {
          workspace: workspaceId,
          id: targetWorkload.id,
          name: name.trim(),
        });
      } else {
        if (targetWorkload.generation === undefined) return;
        workload = await call("compute.delete", {
          workspace: workspaceId,
          id: targetWorkload.id,
          generation: targetWorkload.generation,
          // Every explicit Delete dialog is a fresh confirmation; core checks whether legacy recovery needs it.
          confirmLegacy: true,
          ...(targetWorkload.deletion?.request_id
            ? { request: targetWorkload.deletion.request_id }
            : {}),
        });
      }
      if (scope.current === targetScope) {
        setSelected(workload);
        setDialog(undefined);
      }
    } catch (reason) {
      if (scope.current === targetScope) {
        const code = (reason as { code?: string } | null)?.code;
        const refused =
          code &&
          [
            "invalid_deletion_request",
            "revision_conflict",
            "stale_generation",
            "deletion_in_progress",
            "business_owner_required",
            "update_in_progress",
            "unsupported_provider",
            "shared_allocation",
          ].includes(code);
        if (dialog === "delete" && !refused) setDialog(undefined);
        else
          setDialogError(
            dialog === "delete"
              ? code === "revision_conflict" || code === "stale_generation"
                ? m.compute_delete_generation_changed()
                : code === "business_owner_required"
                  ? m.compute_delete_business_owner()
                  : code === "shared_allocation"
                    ? m.compute_delete_shared_allocation()
                    : code === "update_in_progress"
                      ? m.compute_delete_update_in_progress()
                      : code === "deletion_in_progress"
                        ? m.compute_delete_in_progress()
                        : code === "unsupported_provider"
                          ? m.compute_delete_unsupported_provider()
                          : m.compute_delete_refused()
              : m.compute_workload_mutation_failed()
          );
      }
    } finally {
      lock.current = false;
      if (scope.current === targetScope) setPending(false);
    }
  };
  const checkDeletion = async () => {
    if (!workspaceId || !deletion || lock.current) return;
    const targetScope = workspaceId;
    lock.current = true;
    setPending(true);
    try {
      await call("compute.workload", {
        workspace: workspaceId,
        id: deletion.workloadId,
      });
    } catch {
      /* The original request stays uncertain; absence or an unreadable owner is not completion. */
    } finally {
      lock.current = false;
      if (scope.current === targetScope) setPending(false);
    }
  };
  const resumeDeletion = async () => {
    if (
      !workspaceId ||
      !deletion?.uncertain ||
      deletion.generation === undefined ||
      lock.current
    )
      return;
    const targetScope = workspaceId;
    lock.current = true;
    setPending(true);
    try {
      const workload = await call("compute.delete", {
        workspace: workspaceId,
        id: deletion.workloadId,
        generation: deletion.generation,
        request: deletion.requestId,
      });
      if (scope.current === targetScope && selected?.id === workload.id)
        setSelected(workload);
    } catch {
      /* Core retains the same request and its result-check feedback. */
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
    setCreateError("");
    setName(m.compute_ui_new_name());
    setMode("create");
  };
  const openDialog = (kind: "rename" | "delete", workload: CommaComputeWorkload) => {
    selectionEpoch.current++;
    setDialogError("");
    setCreateError("");
    setDetailError("");
    setDialogTarget(workload);
    setSelected(workload);
    setName(workloadLabel(workload));
    setDialog(kind);
  };
  const deleteLabel = (w: CommaComputeWorkload): string =>
    w.kind === "shell" ? m.compute_delete_shell() : m.compute_ui_delete_section();
  const openUse = (use: NonNullable<CommaComputeWorkload["uses"]>[number]) => {
    setSelectedUse(use);
    setMode("workload");
  };
  const overlay =
    dialog && dialogTarget ? (
      <Dialog
        isOpen
        isDismissable={!pending}
        title={
          dialog === "rename"
            ? m.compute_rename()
            : m.compute_delete_workload_title({ name: workloadLabel(dialogTarget) })
        }
        description={dialog === "delete" ? m.compute_delete_shell_confirm() : undefined}
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
                : m.compute_delete_workload_action(),
            hierarchy: dialog === "delete" ? "destructive" : "primary",
            disabled: pending || (dialog === "rename" && !name.trim()),
            onPress: () => void mutate(),
          },
        ]}
      >
        {dialog === "delete" &&
          (dialogTarget.location?.provider === "cloudflare" ||
            (dialogTarget.location?.device_id &&
              (dialogTarget.location.device_id === devices?.localId ||
                devices?.names.get(dialogTarget.location.device_id)))) && (
            <p className="break-words text-xs font-regular text-quaternary">
              {m.compute_location()}: {location(dialogTarget)}.
            </p>
          )}
        {dialogError ? <p role="alert">{dialogError}</p> : null}
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
    observationPaused: shown?.observationPaused ?? false,
    createError,
    detailError,
    rowActionError,
    deleteUncertainId: deletion?.uncertain ? deletion.workloadId : undefined,
    legacyDeleteTargetId:
      deletion?.uncertain && deletion.generation === undefined
        ? deletion.workloadId
        : undefined,
    canContinueDeletion:
      !!deletion?.uncertain &&
      deletion.generation !== undefined &&
      deletion.canContinue !== false,
    resumeDeletion,
    checkDeletion,
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
    refreshDetail,
    workloadLabel,
    deleteLabel,
    stateLabel,
    location,
    problemReason,
    needsRetry,
    firstPage: () => setWorkloadAfter(""),
    nextPage: () => setWorkloadAfter(projection?.next_workload_cursor ?? ""),
    hasPreviousPage: !!workloadAfter,
  };
}
