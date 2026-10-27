import { useComputeRecoverySection } from "./useComputeRecoverySection";
import {
  useLocalComputeCategory,
  type ComputePanelDetail,
} from "./useLocalComputeCategory";
import { useEffect, useRef, useState } from "react";
import { useCommaMessages } from "@comma/i18n/react";
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
  const [confirm, setConfirm] = useState<
    "drain" | "remove" | "repair" | "rebuild" | "abandon"
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
  const maintenanceActive = local.maintenance.pending || local.maintenance.unfinished;
  const completedMaintenance =
    local.maintenance.state?.operation?.outcome === "succeeded"
      ? local.maintenance.state.operation.requestId
      : undefined;
  const maintenanceCheckKey = completedMaintenance
    ? JSON.stringify([completedMaintenance, workspaceId, state?.confirmationId])
    : undefined;
  const currentCheckKey = useRef(maintenanceCheckKey);
  currentCheckKey.current = maintenanceCheckKey;
  const automaticCheck = useRef<string | undefined>(undefined);
  const checkGeneration = useRef(0);
  const [maintenanceCheck, setMaintenanceCheck] = useState<{
    key: string;
    returned: boolean;
  }>();
  const checkWorkspace = () => {
    const key = maintenanceCheckKey;
    if (!key) return void refreshRef.current();
    const generation = ++checkGeneration.current;
    setMaintenanceCheck({ key, returned: false });
    void refreshRef
      .current()
      .then((next) => {
        if (!next) return;
        if (currentCheckKey.current !== key || generation !== checkGeneration.current)
          return;
        setMaintenanceCheck((current) =>
          current?.key === key ? { ...current, returned: true } : current
        );
      })
      .catch(() => {
        // The owner normally records errors itself. A rejected refresh also stays unconfirmed.
      });
  };
  const checkWorkspaceRef = useRef(checkWorkspace);
  checkWorkspaceRef.current = checkWorkspace;
  useEffect(() => {
    if (
      !visible ||
      !node.available ||
      maintenanceActive ||
      !maintenanceCheckKey ||
      document.hidden
    )
      return;
    if (automaticCheck.current === maintenanceCheckKey) return;
    automaticCheck.current = maintenanceCheckKey;
    checkWorkspaceRef.current();
  }, [visible, node.available, maintenanceActive, maintenanceCheckKey, local.tick]);
  useEffect(
    () => () => {
      checkGeneration.current++;
    },
    []
  );
  const workspaceUnconfirmed =
    maintenanceActive ||
    !!(
      maintenanceCheckKey &&
      (maintenanceCheck?.key !== maintenanceCheckKey ||
        !maintenanceCheck.returned ||
        node.pending)
    );
  useEffect(() => {
    setConfirm(undefined);
    target.current = undefined;
    expectedBinding.current = undefined;
  }, [
    state?.confirmationId,
    state?.bindingWorkspaceId,
    state?.bindingInstallationId,
    state?.bindingRevision,
    workspaceId,
    maintenanceActive,
    completedMaintenance,
  ]);
  const eligible = node.available && state?.eligibility.eligible !== false;
  const busy =
    workspaceUnconfirmed ||
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
  const canManage = workloads.canManage;
  const readOnly = !!workloads.projection && !workloads.canManage;
  const card = computeNodeCard(
    {
      state,
      maintenance: {
        state: local.maintenance.state,
        active: maintenanceActive && !local.maintenance.failed,
        title: local.maintenance.title,
      },
      workspaceUnconfirmed: workspaceUnconfirmed && !local.maintenance.failed,
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
          installationId: state?.bindingInstallationId ?? null,
          confirmationId: state?.confirmationId,
          bindingRevision: state?.bindingRevision ?? state?.revision ?? 1,
        }
      : undefined;
    setConfirm(action);
  };
  // Closes an install request that the cloud never handed over; Main decides when that is possible.
  const canAbandon = !!(eligible && !busy && binding && state?.canAbandonRequest);
  /** The local settings maintenance entry: it shows the progress page. Main asks for native confirmation. */
  const startMaintenance = (action: "update" | "reinstall" | "uninstall" | "clear") => {
    const original = local.maintenance.state?.operation?.requestId;
    workloads.close();
    setDetail("maintenance");
    void local.maintenance.submit(action).then((next) => {
      if (next && (!next.operation || next.operation.requestId === original))
        setDetail("settings");
    });
  };
  /** Runs one card action. Enabling binds the one workspace the card names, so it needs no dialog. */
  const run = (action: ComputeCardActionId) => {
    const workspace = binding ?? workspaceId;
    switch (action) {
      case "enable":
      case "retry":
        if (workspace)
          void node.configure({ desiredEnabled: true, workspaceId: workspace });
        return;
      case "remove":
        openConfirm("remove");
        return;
      case "recover":
        workloads.close();
        setDetail("authorization");
        void recovery.discover();
        return;
      case "update_host":
        void local.maintenance.submit(
          local.maintenance.needsInstall ? "reinstall" : "update"
        );
        return;
      case "reinstall_reset":
        void local.maintenance.submit("reinstall_reset");
        return;
      case "reset_local_record":
        void node.resetLocalRecord().then(() => local.maintenance.refresh());
        return;
      case "manage_storage":
        workloads.close();
        setDetail("local");
        return;
      case "resume_maintenance":
        local.maintenance.resume();
        return;
      case "check_status":
        checkWorkspace();
        return;
    }
  };
  /** Whether a card action can run now. Local maintenance actions wait only for their own request. */
  const canRun = (action: ComputeCardActionId) =>
    action === "reinstall_reset" || action === "resume_maintenance"
      ? !local.maintenance.pending
      : action === "manage_storage"
        ? true
        : action === "check_status"
          ? !node.pending
          : eligible && !busy;
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
    workspaceUnconfirmed,
    maintenanceActive,
    busy,
    binding,
    eligible,
    canManage,
    readOnly,
    canAbandon,
    card,
    run,
    canRun,
    startMaintenance,
    openConfirm,
    checkWorkspace,
    nodeOverlay: confirm ? (
      <Dialog
        isOpen
        isDismissable
        title={
          confirm === "abandon"
            ? m.compute_close_request()
            : confirm === "drain"
              ? m.compute_stop()
              : confirm === "remove"
                ? m.settings_compute_node_remove()
                : m.settings_compute_node_repair()
        }
        description={`${m.compute_target({ workspace: workspaceLabel(target.current) })} ${confirm === "abandon" ? m.compute_close_request_confirm() : confirm === "drain" ? m.compute_stop_confirm() : confirm === "remove" ? m.compute_remove_confirm() : m.compute_repair_warning()}`}
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
              confirm === "abandon"
                ? m.compute_close_request()
                : confirm === "drain"
                  ? m.compute_stop()
                  : confirm === "remove"
                    ? m.settings_compute_node_remove()
                    : m.settings_compute_node_repair(),
            hierarchy: "primary",
            disabled: busy,
            onPress: () => {
              const action = confirm;
              setConfirm(undefined);
              if (action === "drain" && expectedBinding.current)
                void node.drain(expectedBinding.current);
              else if (action === "remove" && expectedBinding.current)
                void node.remove(expectedBinding.current);
              else if (action === "abandon" && expectedBinding.current)
                void node.abandon(expectedBinding.current);
              else if (action === "repair") void node.repair();
              else if (action === "rebuild") void node.rebuild();
            },
          },
        ]}
      />
    ) : undefined,
  };
}
