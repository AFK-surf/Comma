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
import { computeProblemMessage, useComputeNode } from "./useComputeNode";
import { useComputeWorkloadsSection } from "./useComputeWorkloadsSection";

export function useComputeSettingsController(
  /** Whether this app reaches the Comma cloud (a local-only login entry does not). */
  hasCloud: boolean,
  visible: boolean
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
    local.available ? local.tick : undefined
  );
  const [confirm, setConfirm] = useState<
    "enable" | "drain" | "remove" | "repair" | "rebuild" | "abandon"
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
    () => void node.refresh(),
    workloads.workspaceName ?? undefined
  );
  const boundElsewhere = !!binding && binding !== workspaceId;
  const workspaceLabel = (id: string | undefined): string =>
    id === workspaceId && workloads.workspaceName
      ? workloads.workspaceName
      : id
        ? m.compute_workspace_label({ id: id.slice(-8) })
        : m.compute_no_workspace();
  const status: string = workspaceUnconfirmed
    ? m.compute_operation_unknown()
    : !node.available || state?.eligibility.eligible === false
      ? m.compute_unsupported()
      : state?.remoteRevocationConfirmed === false
        ? m.compute_local_removed()
        : state?.status === "removed"
          ? m.compute_removed()
          : state?.status === "not_set"
            ? m.compute_not_enabled()
            : state?.operation?.outcome === "pending" && state.status === "processing"
              ? state?.operation?.kind === "drain"
                ? m.compute_stopping()
                : state?.operation?.kind === "remove"
                  ? m.compute_removing()
                  : m.compute_preparing()
              : state?.status === "ready" && state.observationFresh
                ? m.compute_available()
                : state?.status === "stopped"
                  ? m.compute_stopped()
                  : m.compute_attention();
  const reason: string = workspaceUnconfirmed
    ? node.error
      ? m.compute_read_failed()
      : m.compute_maintenance_checking()
    : state?.issue === "removal_incomplete"
      ? m.compute_removal_incomplete()
      : state?.issue === "authorization_unavailable"
        ? m.compute_current_login_unavailable()
        : state?.issue === "shell_initialization_pending"
          ? m.compute_shell_pending()
          : state?.issue === "operation_unknown"
            ? m.compute_operation_unknown()
            : state?.issue === "capability_missing"
              ? m.compute_host_update_required()
              : state?.issue === "connection"
                ? m.compute_connection_problem()
                : state?.issue === "authorization"
                  ? m.compute_authorization_problem()
                  : state?.issue === "preparation_failed"
                    ? m.compute_preparation_problem()
                    : state?.issue === "enable_incomplete"
                      ? m.compute_enable_incomplete()
                      : m.compute_node_description();
  const problem = state?.problem ? computeProblemMessage(state.problem, m) : undefined;
  // Main keeps the failed component setup's own error until the next attempt; it shows under the generic line.
  const reasonDetail =
    !workspaceUnconfirmed && state?.issue === "preparation_failed"
      ? state.preparation?.error
      : undefined;
  const canFinishRemove = !!(
    eligible &&
    !busy &&
    state?.recoveryActions?.includes("finish_remove")
  );
  const canEnable = !!(
    eligible &&
    !busy &&
    !boundElsewhere &&
    state?.issue !== "capability_missing" &&
    state?.issue !== "authorization_unavailable" &&
    state?.issue !== "removal_incomplete" &&
    ((!state?.desiredEnabled && state?.operation?.outcome !== "unknown") ||
      state.recoveryActions?.includes("continue_enable") ||
      state.recoveryActions?.includes("continue_shell"))
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
  const recoveryNeeded =
    state?.issue === "authorization" || state?.issue === "authorization_unavailable";
  // Closes an install request that the cloud never handed over; Main decides when that is possible.
  const canAbandon = !!(eligible && !busy && binding && state?.canAbandonRequest);
  /** The same maintenance entry as the local settings page; Main asks for native confirmation. */
  const startMaintenance = (action: "update" | "reinstall" | "uninstall" | "clear") => {
    const original = local.maintenance.state?.operation?.requestId;
    workloads.close();
    setDetail("maintenance");
    void local.maintenance.submit(action).then((next) => {
      if (next && (!next.operation || next.operation.requestId === original))
        setDetail("settings");
    });
  };
  const setupDone =
    state?.setup?.components === "ready" &&
    state.setup.connection === "ready" &&
    state.setup.shell === "ready";
  // The steps page returns to the main view once the steps it showed in progress are all ready.
  const setupSeenIncomplete = useRef(false);
  useEffect(() => {
    if (detail !== "setup") {
      setupSeenIncomplete.current = false;
      return;
    }
    if (!setupDone) {
      setupSeenIncomplete.current = true;
      return;
    }
    if (!setupSeenIncomplete.current) return;
    setupSeenIncomplete.current = false;
    setDetail(hasCloud ? undefined : "settings");
  }, [detail, setupDone, hasCloud]);
  // While the visible steps page waits, each local tick (one per 5 s) reads the node
  // once, so a step that finishes shows without a manual status check.
  const setupTick = local.available ? local.tick : undefined;
  useEffect(() => {
    if (!visible || detail !== "setup" || setupDone || setupTick === undefined) return;
    void refreshRef.current();
  }, [visible, detail, setupDone, setupTick]);
  const primary = () => {
    if (maintenanceActive) {
      setDetail("maintenance");
      return;
    }
    if (state?.status === "processing") {
      setDetail("setup");
      return;
    }
    if (state?.issue === "capability_missing") {
      startMaintenance(local.maintenance.needsInstall ? "reinstall" : "update");
      return;
    }
    if (canFinishRemove) {
      openConfirm("remove");
      return;
    }
    if (recoveryNeeded) {
      workloads.close();
      setDetail("authorization");
      void recovery.discover();
      return;
    }
    if (canEnable) {
      openConfirm("enable");
      return;
    }
    checkWorkspace();
  };
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
    canEnable,
    canFinishRemove,
    canAbandon,
    recoveryNeeded,
    status,
    reason,
    reasonDetail,
    problem,
    problemDetail: state?.problemDetail,
    primary,
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
            : confirm === "enable"
              ? m.compute_enable()
              : confirm === "drain"
                ? m.compute_stop()
                : confirm === "remove"
                  ? m.settings_compute_node_remove()
                  : m.settings_compute_node_repair()
        }
        description={`${m.compute_target({ workspace: workspaceLabel(target.current) })} ${confirm === "abandon" ? m.compute_close_request_confirm() : confirm === "enable" ? m.compute_enable_confirm() : confirm === "drain" ? m.compute_stop_confirm() : confirm === "remove" ? m.compute_remove_confirm() : m.compute_repair_warning()}`}
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
                : confirm === "enable"
                  ? m.compute_enable()
                  : confirm === "drain"
                    ? m.compute_stop()
                    : confirm === "remove"
                      ? m.settings_compute_node_remove()
                      : m.settings_compute_node_repair(),
            hierarchy: "primary",
            disabled: busy,
            onPress: () => {
              const action = confirm;
              const workspace = target.current;
              setConfirm(undefined);
              if (action === "enable" && workspace) {
                setDetail("setup");
              }
              if (action === "enable" && workspace)
                void node.configure({
                  desiredEnabled: true,
                  workspaceId: workspace,
                });
              else if (action === "drain" && expectedBinding.current)
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
