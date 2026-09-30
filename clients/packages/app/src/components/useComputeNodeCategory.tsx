import { useEffect, useRef, useState } from "react";
import { useCommaMessages } from "@comma/i18n/react";
import {
  Dialog,
  type SettingsCategoryDefinition,
  type SettingsPanelItem,
} from "@comma/ui";
import type { ComputeNodeExpectedBinding } from "@comma/native-bridge";
import type { CommaApiClient } from "../api";
import { readActiveWorkspaceId, subscribeActiveWorkspace } from "./activeWorkspace";
import { useComputeNode } from "./useComputeNode";
import { useComputeWorkloadsSection } from "./useComputeWorkloadsSection";

export function useComputeNodeCategory(
  api: CommaApiClient,
  visible: boolean
): SettingsCategoryDefinition {
  const m = useCommaMessages();
  const node = useComputeNode();
  const workloads = useComputeWorkloadsSection(api, visible);
  const [workspaceId, setWorkspaceId] = useState(readActiveWorkspaceId);
  const [diagnostics, setDiagnostics] = useState(false);
  const [confirm, setConfirm] = useState<
    "enable" | "drain" | "remove" | "repair" | "rebuild"
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
  const eligible = node.available && state?.eligibility.eligible !== false;
  const busy =
    node.pending ||
    !!(state?.operation?.outcome === "pending" && state.status === "processing");
  const binding = state?.bindingWorkspaceId;
  const boundElsewhere = !!binding && binding !== workspaceId;
  const workspaceLabel = (id: string | undefined) =>
    id === workspaceId && workloads.workspaceName
      ? workloads.workspaceName
      : id
        ? m.compute_workspace_label({ id: id.slice(-8) })
        : m.compute_no_workspace();
  const status =
    !node.available || state?.eligibility.eligible === false
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
                : m.compute_preparing()
              : state?.status === "ready" && state.observationFresh
                ? m.compute_available()
                : state?.status === "stopped"
                  ? m.compute_stopped()
                  : m.compute_attention();
  const reason =
    state?.issue === "operation_unknown"
      ? m.compute_operation_unknown()
      : state?.issue === "connection"
        ? m.compute_connection_problem()
        : state?.issue === "authorization"
          ? m.compute_authorization_problem()
          : state?.issue === "preparation_failed"
            ? m.compute_preparation_problem()
            : state?.issue === "enable_incomplete"
              ? m.compute_enable_incomplete()
              : m.compute_node_description();
  const canEnable = !!(
    eligible &&
    !busy &&
    !boundElsewhere &&
    ((!state?.desiredEnabled && state?.operation?.outcome !== "unknown") ||
      state.recoveryActions?.includes("continue_enable"))
  );
  const activity =
    state?.facets.workActivity === "active"
      ? m.compute_active()
      : state?.facets.workActivity === "idle"
        ? m.compute_idle()
        : m.compute_activity_unknown();
  const openConfirm = (action: NonNullable<typeof confirm>) => {
    target.current = binding ?? workspaceId;
    expectedBinding.current = binding
      ? {
          workspaceId: binding,
          installationId: state?.bindingInstallationId ?? null,
        }
      : undefined;
    setConfirm(action);
  };
  const actions: SettingsPanelItem = {
    id: "compute-node.actions",
    title: m.compute_more(),
    description: activity,
    control: {
      type: "menu",
      label: m.compute_more(),
      disabled: busy || !eligible,
      items: [
        {
          id: "diagnostics",
          label: m.compute_diagnostics(),
          onPress: () => {
            workloads.close();
            setDiagnostics(true);
          },
        },
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
  return {
    id: "compute-node",
    icon: "devices",
    label: m.settings_compute_node(),
    sections: [
      {
        id: "compute-node.device",
        title: m.compute_this_mac(),
        items: [
          {
            id: "compute-node.status",
            title: status,
            description: state?.observedAt
              ? `${reason} ${m.compute_confirmed_at({ time: new Date(state.observedAt).toLocaleString() })}`
              : reason,
            ...(eligible
              ? {
                  control: {
                    type: "button" as const,
                    label: canEnable
                      ? state?.desiredEnabled
                        ? m.compute_continue_enable()
                        : m.compute_enable()
                      : m.compute_check_status(),
                    disabled: busy || (canEnable && !workspaceId),
                    onPress: () => {
                      if (canEnable) openConfirm("enable");
                      else void node.refresh();
                    },
                  },
                }
              : {}),
          },
          {
            id: "compute-node.binding",
            title: m.compute_bound_workspace(),
            description: workspaceLabel(binding ?? workspaceId),
            ...(boundElsewhere ? { errorMessage: m.compute_other_workspace() } : {}),
          },
          actions,
        ],
      },
      workloads.section,
    ],
    ...(diagnostics
      ? {
          detail: {
            id: "compute-node-diagnostics",
            title: m.compute_diagnostics(),
            backLabel: m.compute_back(),
            onBack: () => setDiagnostics(false),
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
                          description:
                            state?.problem ?? node.error ?? m.compute_attention(),
                        },
                      ]
                    : []),
                  {
                    id: "compute-node.repair",
                    title: m.settings_compute_node_repair(),
                    description: m.compute_repair_warning(),
                    control: {
                      type: "button" as const,
                      label: m.settings_compute_node_action_repair(),
                      disabled: busy || !eligible,
                      onPress: () => openConfirm("repair"),
                    },
                  },
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
          },
        }
      : workloads.detail
        ? { detail: workloads.detail }
        : {}),
    ...(confirm
      ? {
          overlay: (
            <Dialog
              isOpen
              isDismissable
              title={
                confirm === "enable"
                  ? m.compute_enable()
                  : confirm === "drain"
                    ? m.compute_stop()
                    : confirm === "remove"
                      ? m.settings_compute_node_remove()
                      : m.settings_compute_node_repair()
              }
              description={`${m.compute_target({ workspace: workspaceLabel(target.current) })} ${confirm === "enable" ? m.compute_enable_confirm() : confirm === "drain" ? m.compute_stop_confirm() : confirm === "remove" ? m.compute_remove_confirm() : m.compute_repair_warning()}`}
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
                  label: m.compute_confirm(),
                  hierarchy: "primary",
                  disabled: node.pending,
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
