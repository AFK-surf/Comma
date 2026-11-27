import { useComputeRecoverySection } from "./useComputeRecoverySection";
import {
  useLocalComputeCategory,
  type ComputePanelDetail,
} from "./useLocalComputeCategory";
import { useEffect, useRef, useState } from "react";
import { useCommaMessages } from "@comma/i18n/react";
import { uiClock } from "@comma/ui/clock";
import { Dialog } from "@comma/ui/components/dialog";
import type { ComputeNodeExpectedBinding } from "@comma/native-bridge";
import { useActiveWorkspaceId } from "./activeWorkspace";
import { useComputeNode } from "./useComputeNode";
import { computeNodeCard, type ComputeCardActionId } from "./computeNodeCard";
import {
  useComputeWorkloadsSection,
  type ComputeWorkloadDevices,
} from "./useComputeWorkloadsSection";

export function useComputeSettingsController(
  /** Whether this app reaches the Comma cloud (a local-only login entry does not). */
  hasCloud: boolean,
  visible: boolean,
  /** The devices list, which names a workload's device. */
  devices?: ComputeWorkloadDevices
) {
  const m = useCommaMessages();
  const node = useComputeNode();
  const workspaceId = useActiveWorkspaceId();
  const [detail, setDetail] = useState<ComputePanelDetail | undefined>(
    hasCloud ? undefined : "settings"
  );
  const local = useLocalComputeCategory(visible, workspaceId, {
    navigation: { detail, setDetail },
    updateRequired: node.state?.issue === "capability_missing",
  });
  const workloads = useComputeWorkloadsSection(
    hasCloud,
    visible && hasCloud,
    local.available ? local.tick : undefined,
    devices
  );
  const refreshWorkloads = workloads.refresh;
  const [confirm, setConfirm] = useState<"drain" | "remove" | "recover">();
  const [maintenanceConfirm, setMaintenanceConfirm] = useState<
    "repair" | "reset" | "uninstall"
  >();
  const target = useRef<string | undefined>(undefined);
  const expectedBinding = useRef<ComputeNodeExpectedBinding | undefined>(undefined);
  const refreshRef = useRef(node.refresh);
  refreshRef.current = node.refresh;
  useEffect(() => {
    if (!visible || !hasCloud || !node.available || document.hidden) return;
    void refreshRef.current();
  }, [visible, node.available, hasCloud]);
  const state = node.state;
  // Native ownership and operation transitions invalidate even a cached all-ready page.
  // Reuse the page's existing observer; metadata revisions and sample times do not trigger reads.
  const nativeProjectionKey = JSON.stringify([
    state?.bindingWorkspaceId,
    state?.bindingRegistrationId,
    state?.desiredEnabled,
    state?.status,
    state?.facets.workActivity,
    state?.operation?.requestId,
    state?.operation?.outcome,
  ]);
  const previousNativeProjection = useRef(nativeProjectionKey);
  useEffect(() => {
    const changed = previousNativeProjection.current !== nativeProjectionKey;
    previousNativeProjection.current = nativeProjectionKey;
    if (changed && visible && hasCloud && !document.hidden) refreshWorkloads();
  }, [nativeProjectionKey, visible, hasCloud, refreshWorkloads]);
  useEffect(() => {
    if (!visible || !hasCloud) return undefined;
    let lastFocusRefreshAt = 0;
    const onFocus = () => {
      if (document.visibilityState !== "visible") return;
      const now = uiClock.now();
      if (now - lastFocusRefreshAt < 2_000) return;
      lastFocusRefreshAt = now;
      if (node.available) void refreshRef.current();
      refreshWorkloads();
    };
    window.addEventListener("focus", onFocus);
    return () => window.removeEventListener("focus", onFocus);
  }, [visible, hasCloud, node.available, refreshWorkloads]);
  const maintenanceActive = local.maintenance.pending || local.maintenance.unfinished;
  const checkWorkspace = () => {
    void refreshRef.current();
    void local.maintenance.refresh();
  };
  useEffect(() => {
    setConfirm(undefined);
    setMaintenanceConfirm(undefined);
    target.current = undefined;
    expectedBinding.current = undefined;
  }, [
    state?.confirmationId,
    state?.bindingWorkspaceId,
    state?.bindingRegistrationId,
    state?.bindingRevision,
    workspaceId,
    maintenanceActive,
  ]);
  const eligible = node.available && state?.eligibility.eligible !== false;
  const busy =
    local.maintenance.pending ||
    local.maintenance.unfinished ||
    node.pending ||
    !!(state?.operation?.outcome === "pending" && state.status === "processing");
  const binding = state?.bindingWorkspaceId;
  const recovery = useComputeRecoverySection(
    workspaceId,
    state?.confirmationId,
    () => void node.refresh()
  );
  const workspaceLabel = (id: string | undefined): string =>
    id === workspaceId && workloads.workspaceName
      ? workloads.workspaceName
      : id
        ? m.compute_workspace_label({ id: id.slice(-8) })
        : m.compute_no_workspace();
  // A reader sees the state; Main checks the binding owner of every connection action again.
  // Only enter read-only when the cloud explicitly returned can_manage === false.
  const readOnly = !!workloads.projection && !workloads.canManage;
  const canManage = !readOnly;
  const card = computeNodeCard(
    {
      state,
      maintenance: {
        state: local.maintenance.state,
        active:
          maintenanceActive && (!local.maintenance.failed || local.maintenance.pending),
        pending: local.maintenance.pending,
        title: local.maintenance.title,
      },
      readFailed: !!node.error,
      workspace: workspaceLabel(binding ?? workspaceId),
      canManage,
      readOnly,
    },
    m
  );
  const openConfirm = (action: NonNullable<typeof confirm>) => {
    target.current = binding ?? workspaceId;
    expectedBinding.current = binding
      ? {
          workspaceId: binding,
          registrationId: state?.bindingRegistrationId ?? null,
          confirmationId: state?.confirmationId,
          bindingRevision: state?.bindingRevision ?? state?.revision ?? 1,
        }
      : undefined;
    setConfirm(action);
  };
  // Closes an install request that the cloud never handed over; Main decides when that is possible.
  const startMaintenance = (
    action:
      | "update"
      | "reinstall"
      | "uninstall"
      | "uninstall_reset"
      | "clear"
      | "reinstall_reset"
  ) => {
    workloads.close();
    setDetail("settings");
    void local.maintenance.submit(action);
  };
  const openMaintenanceConfirm = (action: "repair" | "reset" | "uninstall") => {
    setMaintenanceConfirm(action);
  };
  /** Runs one card action. Enabling binds the one workspace the card names, so it needs no dialog. */
  const run = (action: ComputeCardActionId) => {
    const workspace = binding ?? workspaceId;
    switch (action) {
      case "enable":
        if (workspace)
          void node.configure({ desiredEnabled: true, workspaceId: workspace });
        return;
      case "retry":
        void node.continue();
        return;
      case "remove":
        openConfirm("remove");
        return;
      case "recover":
        if (state?.bindingRegistrationId) openConfirm("recover");
        else {
          workloads.close();
          setDetail("authorization");
          void recovery.discover();
        }
        return;
      case "update_host":
        void local.maintenance.submit(
          local.maintenance.needsInstall ? "reinstall" : "update"
        );
        return;
      case "manage_storage":
        workloads.close();
        setDetail("settings");
        return;
      case "resume_maintenance":
        local.maintenance.resume();
        return;
      case "reinstall_reset":
        startMaintenance("reinstall_reset");
        return;
      case "check_status":
        checkWorkspace();
        return;
    }
  };
  /** Whether a card action can run now. Local maintenance actions wait only for their own request. */
  const canRun = (action: ComputeCardActionId) =>
    action === "manage_storage"
      ? true
      : action === "resume_maintenance" || action === "reinstall_reset"
        ? !local.maintenance.pending
        : eligible && !node.pending;
  return {
    node,
    local,
    workloads,
    recovery,
    state,
    detail,
    setDetail,
    workspaceId,
    localOnly: !hasCloud,
    workspaceLabel,
    maintenanceActive,
    busy,
    binding,
    eligible,
    canManage,
    readOnly,
    card,
    run,
    canRun,
    startMaintenance,
    openMaintenanceConfirm,
    openConfirm,
    checkWorkspace,
    nodeOverlay: confirm ? (
      <Dialog
        isOpen
        isDismissable
        title={
          confirm === "recover"
            ? m.compute_recovery_title()
            : confirm === "drain"
              ? m.compute_stop()
              : confirm === "remove"
                ? m.settings_compute_node_remove()
                : m.settings_compute_node_repair()
        }
        description={`${m.compute_target({ workspace: workspaceLabel(target.current) })} ${confirm === "recover" ? m.compute_recovery_explanation() : confirm === "drain" ? m.compute_stop_confirm() : confirm === "remove" ? m.compute_remove_confirm() : m.compute_repair_warning()}`}
        onOpenChange={(open) => {
          if (!open) setConfirm(undefined);
        }}
        actions={[
          {
            label: m.settings_profile_cancel(),
            hierarchy: "secondary-gray",
            onPress: () => setConfirm(undefined),
          },
          {
            label:
              confirm === "recover"
                ? m.compute_recovery_title()
                : confirm === "drain"
                  ? m.compute_stop()
                  : confirm === "remove"
                    ? m.settings_compute_node_remove()
                    : m.settings_compute_node_repair(),
            hierarchy: "primary",
            disabled: false,
            onPress: () => {
              const action = confirm;
              setConfirm(undefined);
              if (action === "drain" && expectedBinding.current)
                void node.drain(expectedBinding.current);
              else if (action === "remove" && expectedBinding.current)
                void node.remove(expectedBinding.current);
              else if (action === "recover" && expectedBinding.current)
                void node.reauthorize(expectedBinding.current);
            },
          },
        ]}
      />
    ) : maintenanceConfirm ? (
      <Dialog
        isOpen
        isDismissable
        title={
          maintenanceConfirm === "repair"
            ? m.compute_sandbox_repair_title()
            : maintenanceConfirm === "reset"
              ? m.compute_sandbox_reset_title()
              : m.compute_sandbox_uninstall_title()
        }
        description={
          maintenanceConfirm === "repair"
            ? m.compute_sandbox_repair_confirm()
            : maintenanceConfirm === "reset"
              ? m.compute_sandbox_reset_confirm()
              : m.compute_sandbox_uninstall_confirm()
        }
        onOpenChange={(open) => {
          if (!open) setMaintenanceConfirm(undefined);
        }}
        actions={[
          {
            label: m.settings_profile_cancel(),
            hierarchy: "secondary-gray",
            onPress: () => setMaintenanceConfirm(undefined),
          },
          {
            label:
              maintenanceConfirm === "repair"
                ? m.compute_sandbox_repair_confirm_action()
                : maintenanceConfirm === "reset"
                  ? m.compute_sandbox_reset_confirm_action()
                  : m.compute_sandbox_uninstall_confirm_action(),
            hierarchy: maintenanceConfirm === "repair" ? "primary" : "destructive",
            disabled: false,
            onPress: () => {
              const action = maintenanceConfirm;
              setMaintenanceConfirm(undefined);
              if (action === "repair") startMaintenance("reinstall");
              else if (action === "reset") startMaintenance("reinstall_reset");
              else startMaintenance("uninstall_reset");
            },
          },
        ]}
      />
    ) : undefined,
  };
}
