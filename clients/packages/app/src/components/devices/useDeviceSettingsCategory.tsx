import { useEffect, useRef, useState } from "react";
import { useNavigate } from "@tanstack/react-router";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import { getNativeBridge } from "@comma/native-bridge";
import {
  DeviceSettings,
  type SettingsCategoryDefinition,
} from "@comma/ui/components/settings";
import { Dialog } from "@comma/ui/components/dialog";
import { InputField } from "@comma/ui/components/input";
import { uiClock } from "@comma/ui/clock";
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
import { useMachineAccounts } from "./useMachineAccounts";
import { AddComputerCommand } from "./AddComputerCommand";
import { LinuxComputeCommand } from "./LinuxComputeCommand";
import { AddCommaDeviceOption, AddDevice } from "./AddDevice";
import { prefillDeviceDraft } from "./routerDeviceDraft";

import { useComputeSettingsController } from "../useComputeSettingsController";
import { ComputeSettingsView } from "../ComputeSettingsView";

export function useDeviceSettingsCategory(
  enabled: boolean,
  /** Settings' own navigation: opens another category (Models & API, to add a workspace account). */
  openCategory?: (categoryId: string) => void
): SettingsCategoryDefinition {
  const m = useCommaMessages();
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
  // The devices list names the device that runs each workload.
  const compute = useComputeSettingsController(true, enabled, {
    names: new Map(devices.map((device) => [device.device_id, device.name])),
    localId: local.deviceId,
  });
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
    commaDevice: boolean;
  }>();
  const [deviceName, setDeviceName] = useState("");
  const [managementPending, setManagementPending] = useState(false);
  const [managementError, setManagementError] = useState(false);
  const [actionError, setActionError] = useState<string>();
  const [pending, setPending] = useState(false);
  const [accessPending, setAccessPending] = useState<readonly string[]>([]);
  const [accessError, setAccessError] = useState(false);
  const [settingUp, setSettingUp] = useState(false);
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
  // Which account this Mac's Codex and Claude Code run on in the workspace: a dropdown on each agent's row. Read from
  // this Mac's station over its local channel (not the mesh); other computers keep their rows as reported.
  const machineWorkspace =
    enabled && bridge.platform === "electron" ? shownWorkspace : undefined;
  const machine = useMachineAccounts(machineWorkspace);
  // The model server an agent on this Mac is pointed at: the dialog's agent and what is typed in it.
  const [endpointFor, setEndpointFor] = useState<{
    provider: "codex" | "claude";
    address: string;
    key: string;
    /** The station has a key for it: an empty field keeps that one. */
    keyed: boolean;
    invalid: boolean;
  }>();
  const saveEndpoint = async () => {
    if (!endpointFor) return;
    const address = endpointFor.address.trim();
    if (!/^https?:\/\/\S+$/i.test(address)) {
      setEndpointFor({ ...endpointFor, invalid: true });
      return;
    }
    if (
      await machine.setEndpoint(endpointFor.provider, address, endpointFor.key.trim())
    )
      setEndpointFor(undefined);
  };
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
        await call(management.commaDevice ? "deviceSetup.remove" : "devices.remove", {
          workspace: shownWorkspace,
          device: management.id,
        });
      if (management.kind === "remove") await call("devices.refresh", {});
      setManagement(undefined);
    } catch {
      setManagementError(true);
    } finally {
      setManagementPending(false);
    }
  };
  const openManagement = (kind: "rename" | "remove", device: ShownDevice) => {
    setManagement({
      kind,
      id: device.device_id,
      name: device.name,
      commaDevice: !!device.isCommaDevice,
    });
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
    // What keeps it from Tasks, if anything.
    const tasksBlocker = (() => {
      const readiness = device?.tasks_readiness;
      if (!readiness || readiness === "offline" || readiness === "ready")
        return undefined;
      if (readiness === "device_needs_station")
        return m.settings_devices_tasks_needs_station();
      if (readiness === "station_outdated") return m.settings_devices_tasks_outdated();
      return m.settings_devices_tasks_unavailable();
    })();
    const source = (
      {
        comma_dev: "Comma Dev",
        comma_staging: "Comma Staging",
        comma: "Comma",
        connector: "Connector",
      } as Record<string, string>
    )[device?.system_info?.client_source ?? ""];
    const path = (() => {
      const via =
        !isLocal && device?.station_id ? viaOf.get(device.station_id) : undefined;
      if (via === "direct") return m.settings_devices_link_direct();
      if (via === "relay") return m.settings_devices_link_relay();
      if (via === "salix") return m.settings_devices_link_salix();
      return undefined;
    })();
    const agents = (device?.device_runtimes ?? [])
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
        const name =
          (
            {
              codex: "Codex",
              claude: "Claude Code",
            } as Record<string, string>
          )[runtime.provider] ?? runtime.provider;
        return {
          id: runtime.device_runtime_id,
          provider: runtime.provider,
          name,
          status: statusLabel(),
          ready,
          attention:
            connected && permits && runtime.issue === "authentication_required",
          ...(connected && runtime.message ? { note: runtime.message } : {}),
          // Only what was reported.
          details: (
            [
              [m.settings_devices_version(), runtime.version],
              [
                m.settings_devices_models(),
                device?.task_models?.[runtime.provider]?.join(", "),
              ],
              [m.settings_devices_authentication(), authenticationLabel()],
              [
                m.settings_devices_checked(),
                runtime.readiness_checked_at
                  ? new Date(runtime.readiness_checked_at * 1000).toLocaleString()
                  : undefined,
              ],
            ] as const
          ).flatMap(([label, value]) =>
            value && value !== m.settings_devices_not_reported()
              ? [[label, value] as [string, string]]
              : []
          ),
        };
      });
    // On this computer each agent's row says which account it runs on, and its dropdown changes it (RFC43 §3.4).
    const rows =
      isLocal && machineWorkspace
        ? (["codex", "claude"] as const).map((provider) => {
            const name = provider === "codex" ? "Codex" : "Claude Code";
            const found = agents.find((agent) => agent.provider === provider);
            const account = machine.accounts?.[provider];
            const login = account?.local ?? null;
            const signingIn = login?.signIn?.state === "running";
            const signedIn = login !== null && login.loggedIn && login.usable;
            // The workspace's AI accounts are its Profiles, in Models & API.
            const addWorkspace = openCategory
              ? {
                  label: m.settings_devices_agent_source_add_workspace(),
                  onPress: () => openCategory("models"),
                }
              : undefined;
            const server = account?.endpoint ?? null;
            const changeEndpoint = {
              label: m.settings_devices_agent_source_endpoint_change(),
              onPress: () =>
                setEndpointFor({
                  provider,
                  address: server?.address ?? "",
                  key: "",
                  keyed: server?.keyed ?? false,
                  invalid: false,
                }),
            };
            const line = (() => {
              if (!account) return { status: "" };
              if (account.source === "endpoint") {
                if (!server)
                  return {
                    status: m.settings_devices_agent_source_endpoint_missing(),
                    attention: true,
                    link: changeEndpoint,
                  };
                if (server.state !== "ok")
                  return {
                    status: m.settings_devices_agent_source_endpoint_failed({
                      address: server.address,
                      detail: server.detail,
                    }),
                    attention: true,
                    link: changeEndpoint,
                  };
                return server.models.length > 0
                  ? {
                      status: m.settings_devices_agent_source_using_endpoint({
                        address: server.address,
                        count: String(server.models.length),
                      }),
                      ready: true,
                      link: changeEndpoint,
                    }
                  : {
                      status: m.settings_devices_agent_source_endpoint_no_models({
                        address: server.address,
                      }),
                      attention: true,
                      link: changeEndpoint,
                    };
              }
              if (account.source === "workspace")
                return account.workspaceAvailable
                  ? {
                      status: m.settings_devices_agent_source_using_workspace(),
                      ready: true,
                    }
                  : {
                      status: m.settings_devices_agent_source_no_workspace(),
                      attention: true,
                      link: addWorkspace,
                    };
              if (account.source === "local") {
                if (login && !login.installed)
                  return {
                    status: m.settings_devices_agent_missing(),
                    attention: true,
                  };
                if (signedIn)
                  return {
                    status: login.email
                      ? m.settings_devices_agent_source_using_local({
                          email: login.email,
                        })
                      : m.settings_devices_agent_source_using_local_unnamed(),
                    ready: true,
                  };
                return {
                  status: m.settings_devices_agent_source_signed_out({ agent: name }),
                  attention: true,
                  signIn: {
                    label: signingIn
                      ? m.settings_devices_agent_source_stop_sign_in()
                      : m.settings_devices_agent_source_sign_in(),
                    pending: machine.pending,
                    busy: signingIn,
                    onPress: () =>
                      signingIn
                        ? machine.stopSignIn(provider)
                        : machine.signIn(provider),
                    error:
                      login?.signIn?.state === "failed"
                        ? login.signIn.error ||
                          m.settings_devices_agent_sign_in_failed()
                        : undefined,
                  },
                };
              }
              // `none` is also the station's default: only a recorded choice says "does not run".
              if (account.chosen)
                return { status: m.settings_devices_agent_source_off({ agent: name }) };
              return account.workspaceAvailable
                ? { status: m.settings_devices_agent_source_choose() }
                : {
                    status: m.settings_devices_agent_source_no_workspace(),
                    link: addWorkspace,
                  };
            })();
            return {
              id: found?.id ?? `machine_${provider}`,
              provider,
              name,
              status: line.status,
              ready: line.ready === true,
              attention: line.attention === true,
              details: found?.details ?? [],
              ...(line.link ? { link: line.link } : {}),
              ...(line.signIn ? { signIn: line.signIn } : {}),
              source: {
                label: `${name} ${m.settings_devices_agent_source()}`,
                placeholder: m.settings_devices_agent_source_choose_placeholder(),
                // Nothing chosen shows nothing chosen: two available sources are not picked for the person.
                value:
                  account && (account.source !== "none" || account.chosen)
                    ? account.source
                    : undefined,
                disabled: !account || machine.pending,
                items: [
                  ...(account?.workspaceAvailable || account?.source === "workspace"
                    ? [
                        {
                          id: "workspace",
                          label: m.settings_devices_agent_source_workspace(),
                        },
                      ]
                    : []),
                  { id: "local", label: m.settings_devices_agent_source_local() },
                  { id: "endpoint", label: m.settings_devices_agent_source_endpoint() },
                  { id: "none", label: m.settings_devices_agent_source_none() },
                ],
                onChange: (id: string) => {
                  // A model server is chosen with its address: asked first when the station has none.
                  if (id === "endpoint" && !server) changeEndpoint.onPress();
                  else if (
                    id === "workspace" ||
                    id === "local" ||
                    id === "endpoint" ||
                    id === "none"
                  )
                    machine.change(provider, id);
                },
              },
            };
          })
        : agents;
    const connecting = !connected && !device && isLocal;
    return {
      id: device?.device_id ?? "local",
      name: device?.name ?? m.settings_this_device(),
      metadata: device
        ? (
            [
              [m.settings_devices_fact_connection(), path],
              [m.settings_devices_fact_source(), source],
              [
                m.settings_devices_fact_hostname(),
                device.system_info?.hostname !== device.name
                  ? device.system_info?.hostname
                  : undefined,
              ],
              [m.settings_devices_fact_chip(), device.system_info?.cpu_model],
              [
                m.settings_devices_fact_memory(),
                device.system_info?.memory_total
                  ? `${Math.round(device.system_info.memory_total / 1024 ** 3)} GB`
                  : undefined,
              ],
              [
                m.settings_devices_fact_system(),
                [
                  (
                    { darwin: "macOS", linux: "Linux", windows: "Windows" } as Record<
                      string,
                      string
                    >
                  )[device.os ?? ""] ?? device.os,
                  device.system_info?.os_version,
                ]
                  .filter(Boolean)
                  .join(" "),
              ],
              [m.settings_devices_device_id(), device.device_id],
              [
                m.settings_devices_disconnected_at(),
                !connected && device.disconnected_at
                  ? new Date(device.disconnected_at * 1000).toLocaleString()
                  : undefined,
              ],
            ] as const
          ).flatMap(([label, value]) =>
            value ? [[label, value] as [string, string]] : []
          )
        : undefined,
      local: isLocal,
      commaDevice: !!device?.isCommaDevice,
      connected,
      ...(connected && tasksBlocker ? { notice: tasksBlocker } : {}),
      loading: connecting,
      status: connected
        ? m.settings_devices_connected()
        : device && !isLocal
          ? m.settings_devices_disconnected()
          : m.settings_devices_connecting(),
      menu: [
        ...(device
          ? [
              {
                id: "rename",
                label: m.settings_devices_rename(),
                onAction: () => openManagement("rename", device),
              },
            ]
          : []),
        // The sandbox's own: stop it, disconnect it from the workspace, its settings.
        ...(isLocal && compute.node.available && compute.eligible
          ? [
              ...(compute.card.kind === "available" && compute.canManage
                ? [
                    {
                      id: "sandbox-stop",
                      label: m.compute_ui_stop(),
                      onAction: () => compute.openConfirm("drain"),
                    },
                  ]
                : []),
              ...(compute.binding &&
              compute.canManage &&
              (compute.card.kind === "available" ||
                compute.card.kind === "attention") &&
              !compute.card.actions.some((entry) => entry.id === "remove")
                ? [
                    {
                      id: "sandbox-disconnect",
                      label: m.compute_ui_disconnect(),
                      destructive: true,
                      onAction: () => compute.openConfirm("remove"),
                    },
                  ]
                : []),
              {
                id: "sandbox",
                label: m.compute_local_settings(),
                onAction: () => compute.setDetail("settings"),
              },
            ]
          : []),
        ...(device && !isLocal && !isCloud
          ? [
              {
                id: "remove",
                label: m.settings_devices_remove(),
                destructive: true,
                onAction: () => openManagement("remove", device),
              },
            ]
          : []),
      ],
      // Checks run by themselves each visit; only one running or failed is shown, with its retry.
      runtimeCheck:
        device && checks[device.device_id]
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
      agents: rows,
      ...(rows !== agents && (machine.problem || machine.missing)
        ? {
            agentsProblem: {
              label:
                machine.problem === "save"
                  ? m.settings_devices_agent_source_save_failed()
                  : m.settings_devices_agent_source_read_failed(),
              retryLabel: m.settings_devices_agent_source_retry(),
              onRetry: machine.retry,
            },
          }
        : {}),
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
    overlay: compute.nodeOverlay ?? compute.workloads.overlay,
    content: (
      <>
        <ComputeSettingsView
          controller={compute}
          renderHome={({ localNode, workloads }) => (
            <DeviceSettings
              title={m.settings_devices()}
              detailsLabel={m.settings_devices_details()}
              deviceLabel={m.settings_devices_device_group()}
              moreLabel={(name) => m.settings_devices_more({ name })}
              offlineLabel={(count) =>
                m.settings_devices_offline_count({ count: String(count) })
              }
              accessLevels={{
                off: {
                  label: m.settings_devices_access_off(),
                  description: m.settings_devices_access_off_description(),
                },
                read: {
                  label: m.settings_devices_access_read(),
                  description: m.settings_devices_access_read_description(),
                },
                full: {
                  label: m.settings_devices_access_full(),
                  description: m.settings_devices_access_full_description(),
                },
              }}
              closeLabel={m.common_close()}
              guidedLabel={m.settings_devices_router_help()}
              agentsLabel={m.settings_devices_agents_label()}
              emptyAgentsLabel={m.settings_devices_agents_empty()}
              emptyLabel={m.settings_devices_empty()}
              accessLabel={m.settings_devices_access()}
              addLabel={m.settings_devices_add()}
              addDisabled={!shownWorkspace}
              addContent={
                shownWorkspace
                  ? (close) => (
                      <>
                        <AddCommaDeviceOption
                          onSetUp={() => {
                            close();
                            setSettingUp(true);
                          }}
                        />
                        <AddComputerCommand workspace={shownWorkspace} />
                        <LinuxComputeCommand
                          key={shownWorkspace}
                          workspace={shownWorkspace}
                        />
                      </>
                    )
                  : undefined
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
        {settingUp && shownWorkspace && (
          <AddDevice workspace={shownWorkspace} onClose={() => setSettingUp(false)} />
        )}
        {endpointFor && (
          <Dialog
            isOpen
            isDismissable={!machine.pending}
            showCloseButton={!machine.pending}
            title={m.settings_devices_endpoint_title({
              agent: endpointFor.provider === "codex" ? "Codex" : "Claude Code",
            })}
            description={m.settings_devices_endpoint_description({
              agent: endpointFor.provider === "codex" ? "Codex" : "Claude Code",
              protocol:
                endpointFor.provider === "codex"
                  ? "OpenAI Responses"
                  : "Anthropic Messages",
            })}
            onOpenChange={(open) => {
              if (!open && !machine.pending) setEndpointFor(undefined);
            }}
            actions={[
              {
                label: m.settings_profile_cancel(),
                hierarchy: "secondary-gray",
                disabled: machine.pending,
                onPress: () => setEndpointFor(undefined),
              },
              {
                label: m.settings_profile_save(),
                hierarchy: "primary",
                disabled: machine.pending || !endpointFor.address.trim(),
                onPress: () => {
                  void saveEndpoint();
                },
              },
            ]}
          >
            <div className="flex flex-col gap-lg">
              <InputField
                className="w-full"
                label={m.settings_devices_endpoint_address()}
                value={endpointFor.address}
                placeholder="http://localhost:11434"
                maxLength={2048}
                disabled={machine.pending}
                {...(endpointFor.invalid
                  ? { errorMessage: m.settings_devices_endpoint_invalid() }
                  : {})}
                onChange={(event) =>
                  setEndpointFor({
                    ...endpointFor,
                    address: event.target.value,
                    invalid: false,
                  })
                }
              />
              <InputField
                className="w-full"
                label={m.settings_devices_endpoint_key()}
                hint={m.settings_devices_endpoint_key_hint()}
                type="password"
                value={endpointFor.key}
                {...(endpointFor.keyed
                  ? { placeholder: m.settings_devices_endpoint_key_kept() }
                  : {})}
                maxLength={16384}
                autoComplete="off"
                disabled={machine.pending}
                onChange={(event) =>
                  setEndpointFor({ ...endpointFor, key: event.target.value })
                }
              />
            </div>
          </Dialog>
        )}
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
                ? management.commaDevice
                  ? m.devices_remove_message({ name: management.name })
                  : m.settings_devices_remove_description({ name: management.name })
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
