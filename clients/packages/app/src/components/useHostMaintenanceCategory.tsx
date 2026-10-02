import { useCallback, useEffect, useRef, useState } from "react";
import { getNativeBridge, type HostMaintenanceState } from "@comma/native-bridge";
import { useCommaMessages } from "@comma/i18n/react";
import {
  type SettingsCategoryDetail,
  type SettingsPanelItem,
  type SettingsPanelSection,
} from "@comma/ui";

type MaintenanceAction = "update" | "reinstall" | "uninstall";
type DataPolicy = "preserve" | "reset";

/** Local owner state survives cloud account changes. Uses the existing visible read clock. */
export function useHostMaintenanceCategory(
  visible: boolean,
  tick: number,
  open: () => void,
  close: () => void,
  updateRequired = false
) {
  const bridge = getNativeBridge();
  const m = useCommaMessages();
  const available = bridge.platform === "electron";
  const [state, setState] = useState<HostMaintenanceState>();
  const [readingError, setReadingError] = useState(false);
  const [error, setError] = useState("");
  const [pending, setPending] = useState(false);
  const [action, setAction] = useState<MaintenanceAction>();
  const [dataPolicy, setDataPolicy] = useState<DataPolicy>("preserve");
  const reading = useRef(false);
  const mutating = useRef(false);
  const generation = useRef(0);
  const refresh = useCallback(async () => {
    if (!available || document.hidden || reading.current) return;
    reading.current = true;
    const current = generation.current;
    try {
      const next = await bridge.computeNode.hostMaintenanceState();
      if (current === generation.current) {
        setState(next);
        setReadingError(false);
        setError("");
      }
    } catch {
      if (current === generation.current) setReadingError(true);
    } finally {
      reading.current = false;
    }
  }, [available, bridge]);
  useEffect(() => {
    if (visible) void refresh();
  }, [visible, tick, refresh]);
  useEffect(
    () => () => {
      generation.current++;
    },
    []
  );
  const mutate = async (operation: () => Promise<HostMaintenanceState>) => {
    if (mutating.current) return;
    mutating.current = true;
    generation.current++;
    setPending(true);
    setError("");
    try {
      const next = await operation();
      generation.current++;
      setState(next);
      setReadingError(false);
      setAction(undefined);
    } catch {
      generation.current++;
      // No second request after an ambiguous result: the next read finds the receipt.
      setReadingError(true);
      setError(m.compute_maintenance_submit_failed());
    } finally {
      mutating.current = false;
      setPending(false);
    }
  };
  const operation = state?.operation;
  const unfinished = !!operation && operation.outcome !== "succeeded";
  const failed = operation?.outcome === "failed";
  const running = operation?.outcome === "pending";
  useEffect(() => {
    // A new receipt or resumed operation invalidates an unsubmitted selection.
    setAction(undefined);
    setDataPolicy("preserve");
  }, [operation?.requestId, operation?.outcome]);
  const needsInstall = state?.installation === "not_installed";
  const needsUpdate = updateRequired || !!state?.updateAvailable;
  const blocked = pending || readingError || !state || running;
  const choose = (next: MaintenanceAction) => {
    if (blocked || (failed && next === "update")) return;
    // After failure, preserving the same installation is the existing Resume action.
    setDataPolicy(failed && next === "reinstall" ? "reset" : "preserve");
    setAction(next);
    open();
  };
  const phaseLabel = failed
    ? m.compute_maintenance_failed()
    : operation?.phase === "preparing"
      ? m.compute_maintenance_preparing()
      : operation?.phase === "stopping"
        ? m.compute_maintenance_stopping()
        : operation?.phase === "installing"
          ? m.compute_maintenance_installing()
          : operation?.phase === "removing"
            ? m.compute_maintenance_removing()
            : operation?.phase === "checking"
              ? m.compute_maintenance_checking()
              : operation?.outcome === "failed"
                ? m.compute_maintenance_failed()
                : m.compute_maintenance_completed();
  const title = readingError
    ? m.compute_maintenance_unknown()
    : unfinished
      ? phaseLabel
      : pending
        ? m.compute_maintenance_preparing()
        : needsInstall &&
            operation?.action === "uninstall" &&
            operation.outcome === "succeeded"
          ? operation.dataPolicy === "reset"
            ? m.compute_maintenance_uninstalled_reset()
            : m.compute_maintenance_uninstalled_preserve()
          : needsInstall
            ? m.compute_maintenance_not_installed()
            : needsUpdate
              ? m.compute_host_update_required()
              : state?.installation === "installed"
                ? m.compute_maintenance_installed()
                : m.compute_maintenance_unknown();
  const primary: SettingsPanelItem["control"] =
    unfinished || pending
      ? {
          type: "button",
          label: m.compute_maintenance_view_progress(),
          onPress: open,
        }
      : !state || readingError
        ? {
            type: "button",
            label: m.compute_check_status(),
            disabled: pending,
            onPress: () => void refresh(),
          }
        : needsInstall || needsUpdate
          ? {
              type: "button",
              label: needsInstall
                ? m.compute_maintenance_install()
                : m.compute_maintenance_update(),
              disabled: blocked,
              onPress: () => choose(needsInstall ? "reinstall" : "update"),
            }
          : state.installation === "unreadable"
            ? {
                type: "button",
                label: m.compute_maintenance_reinstall(),
                disabled: blocked,
                onPress: () => choose("reinstall"),
              }
            : undefined;
  const section: SettingsPanelSection = {
    id: "compute-node.host",
    title: m.compute_this_mac(),
    items: [
      {
        id: "compute-node.host-status",
        title,
        ...(readingError ? { description: m.compute_maintenance_read_failed() } : {}),
        ...(primary ? { control: primary } : {}),
      },
      {
        id: "compute-node.host-menu",
        title: m.compute_maintenance_title(),
        control: {
          type: "menu",
          label: m.compute_more(),
          items: [
            {
              id: "maintenance",
              label: m.compute_maintenance_title(),
              onPress: () => {
                setAction(undefined);
                open();
              },
            },
            {
              id: "refresh",
              label: m.compute_check_status(),
              onPress: () => void refresh(),
            },
          ],
        },
      },
    ],
  };
  const selectionValid =
    !failed ||
    action === "uninstall" ||
    (action === "reinstall" && dataPolicy === "reset");
  const actionLabel =
    action === "update"
      ? m.compute_maintenance_action_update()
      : action === "uninstall"
        ? dataPolicy === "reset"
          ? m.compute_maintenance_action_uninstall_reset()
          : m.compute_maintenance_action_uninstall()
        : dataPolicy === "reset"
          ? m.compute_maintenance_action_reinstall_reset()
          : m.compute_maintenance_action_reinstall();
  const detail: SettingsCategoryDetail = {
    id: "compute-host-maintenance",
    title: m.compute_maintenance_title(),
    description: m.compute_maintenance_shared_scope(),
    backLabel: m.compute_back(),
    onBack: () => {
      setAction(undefined);
      close();
    },
    sections: [
      {
        id: "compute-node.host-maintenance",
        title: m.compute_maintenance_title(),
        items: [
          {
            id: "compute-node.host-result",
            title,
            ...(operation?.problem ? { description: operation.problem } : {}),
            ...(unfinished
              ? {
                  control: {
                    type: "button" as const,
                    label: readingError
                      ? m.compute_check_status()
                      : m.compute_maintenance_continue(),
                    disabled: pending,
                    onPress: () => {
                      if (readingError) void refresh();
                      else
                        void mutate(() =>
                          bridge.computeNode.resumeHostMaintenance({
                            requestId: operation!.requestId,
                          })
                        );
                    },
                  },
                }
              : {}),
          },
          ...(error ? [{ id: "compute-node.host-error", title: error }] : []),
          ...(readingError
            ? [
                {
                  id: "compute-node.host-read-error",
                  title: m.compute_maintenance_read_failed(),
                },
              ]
            : []),
          {
            id: "compute-node.host-installed-version",
            title: m.compute_maintenance_version(),
            description: state?.installedReleaseId ?? m.compute_maintenance_unknown(),
          },
          {
            id: "compute-node.host-target-version",
            title: m.compute_maintenance_target_version(),
            description: state?.selectedReleaseId ?? m.compute_maintenance_unknown(),
          },
          {
            id: "compute-node.host-actions",
            title: m.compute_maintenance_choose_action(),
            control: {
              type: "menu" as const,
              label: m.compute_more(),
              disabled: blocked,
              items: [
                ...(needsUpdate && !needsInstall && !failed
                  ? [
                      {
                        id: "update",
                        label: m.compute_maintenance_update(),
                        onPress: () => choose("update"),
                      },
                    ]
                  : []),
                {
                  id: "reinstall",
                  label: failed
                    ? m.compute_maintenance_action_reinstall_reset()
                    : needsInstall
                      ? m.compute_maintenance_install()
                      : m.compute_maintenance_reinstall(),
                  onPress: () => choose("reinstall"),
                },
                {
                  id: "uninstall",
                  label: m.compute_maintenance_uninstall(),
                  tone: "destructive" as const,
                  onPress: () => choose("uninstall"),
                },
              ],
            },
          },
          ...(action
            ? [
                ...(action !== "update"
                  ? [
                      {
                        id: "compute-node.host-policy",
                        title: m.compute_maintenance_data_policy(),
                        description:
                          dataPolicy === "preserve"
                            ? m.compute_maintenance_preserve_detail()
                            : m.compute_maintenance_reset_detail(),
                        control: {
                          type: "dropdown" as const,
                          value: dataPolicy,
                          disabled: blocked,
                          items: [
                            ...(!(failed && action === "reinstall")
                              ? [
                                  {
                                    id: "preserve",
                                    label: m.compute_maintenance_preserve(),
                                  },
                                ]
                              : []),
                            { id: "reset", label: m.compute_maintenance_reset() },
                          ],
                          onChange: (value: string) => {
                            if (
                              value === "reset" ||
                              (value === "preserve" &&
                                !(failed && action === "reinstall"))
                            )
                              setDataPolicy(value);
                          },
                        },
                      },
                    ]
                  : []),
                {
                  id: "compute-node.host-submit",
                  title: actionLabel,
                  description:
                    action === "update"
                      ? m.compute_maintenance_preserve_detail()
                      : m.compute_maintenance_shared_scope(),
                  control: {
                    type: "button" as const,
                    label: actionLabel,
                    disabled: blocked || !selectionValid,
                    onPress: () => {
                      if (blocked || !selectionValid) return;
                      void mutate(() =>
                        bridge.computeNode.maintainHost({
                          action,
                          dataPolicy: action === "update" ? "preserve" : dataPolicy,
                        })
                      );
                    },
                  },
                },
              ]
            : []),
          {
            id: "compute-node.host-check",
            title: m.compute_check_status(),
            control: {
              type: "button" as const,
              label: m.compute_check_status(),
              disabled: pending,
              onPress: () => void refresh(),
            },
          },
        ],
      },
    ],
  };
  return { state, section, detail, refresh, pending, unfinished, choose };
}
