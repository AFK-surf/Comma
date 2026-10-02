import { useComputeRecoverySection } from "./useComputeRecoverySection";
import {
  useLocalComputeCategory,
  type ComputePanelDetail,
} from "./useLocalComputeCategory";
import { useEffect, useRef, useState } from "react";
import { useCommaMessages } from "@comma/i18n/react";
import {
  Dialog,
  type SettingsCategoryDefinition,
  type SettingsCategoryDetail,
  type SettingsPanelSection,
  type SettingsPanelItem,
} from "@comma/ui";
import type { ComputeNodeExpectedBinding } from "@comma/native-bridge";
import type { CommaApiClient } from "../api";
import { readActiveWorkspaceId, subscribeActiveWorkspace } from "./activeWorkspace";
import { needsDesktopApp, requestDesktopApp } from "./DesktopAppPrompt";
import { useComputeNode } from "./useComputeNode";
import { useComputeWorkloadsSection } from "./useComputeWorkloadsSection";

export function useComputeNodeCategory(
  api: CommaApiClient,
  visible: boolean
): SettingsCategoryDefinition {
  const m = useCommaMessages();
  const node = useComputeNode();
  const [workspaceId, setWorkspaceId] = useState(readActiveWorkspaceId);
  const [detail, setDetail] = useState<ComputePanelDetail>();
  const local = useLocalComputeCategory(visible, workspaceId, {
    navigation: { detail, setDetail },
    updateRequired: node.state?.issue === "capability_missing",
  });
  const workloads = useComputeWorkloadsSection(
    api,
    visible,
    local.available ? local.tick : undefined
  );
  const [confirm, setConfirm] = useState<
    "enable" | "drain" | "remove" | "repair" | "rebuild" | "abandon"
  >();
  const target = useRef<string | undefined>(undefined);
  const expectedBinding = useRef<ComputeNodeExpectedBinding | undefined>(undefined);
  const refreshRef = useRef(node.refresh);
  refreshRef.current = node.refresh;
  useEffect(() => subscribeActiveWorkspace(setWorkspaceId), []);
  useEffect(() => {
    if (!visible || !node.available || document.hidden) return;
    void refreshRef.current();
  }, [visible, node.available]);
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
  const boundElsewhere = !!binding && binding !== workspaceId;
  const workspaceLabel = (id: string | undefined) =>
    id === workspaceId && workloads.workspaceName
      ? workloads.workspaceName
      : id
        ? m.compute_workspace_label({ id: id.slice(-8) })
        : m.compute_no_workspace();
  const status = workspaceUnconfirmed
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
  const reason = workspaceUnconfirmed
    ? node.error
      ? m.compute_read_failed()
      : m.compute_maintenance_checking()
    : state?.issue === "removal_incomplete"
      ? m.compute_removal_incomplete()
      : state?.issue === "authorization_unavailable"
        ? m.compute_current_login_unavailable()
        : state?.issue === "installation_receipt_missing"
          ? m.compute_receipt_missing()
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
    state?.issue !== "installation_receipt_missing" &&
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
  const actions: SettingsPanelItem = {
    id: "compute-node.actions",
    title: m.compute_maintenance_workspace_settings(),
    control: {
      type: "menu",
      label: m.compute_maintenance_workspace_settings(),
      disabled: busy || !eligible,
      items: [
        {
          id: "refresh",
          label: m.compute_check_status(),
          onPress: checkWorkspace,
        },
        ...(state?.canAbandonRequest
          ? [
              {
                id: "abandon",
                label: m.compute_close_request(),
                onPress: () => openConfirm("abandon"),
              },
            ]
          : []),
        ...(binding
          ? [
              {
                id: "drain",
                label: m.compute_stop(),
                onPress: () => openConfirm("drain"),
              },
              {
                id: "remove",
                label: m.settings_compute_node_remove(),
                tone: "destructive" as const,
                onPress: () => openConfirm("remove"),
              },
            ]
          : []),
      ],
    },
  };
  const diagnosticsDetail: SettingsCategoryDetail = {
    id: "compute-node-diagnostics",
    title: m.compute_diagnostics(),
    backLabel: m.compute_back(),
    onBack: () => setDetail(undefined),
    sections: [
      {
        id: "compute-node.diagnostics",
        title: m.compute_diagnostics(),
        items: [
          {
            id: "compute-node.last-observation",
            title: m.compute_last_check(),
            description: state?.observedAt ?? m.compute_activity_unknown(),
          },
          {
            id: "compute-node.binding-id",
            title: m.compute_bound_workspace(),
            description: binding ?? m.compute_no_workspace(),
          },
          {
            id: "compute-node.raw-facets",
            title: m.settings_compute_node_status(),
            description: state
              ? m.settings_compute_node_status_description({
                  desired: state.desiredEnabled ? "enabled" : "disabled",
                  admission: state.facets.admission,
                  connection: state.facets.connection,
                  installation: state.facets.installationHealth,
                  readiness: state.facets.runtimeReadiness,
                  activity: state.facets.workActivity,
                })
              : m.compute_loading(),
          },
          ...(state?.preparation
            ? [
                {
                  id: "compute-node.preparation",
                  title: m.settings_compute_node_preparation(),
                  description: m.settings_compute_node_preparation_description({
                    source: state.preparation.location,
                    instance: state.preparation.instance,
                    phase: state.preparation.phase,
                  }),
                },
              ]
            : []),
          ...(state?.problem || node.error
            ? [
                {
                  id: "compute-node.problem",
                  title: m.compute_details(),
                  description: state?.problem ?? node.error ?? m.compute_attention(),
                },
              ]
            : []),
          ...(state?.preparation?.source === "local"
            ? [
                {
                  id: "compute-node.rebuild",
                  title: m.settings_compute_node_rebuild(),
                  description: m.settings_compute_node_rebuild_description(),
                  control: {
                    type: "button" as const,
                    label: m.settings_compute_node_rebuild(),
                    disabled: busy,
                    onPress: () => openConfirm("rebuild"),
                  },
                },
              ]
            : []),
        ],
      },
    ],
  };
  const recoveryNeeded =
    !!state?.issue &&
    [
      "authorization_unavailable",
      "installation_receipt_missing",
      "enable_incomplete",
      "operation_unknown",
    ].includes(state.issue);
  const workspaceStatus: SettingsPanelItem = {
    id: "compute-node.status",
    title: status,
    description: state?.observedAt
      ? `${reason} ${m.compute_confirmed_at({ time: new Date(state.observedAt).toLocaleString() })}`
      : reason,
    ...(workspaceUnconfirmed
      ? {
          control: {
            type: "button" as const,
            label: maintenanceActive
              ? m.compute_maintenance_view_progress()
              : m.compute_check_status(),
            disabled: !maintenanceActive && node.pending,
            onPress: () => {
              if (maintenanceActive) setDetail("maintenance");
              else checkWorkspace();
            },
          },
        }
      : eligible && state?.status !== "ready" && state?.issue !== "capability_missing"
        ? {
            control: {
              type: "button" as const,
              label: canFinishRemove
                ? m.compute_finish_remove()
                : canEnable
                  ? state?.issue === "shell_initialization_pending"
                    ? m.compute_continue_shell()
                    : state?.desiredEnabled
                      ? m.compute_continue_enable()
                      : m.compute_enable()
                  : recoveryNeeded
                    ? m.compute_recovery_title()
                    : m.compute_check_status(),
              disabled: busy || (canEnable && !workspaceId),
              onPress: () => {
                if (canFinishRemove) openConfirm("remove");
                else if (canEnable) openConfirm("enable");
                else if (recoveryNeeded) {
                  workloads.close();
                  setDetail("workspace");
                } else void node.refresh();
              },
            },
          }
        : needsDesktopApp()
          ? {
              control: {
                type: "button" as const,
                label: m.compute_enable(),
                onPress: () => requestDesktopApp("compute-node"),
              },
            }
          : {}),
  };
  const workspaceSection: SettingsPanelSection = {
    id: "compute-node.workspace",
    title: m.compute_workspace_title(),
    items: [
      {
        id: "compute-node.binding",
        title: workspaceLabel(workspaceId),
        ...(boundElsewhere ? { errorMessage: m.compute_other_workspace() } : {}),
        control: {
          type: "button",
          label: m.compute_maintenance_workspace_open(),
          disabled: !workspaceId,
          onPress: () => {
            workloads.close();
            setDetail("workspace");
          },
        },
      },
      workspaceStatus,
      ...(state?.issue === "removal_incomplete"
        ? [
            {
              id: "compute-node.removal-cloud",
              title: state.remoteRevocationConfirmed
                ? m.compute_cloud_revoke_confirmed()
                : m.compute_cloud_revoke_unknown(),
            },
            {
              id: "compute-node.removal-local",
              title: m.compute_local_cleanup_pending(),
            },
          ]
        : []),
      // Keep an unresolved creation visible without expanding every workload on the root page.
      ...workloads.section.items.filter((item) => item.id === "compute-node.creation"),
      actions,
    ],
  };
  const hostSection: SettingsPanelSection = {
    ...local.maintenance.section,
    items: local.maintenance.section.items.map((item) =>
      item.control?.type === "menu"
        ? {
            ...item,
            control: {
              ...item.control,
              items: [
                ...item.control.items,
                {
                  id: "diagnostics",
                  label: m.compute_diagnostics(),
                  onPress: () => setDetail("diagnostics"),
                },
              ],
            },
          }
        : item
    ),
  };
  if (
    local.disposal &&
    local.disposal.outcome !== "completed" &&
    local.disposal.outcome !== "superseded"
  )
    hostSection.items.push({
      id: "compute-node.local-pending",
      title: m.compute_local_delete_pending(),
      control: { type: "button", label: m.compute_details(), onPress: local.open },
    });
  const activeDetail =
    detail === "local" || detail === "maintenance"
      ? local.category.detail
      : detail === "diagnostics"
        ? diagnosticsDetail
        : detail === "workspace"
          ? (workloads.detail ?? {
              id: "compute-workspace",
              title: workspaceLabel(workspaceId),
              backLabel: m.compute_back(),
              onBack: () => setDetail(undefined),
              sections: [
                {
                  ...workspaceSection,
                  items: workspaceSection.items.filter(
                    (item) => item.id !== "compute-node.creation"
                  ),
                },
                ...(recoveryNeeded && node.available ? [recovery.section] : []),
                workloads.section,
              ],
            })
          : undefined;
  return {
    id: "compute-node",
    icon: "devices",
    label: m.settings_compute_node(),
    sections: [
      ...(local.available ? [hostSection] : []),
      local.section,
      workspaceSection,
    ],
    ...(activeDetail ? { detail: activeDetail } : {}),
    ...(recovery.overlay ? { overlay: recovery.overlay } : {}),
    ...(confirm
      ? {
          overlay: (
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
          ),
        }
      : {}),
  };
}
