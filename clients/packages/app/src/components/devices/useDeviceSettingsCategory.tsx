import { useEffect, useRef, useState } from "react";
import { useNavigate } from "@tanstack/react-router";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import { getNativeBridge } from "@comma/native-bridge";
import { Button } from "@comma/ui/components/Button";
import { Menu, MenuItem, MenuPopover, MenuTrigger } from "@comma/ui/components/menu";
import {
  DeviceSettings,
  deviceSettingsMenuClassName,
  type SettingsCategoryDefinition,
} from "@comma/ui/components/settings";
import { Dialog } from "@comma/ui/components/dialog";
import { uiClock } from "@comma/ui/clock";
import { MoreHorizontalIcon } from "@comma/ui/components/icons";
import {
  useCall,
  useTopic,
  type DeviceAccess,
  type ShownDevice,
} from "@comma/core-client";
import { useCommaConnectorScope } from "../useCommaConnectorScope";
import { useWorkspacePreference } from "../activeWorkspace";
import { useOptionalChatActionRegistry } from "../chat/ChatProvider";
import { resolveWorkspaceChat } from "../chat/useWorkspaceChat";
import { useCommaSettingsOverlay } from "../settingsOverlay";
import { AddComputerCommand } from "./AddComputerCommand";
import { prefillDeviceDraft } from "./routerDeviceDraft";

import { useComputeSettingsController } from "../useComputeSettingsController";
import { ComputeSettingsView } from "../ComputeSettingsView";

export function useDeviceSettingsCategory(
  enabled: boolean
): SettingsCategoryDefinition {
  const m = useCommaMessages();
  const compute = useComputeSettingsController(true, enabled);
  const locale = useCommaLocale();
  const navigate = useNavigate();
  const registry = useOptionalChatActionRegistry();
  const overlay = useCommaSettingsOverlay();
  const local = useCommaConnectorScope(enabled);
  const bridge = getNativeBridge();
  const workspaceId = useWorkspacePreference();
  // The core reads the computers (and this one, by its id) while the page shows them, every 15 s.
  const call = useCall();
  // Each time the page opens is a visit: the core checks stale Agent runtimes once per visit.
  const [visit, setVisit] = useState(0);
  useEffect(() => {
    if (enabled) setVisit((count) => count + 1);
  }, [enabled]);
  const { value: shown } = useTopic(
    enabled && visit > 0 && workspaceId !== undefined
      ? {
          topic: "devices",
          prefer: workspaceId,
          local: local.deviceId ?? "",
          visit: String(visit),
        }
      : null
  );
  const devices = shown?.devices ?? [];
  const cloud = shown?.cloud ?? null;
  const loading = enabled && (shown?.loading ?? true);
  const failed = shown?.failed ?? false;
  const checks = shown?.checks ?? {};
  const hasMore = shown?.hasMore ?? false;
  const shownWorkspace = shown?.workspace ?? workspaceId;
  // How this device reaches each computer's station now, by the station's id.
  const { value: stationsShown } = useTopic(
    enabled && shownWorkspace !== undefined
      ? { topic: "stations", workspace: shownWorkspace }
      : null
  );
  const viaOf = new Map(
    (stationsShown?.stations ?? []).flatMap((station) =>
      station.link.state === "online" && station.link.via
        ? [[station.id, station.link.via] as const]
        : []
    )
  );
  const [management, setManagement] = useState<{
    kind: "rename" | "remove";
    id: string;
    name: string;
  }>();
  const [deviceName, setDeviceName] = useState("");
  const [managementPending, setManagementPending] = useState(false);
  const [managementError, setManagementError] = useState(false);
  const [actionError, setActionError] = useState<string>();
  const [pending, setPending] = useState(false);
  const [accessPending, setAccessPending] = useState<readonly string[]>([]);
  const [accessError, setAccessError] = useState(false);
  const action = useRef<AbortController | undefined>(undefined);
  const check = (device: string) =>
    void call("devices.check", { device }).catch(() => undefined);

  useEffect(() => {
    if (!enabled) {
      setManagement(undefined);
      setManagementPending(false);
    }
  }, [enabled]);
  // Only a switch to another workspace resets what this page holds.
  const heldWorkspace = useRef(workspaceId);
  useEffect(() => {
    if (heldWorkspace.current === workspaceId) return;
    heldWorkspace.current = workspaceId;
    setManagement(undefined);
    setManagementPending(false);
    setManagementError(false);
    setAccessPending([]);
    setPending(false);
  }, [workspaceId]);
  // Coming back to the window reads the computers again.
  useEffect(() => {
    if (!enabled) return undefined;
    const refresh = () => {
      if (document.visibilityState === "visible")
        void call("devices.refresh", {}).catch(() => undefined);
    };
    window.addEventListener("focus", refresh);
    return () => window.removeEventListener("focus", refresh);
  }, [call, enabled]);
  useEffect(() => () => action.current?.abort(), [workspaceId, enabled]);

  const current = devices.find((device) => device.device_id === local.deviceId);
  const changeAccess = async (
    device: ShownDevice | undefined,
    isLocal: boolean,
    access: DeviceAccess
  ) => {
    setAccessError(false);
    // This computer while Comma does not list it connected: its Connector takes Read or Full from this app.
    if (isLocal && device?.status !== "connected") {
      if (access === "off") setAccessError(true);
      else await local.setScope(access === "full" ? "" : "local_file_read");
      return;
    }
    if (!shownWorkspace || !device) return;
    setAccessPending((previous) => [...previous, device.device_id]);
    try {
      await call("devices.setAccess", {
        workspace: shownWorkspace,
        device: device.device_id,
        access,
      });
    } catch {
      setAccessError(true);
    } finally {
      setAccessPending((previous) => previous.filter((id) => id !== device.device_id));
    }
  };

  const manageDevice = async () => {
    if (!shownWorkspace || !management || managementPending) return;
    setManagementPending(true);
    setManagementError(false);
    try {
      if (management.kind === "rename")
        await call("devices.rename", {
          workspace: shownWorkspace,
          device: management.id,
          name: deviceName.trim(),
        });
      else
        await call("devices.remove", {
          workspace: shownWorkspace,
          device: management.id,
        });
      setManagement(undefined);
    } catch {
      setManagementError(true);
    } finally {
      setManagementPending(false);
    }
  };
  const openManagement = (kind: "rename" | "remove", device: ShownDevice) => {
    setManagement({ kind, id: device.device_id, name: device.name });
    setDeviceName(device.name);
    setManagementError(false);
  };
  // The Cloud VM belongs to the workspace: it can be renamed, not deleted here.
  const card = (device: ShownDevice | undefined, isLocal: boolean, isCloud = false) => {
    // The computer's one access value; a server from before says only whether it allows operations, and this
    // computer, before Comma lists it, has its Connector's scope.
    const access: DeviceAccess =
      device?.access ??
      (device
        ? device.allows_operations
          ? "full"
          : "read"
        : local.scope === ""
          ? "full"
          : "read");
    const permits = access === "full";
    const connected = isLocal ? local.available : device?.status === "connected";
    const tasks = (() => {
      const readiness = device?.tasks_readiness;
      if (!readiness || readiness === "offline") return undefined;
      if (readiness === "ready")
        return { label: m.settings_devices_tasks_ready(), ready: true };
      if (readiness === "device_needs_station")
        return { label: m.settings_devices_tasks_needs_station(), ready: false };
      if (readiness === "station_outdated")
        return { label: m.settings_devices_tasks_outdated(), ready: false };
      return { label: m.settings_devices_tasks_unavailable(), ready: false };
    })();
    return {
      id: device?.device_id ?? "local",
      name: device?.name ?? m.settings_this_device(),
      metadata: device
        ? [
            device.system_info?.hostname && device.system_info.hostname !== device.name
              ? device.system_info.hostname
              : undefined,
            device.system_info?.cpu_model,
            device.system_info?.memory_total
              ? `${Math.round(device.system_info.memory_total / 1024 ** 3)} GB`
              : undefined,
            device.system_info?.os_version,
            `${m.settings_devices_device_id()}: ${device.device_id}`,
            !connected && device.disconnected_at
              ? `${m.settings_devices_disconnected_at()}: ${new Date(device.disconnected_at * 1000).toLocaleString()}`
              : undefined,
          ].filter((value): value is string => Boolean(value))
        : undefined,
      source: (
        {
          comma_dev: "Comma Dev",
          comma_staging: "Comma Staging",
          comma: "Comma",
          connector: "Connector",
        } as Record<string, string>
      )[device?.system_info?.client_source ?? ""],
      local: isLocal,
      connected,
      tasks,
      path: (() => {
        const via =
          !isLocal && device?.station_id ? viaOf.get(device.station_id) : undefined;
        if (via === "direct") return m.settings_devices_link_direct();
        if (via === "relay") return m.settings_devices_link_relay();
        if (via === "salix") return m.settings_devices_link_salix();
        return undefined;
      })(),
      loading: !connected && !device && isLocal,
      status: connected
        ? m.settings_devices_connected()
        : device && !isLocal
          ? m.settings_devices_disconnected()
          : m.settings_devices_connecting(),
      description: [
        (
          { darwin: "macOS", linux: "Linux", windows: "Windows" } as Record<
            string,
            string
          >
        )[device?.os ?? ""] ?? device?.os,
        device?.system_info?.cpu_model ?? device?.arch,
        device?.system_info?.memory_total
          ? `${Math.round(device.system_info.memory_total / 1024 ** 3)} GB`
          : undefined,
      ]
        .filter(Boolean)
        .join(" · "),
      actions: device ? (
        <MenuTrigger>
          <Button
            className={deviceSettingsMenuClassName}
            hierarchy="tertiary-gray"
            size="xs"
            iconOnly
            iconLeading={<MoreHorizontalIcon />}
            aria-label={m.settings_devices_more({ name: device.name })}
          />
          <MenuPopover placement="bottom end">
            <Menu aria-label={m.settings_devices_more({ name: device.name })}>
              <MenuItem onAction={() => openManagement("rename", device)}>
                {m.settings_devices_rename()}
              </MenuItem>
              {!isLocal && !isCloud && (
                <MenuItem
                  tone="destructive"
                  onAction={() => openManagement("remove", device)}
                >
                  {m.settings_devices_remove()}
                </MenuItem>
              )}
            </Menu>
          </MenuPopover>
        </MenuTrigger>
      ) : undefined,
      runtimeCheck: device
        ? {
            label:
              checks[device.device_id] === "pending"
                ? m.settings_devices_checking()
                : m.settings_devices_check_again(),
            pending: checks[device.device_id] === "pending",
            disabled: !connected || !permits,
            error:
              checks[device.device_id] === "failed"
                ? m.settings_devices_check_failed()
                : undefined,
            onCheck: () => check(device.device_id),
          }
        : undefined,
      agents: (device?.device_runtimes ?? [])
        .filter((runtime) => ["codex", "claude"].includes(runtime.provider))
        .map((runtime) => {
          const expired = !runtime.fresh;
          const ready =
            connected && permits && !failed && !expired && runtime.status === "ready";
          function statusLabel() {
            if (!connected) return m.settings_devices_disconnected();
            if (!permits || runtime.issue === "permission_required")
              return m.settings_devices_permission_required();
            if (failed) return m.settings_devices_runtime_unknown();
            if (ready) return m.settings_devices_agent_available();
            if (expired && runtime.status === "ready")
              return m.settings_devices_agent_stale();
            if (runtime.status === "stale") return m.settings_devices_agent_stale();
            if (runtime.issue === "authentication_required")
              return m.settings_devices_agent_login();
            if (runtime.issue === "permission_required")
              return m.settings_devices_permission_required();
            if (runtime.status === "unavailable")
              return m.settings_devices_agent_unavailable();
            return m.settings_devices_agent_found();
          }
          function runtimeDescription() {
            if (!connected) return undefined;
            if (runtime.message) return runtime.message;
            if (ready) return undefined;
            if (runtime.status === "stale")
              return m.settings_devices_runtime_stale_hint();
            if (runtime.issue === "authentication_required")
              return m.settings_devices_runtime_login_hint();
            return runtime.version ?? "";
          }
          // The station reports the sign-in state; the mode only when the runtime's login names it (Codex).
          function authenticationLabel() {
            const mode = (
              {
                chatgpt: "ChatGPT",
                api_key: "API key",
                amazon_bedrock: "Amazon Bedrock",
              } as Record<string, string>
            )[runtime.auth?.mode ?? ""];
            if (mode || runtime.auth?.backend) return mode || runtime.auth?.backend;
            if (runtime.auth?.status === "authenticated")
              return m.settings_devices_signed_in();
            if (runtime.auth?.status === "unauthenticated")
              return m.settings_devices_signed_out();
            return m.settings_devices_not_reported();
          }
          return {
            id: runtime.device_runtime_id,
            provider: runtime.provider,
            name:
              (
                {
                  codex: "Codex",
                  claude: "Claude Code",
                } as Record<string, string>
              )[runtime.provider] ?? runtime.provider,
            status: statusLabel(),
            ready,
            attention: connected && runtime.issue === "authentication_required",
            description: runtimeDescription(),
            details: [
              `${m.settings_devices_version()}: ${runtime.version || m.settings_devices_not_reported()}`,
              ...(device?.task_models?.[runtime.provider]?.length
                ? [
                    `${m.settings_devices_models()}: ${device.task_models[runtime.provider]!.join(", ")}`,
                  ]
                : []),
              `${m.settings_devices_authentication()}: ${authenticationLabel()}`,
              `${m.settings_devices_checked()}: ${runtime.readiness_checked_at ? new Date(runtime.readiness_checked_at * 1000).toLocaleString() : m.settings_devices_not_reported()}`,
            ],
          };
        }),
      access: {
        level: access,
        disabled:
          (device ? accessPending.includes(device.device_id) : false) ||
          local.pending ||
          managementPending ||
          (isLocal ? !local.available || local.pending : !connected),
        onChange: (level: DeviceAccess) => {
          void changeAccess(device, isLocal, level);
        },
      },
    };
  };
  const items = [
    ...(bridge.platform === "electron" ? [card(current, true)] : []),
    ...devices
      .filter(
        (device) =>
          bridge.platform !== "electron" || device.device_id !== local.deviceId
      )
      .map((device) => card(device, false)),
  ];

  const openRouter = async () => {
    if (!registry || !workspaceId) return;
    const controller = new AbortController();
    action.current?.abort();
    action.current = controller;
    const attempt = registry.beginAttempt();
    setPending(true);
    setActionError(undefined);
    try {
      await attempt.run(async (signal) => {
        const combined = AbortSignal.any([signal, controller.signal]);
        const resolved = await resolveWorkspaceChat({
          core: registry.core,
          workspaceId,
          exactWorkspace: true,
          locale,
          session: registry.productLease,
          signal: combined,
        });
        if (resolved.status !== "ready") throw new Error("Router unavailable");
        const lease = attempt.retain(
          resolved.workspaceId,
          resolved.groupId,
          resolved.conversation.id
        );
        await prefillDeviceDraft(
          lease.channel,
          m.settings_devices_router_prompt(),
          combined
        );
        combined.throwIfAborted();
        registry.rememberHomeConversationTarget(
          resolved.workspaceId,
          resolved.groupId,
          resolved.conversation.id,
          resolved.conversation
        );
        overlay.closeSettings();
        await navigate({ to: "/" });
        uiClock.frame(() => {
          document
            .querySelector<HTMLElement>(
              '.comma-chat-composer-frame [contenteditable="true"]'
            )
            ?.focus();
        });
      });
    } catch {
      if (!controller.signal.aborted)
        setActionError(m.settings_devices_router_failed());
    } finally {
      attempt.release();
      if (!controller.signal.aborted) setPending(false);
    }
  };

  return {
    id: "devices",
    icon: "devices",
    label: m.settings_devices(),
    sections: [],
    overlay:
      compute.nodeOverlay ?? compute.workloads.overlay ?? compute.recovery.overlay,
    content: (
      <>
        <ComputeSettingsView
          controller={compute}
          renderHome={({ localNode, workloads }) => (
            <DeviceSettings
              title={m.settings_devices()}
              description={m.settings_devices_intro()}
              statusDescription={m.settings_devices_status_description()}
              summary={m.settings_devices_page_summary({
                count: String(items.length),
                online: String(items.filter((item) => item.connected).length),
              })}
              accessDetailsLabel={m.settings_devices_access_details()}
              accessLevels={{
                off: {
                  label: m.settings_devices_access_off(),
                  description: m.settings_devices_access_off_description(),
                  summary: m.settings_devices_access_off_summary(),
                },
                read: {
                  label: m.settings_devices_access_read(),
                  description: m.settings_devices_access_read_description(),
                  summary: m.settings_devices_access_readonly(),
                },
                full: {
                  label: m.settings_devices_access_full(),
                  description: m.settings_devices_access_full_description(),
                  summary: m.settings_devices_access_allowed(),
                },
              }}
              closeLabel={m.common_close()}
              guidedLabel={m.settings_devices_router_help()}
              agentsLabel={m.settings_devices_agents_label()}
              discoveredLabel={m.settings_devices_discovered()}
              emptyAgentsLabel={m.settings_devices_agents_empty()}
              emptyLabel={m.settings_devices_empty()}
              accessLabel={m.settings_devices_access()}
              addLabel={m.settings_devices_add()}
              addDisabled={!shownWorkspace}
              addContent={
                shownWorkspace ? (
                  <AddComputerCommand workspace={shownWorkspace} />
                ) : undefined
              }
              guidedDisabled={pending || !registry || !workspaceId}
              localLabel={m.settings_devices_local_label()}
              loadingLabel={m.common_loading()}
              devices={items.map((item) => ({
                ...item,
                content: item.local ? localNode : undefined,
              }))}
              cloud={cloud ? card(cloud, false, true) : undefined}
              cloudLabel={m.settings_devices_cloud_vm()}
              availableSummary={(ready, total) =>
                m.settings_devices_available_count({
                  ready: String(ready),
                  total: String(total),
                })
              }
              loading={loading}
              hasMore={hasMore}
              {...(actionError
                ? { error: actionError }
                : failed
                  ? { error: m.settings_devices_unavailable() }
                  : local.error || accessError
                    ? { error: m.settings_devices_permission_failed() }
                    : {})}
              onGuided={() => {
                void openRouter();
              }}
              onLoadMore={() => {
                if (hasMore) void call("devices.more", {}).catch(() => undefined);
              }}
            >
              {bridge.platform !== "electron" && (
                <div className="compute-panel">{localNode}</div>
              )}
              {workloads}
            </DeviceSettings>
          )}
        />
        {management && (
          <Dialog
            isOpen
            isDismissable={!managementPending}
            showCloseButton={!managementPending}
            title={
              management.kind === "rename"
                ? m.settings_devices_rename()
                : m.settings_devices_remove()
            }
            description={
              management.kind === "remove"
                ? m.settings_devices_remove_description({ name: management.name })
                : undefined
            }
            {...(management.kind === "rename"
              ? {
                  variant: "input" as const,
                  input: {
                    label: m.settings_devices_name(),
                    value: deviceName,
                    maxLength: 80,
                    autoFocus: true,
                    disabled: managementPending,
                    onChange: (event: React.ChangeEvent<HTMLInputElement>) =>
                      setDeviceName(event.target.value),
                  },
                }
              : {})}
            onOpenChange={(open) => {
              if (!open && !managementPending) setManagement(undefined);
            }}
            actions={[
              {
                label: m.settings_profile_cancel(),
                hierarchy: "secondary-gray",
                disabled: managementPending,
                onPress: () => setManagement(undefined),
              },
              {
                label:
                  management.kind === "rename"
                    ? m.settings_profile_save()
                    : m.settings_devices_remove(),
                hierarchy: management.kind === "rename" ? "primary" : "destructive",
                disabled:
                  managementPending ||
                  (management.kind === "rename" && !deviceName.trim()),
                onPress: () => {
                  void manageDevice();
                },
              },
            ]}
          >
            {managementError && (
              <p role="alert" className="text-sm text-error-primary">
                {m.settings_devices_manage_failed()}
              </p>
            )}
          </Dialog>
        )}
      </>
    ),
  };
}
