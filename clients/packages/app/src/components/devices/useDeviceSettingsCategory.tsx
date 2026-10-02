import { useCallback, useEffect, useRef, useState } from "react";
import { useNavigate } from "@tanstack/react-router";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import { getNativeBridge } from "@comma/native-bridge";
import {
  Button,
  Menu,
  MenuItem,
  MenuPopover,
  MenuTrigger,
  DeviceSettings,
  Dialog,
  type SettingsCategoryDefinition,
  MoreHorizontalIcon,
} from "@comma/ui";
import { CommaApiError, type CommaApiClient, type CommaDevice } from "../../api";
import { useCommaConnectorScope } from "../useCommaConnectorScope";
import { readActiveWorkspaceId, subscribeActiveWorkspace } from "../activeWorkspace";
import { useOptionalChatActionRegistry } from "../chat/ChatProvider";
import { resolveWorkspaceChat } from "../chat/useWorkspaceChat";
import { needsDesktopApp, requestDesktopApp } from "../DesktopAppPrompt";
import { useCommaSettingsOverlay } from "../settingsOverlay";
import { prefillDeviceDraft } from "./routerDeviceDraft";
import { useDeviceRuntimeChecks } from "./useDeviceRuntimeChecks";

export function useDeviceSettingsCategory(
  api: CommaApiClient,
  enabled: boolean
): SettingsCategoryDefinition {
  const m = useCommaMessages();
  const locale = useCommaLocale();
  const navigate = useNavigate();
  const registry = useOptionalChatActionRegistry();
  const overlay = useCommaSettingsOverlay();
  const local = useCommaConnectorScope(enabled, api);
  const bridge = getNativeBridge();
  const [workspaceId, setWorkspaceId] = useState(readActiveWorkspaceId);
  useEffect(() => subscribeActiveWorkspace(setWorkspaceId), []);
  const [devices, setDevices] = useState<CommaDevice[]>([]);
  const [cursor, setCursor] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [failed, setFailed] = useState(false);
  const [management, setManagement] = useState<{
    kind: "rename" | "remove";
    id: string;
    name: string;
  }>();
  const [deviceName, setDeviceName] = useState("");
  const [managementPending, setManagementPending] = useState(false);
  const [managementError, setManagementError] = useState(false);
  const [dialog, setDialog] = useState<"manual">();
  const [actionError, setActionError] = useState<string>();
  const [pending, setPending] = useState(false);
  const [copied, setCopied] = useState(false);
  const [accessPending, setAccessPending] = useState<readonly string[]>([]);
  const accessRequests = useRef(new Map<string, AbortController>());
  const [now, setNow] = useState(Date.now);
  const [accessError, setAccessError] = useState(false);
  const request = useRef<AbortController | undefined>(undefined);
  const restartPendingLoad = useRef<(() => void) | undefined>(undefined);
  const action = useRef<AbortController | undefined>(undefined);
  const refreshing = useRef(false);
  const onChecked = useCallback((device: CommaDevice) => {
    setDevices((previous) =>
      previous.map((row) => (row.device_id === device.device_id ? device : row))
    );
    setNow(Date.now());
    // A pending read can carry readiness from before this check. Re-read the
    // same page so it cannot overwrite fresh results or lose requested devices.
    restartPendingLoad.current?.();
  }, []);
  const { checks, check, checkExpiredOnEntry } = useDeviceRuntimeChecks(
    api,
    workspaceId,
    enabled,
    onChecked
  );

  const load = useCallback(
    async (after?: string, background = false): Promise<void> => {
      if (!workspaceId || !enabled) return;
      if (background && refreshing.current) return;
      request.current?.abort();
      const controller = new AbortController();
      request.current = controller;
      refreshing.current = true;
      restartPendingLoad.current = () => {
        refreshing.current = false;
        void load(after, background);
      };
      if (!background) setLoading(true);
      // A refresh re-reads the first page and replaces what it covers, so a
      // computer deleted from another client stops being listed here. Pages
      // the reader asked for beyond the first are re-offered, not kept: a
      // stale extra page would outrank the live one it sits under.
      const requestCursor = background ? undefined : after;
      const readDevice = async (id: string) => {
        try {
          return await api.getDevice(workspaceId, id, { signal: controller.signal });
        } catch (error) {
          if (error instanceof CommaApiError && error.status === 404) return undefined;
          throw error;
        }
      };
      try {
        // This computer may sit outside the requested page, so it is read by
        // identity rather than waiting for its page to come around.
        const [listed, current] = await Promise.all([
          api.listDevices(workspaceId, {
            ...(requestCursor ? { cursor: requestCursor } : {}),
            signal: controller.signal,
          }),
          local.deviceId ? readDevice(local.deviceId) : Promise.resolve(undefined),
        ]);
        if (controller.signal.aborted) return;
        setDevices((previous) => {
          const rows = new Map(
            (requestCursor ? previous : []).map((row) => [row.device_id, row])
          );
          for (const row of [...listed.devices, ...(current ? [current] : [])]) {
            rows.delete(row.device_id);
            rows.set(row.device_id, row);
          }
          if (local.deviceId && !current) rows.delete(local.deviceId);
          return [...rows.values()].slice(-50);
        });
        setCursor(listed.next_cursor);
        setFailed(false);
        setNow(Date.now());
        checkExpiredOnEntry(listed.devices, current);
      } catch {
        if (!controller.signal.aborted) setFailed(true);
      } finally {
        if (request.current === controller) {
          request.current = undefined;
          restartPendingLoad.current = undefined;
          refreshing.current = false;
          setLoading(false);
        }
      }
    },
    [api, enabled, local.deviceId, workspaceId, checkExpiredOnEntry]
  );

  useEffect(() => {
    if (!enabled) {
      setManagement(undefined);
      setManagementPending(false);
    }
  }, [enabled]);
  // The state starts out empty for this workspace; only a switch to another
  // workspace resets it. Resetting on mount would swap in equal empty lists and
  // re-render all of Settings as it opens.
  const heldWorkspace = useRef(workspaceId);
  useEffect(() => {
    if (heldWorkspace.current === workspaceId) return;
    heldWorkspace.current = workspaceId;
    setManagement(undefined);
    setManagementPending(false);
    setManagementError(false);
    setDevices([]);
    setCursor(null);
    setAccessPending([]);
    setPending(false);
  }, [workspaceId]);
  useEffect(() => {
    void load();
    return () => request.current?.abort();
  }, [load, local.scope]);
  useEffect(() => {
    if (!enabled || !workspaceId) return undefined;
    const refresh = () => {
      setNow(Date.now());
      if (document.visibilityState === "visible") void load(undefined, true);
    };
    const timer = window.setInterval(refresh, 15_000);
    window.addEventListener("focus", refresh);
    return () => {
      window.clearInterval(timer);
      window.removeEventListener("focus", refresh);
    };
  }, [enabled, load, workspaceId]);
  useEffect(
    () => () => {
      action.current?.abort();
      for (const controller of accessRequests.current.values()) controller.abort();
      accessRequests.current.clear();
    },
    [workspaceId, enabled]
  );

  // One expiry timer for the visible inventory (at most 50 devices), with no API calls.
  // The existing 15-second refresh remains one page plus the local device lookup.
  useEffect(() => {
    if (!enabled) return undefined;
    const nextExpiry = Math.min(
      ...devices
        .flatMap((device) =>
          (device.device_runtimes ?? []).map(
            (runtime) => (runtime.readiness_valid_until ?? 0) * 1000
          )
        )
        .filter((expiry) => expiry > now)
    );
    if (!Number.isFinite(nextExpiry)) return undefined;
    const timer = window.setTimeout(
      () => setNow(Date.now()),
      Math.max(0, nextExpiry - Date.now())
    );
    return () => window.clearTimeout(timer);
  }, [devices, enabled, now]);

  const current = devices.find((device) => device.device_id === local.deviceId);
  const changeAccess = async (
    device: CommaDevice | undefined,
    isLocal: boolean,
    allow: boolean
  ) => {
    setAccessError(false);
    if (isLocal) {
      await local.setScope(allow ? "" : "local_file_read");
      return;
    }
    if (!workspaceId || !device) return;
    const controller = new AbortController();
    accessRequests.current.get(device.device_id)?.abort();
    accessRequests.current.set(device.device_id, controller);
    setAccessPending((previous) => [...previous, device.device_id]);
    try {
      const result = await api.setDeviceAccess(workspaceId, device.device_id, allow, {
        signal: controller.signal,
      });
      if (controller.signal.aborted) return;
      setDevices((previous) =>
        previous.map((candidate) =>
          candidate.device_id === device.device_id
            ? { ...candidate, ...result }
            : candidate
        )
      );
      // The access reply carries the permission alone. Agent readiness is the
      // Connector's to report, so ask for it now instead of leaving the rows
      // under this switch describing the state the reader just left.
      void load(undefined, true);
    } catch {
      if (!controller.signal.aborted) {
        setAccessError(true);
        void load(undefined, true);
      }
    } finally {
      if (accessRequests.current.get(device.device_id) === controller)
        accessRequests.current.delete(device.device_id);
      if (!controller.signal.aborted)
        setAccessPending((previous) =>
          previous.filter((id) => id !== device.device_id)
        );
    }
  };

  const manageDevice = async () => {
    if (!workspaceId || !management || managementPending) return;
    const controller = new AbortController();
    action.current?.abort();
    action.current = controller;
    setManagementPending(true);
    setManagementError(false);
    try {
      if (management.kind === "rename") {
        const updated = await api.renameDevice(
          workspaceId,
          management.id,
          deviceName.trim(),
          { signal: controller.signal }
        );
        if (controller.signal.aborted) return;
        request.current?.abort();
        setDevices((rows) =>
          rows.map((row) => (row.device_id === updated.device_id ? updated : row))
        );
      } else {
        await api.removeDevice(workspaceId, management.id, {
          signal: controller.signal,
        });
        if (controller.signal.aborted) return;
        request.current?.abort();
        setDevices((rows) => rows.filter((row) => row.device_id !== management.id));
      }
      setManagement(undefined);
      void load();
    } catch {
      if (!controller.signal.aborted) setManagementError(true);
    } finally {
      if (!controller.signal.aborted) setManagementPending(false);
    }
  };
  const openManagement = (kind: "rename" | "remove", device: CommaDevice) => {
    setManagement({ kind, id: device.device_id, name: device.name });
    setDeviceName(device.name);
    setManagementError(false);
  };
  const card = (device: CommaDevice | undefined, isLocal: boolean) => {
    const permits = isLocal ? local.scope === "" : device?.allows_operations === true;
    const connected = isLocal ? local.available : device?.status === "connected";
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
            hierarchy="link-gray"
            size="sm"
            aria-label={m.settings_devices_more({ name: device.name })}
          >
            <MoreHorizontalIcon className="size-4" />
          </Button>
          <MenuPopover placement="bottom end">
            <Menu aria-label={m.settings_devices_more({ name: device.name })}>
              <MenuItem onAction={() => openManagement("rename", device)}>
                {m.settings_devices_rename()}
              </MenuItem>
              {!isLocal && (
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
        .filter((runtime) =>
          ["codex", "claude", "pi", "kimi"].includes(runtime.provider)
        )
        .map((runtime) => {
          const expired =
            !runtime.readiness_valid_until ||
            runtime.readiness_valid_until * 1000 <= now;
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
          return {
            id: runtime.device_runtime_id,
            provider: runtime.provider,
            name:
              (
                {
                  codex: "Codex",
                  claude: "Claude Code",
                  pi: "Pi",
                  kimi: "Kimi",
                } as Record<string, string>
              )[runtime.provider] ?? runtime.provider,
            status: statusLabel(),
            ready,
            attention: connected && runtime.issue === "authentication_required",
            description: runtimeDescription(),
            details: [
              `${m.settings_devices_version()}: ${runtime.version || m.settings_devices_not_reported()}`,
              `${m.settings_devices_authentication()}: ${({ chatgpt: "ChatGPT", api_key: "API key", amazon_bedrock: "Amazon Bedrock" } as Record<string, string>)[runtime.auth?.mode ?? ""] || runtime.auth?.backend || m.settings_devices_not_reported()}`,
              `${m.settings_devices_checked()}: ${runtime.readiness_checked_at ? new Date(runtime.readiness_checked_at * 1000).toLocaleString() : m.settings_devices_not_reported()}`,
            ],
          };
        }),
      access: {
        allowed: permits,
        description: m.settings_devices_operations_description(),
        disabled:
          (device ? accessPending.includes(device.device_id) : false) ||
          local.pending ||
          managementPending ||
          (isLocal ? !local.available || local.pending : !connected),
        onChange: (allow: boolean) => {
          void changeAccess(device, isLocal, allow);
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
      await attempt.run(async (chatApi, signal) => {
        const combined = AbortSignal.any([signal, controller.signal]);
        const resolved = await resolveWorkspaceChat({
          api: chatApi,
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
        setDialog(undefined);
        overlay.closeSettings();
        await navigate({ to: "/" });
        requestAnimationFrame(() => {
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

  const copyCommand = async () => {
    if (!workspaceId) return;
    setPending(true);
    setActionError(undefined);
    try {
      const result = await bridge.connectorRuntime.copyConnectCommand({ workspaceId });
      if (!result.copied) throw new Error("Copy unavailable");
      setCopied(true);
    } catch {
      setActionError(m.settings_devices_manual_failed());
    } finally {
      setPending(false);
    }
  };

  return {
    id: "devices",
    icon: "devices",
    label: m.settings_devices(),
    sections: [],
    content: (
      <>
        <DeviceSettings
          title={m.settings_devices()}
          description={m.settings_devices_intro()}
          statusDescription={m.settings_devices_status_description()}
          summary={m.settings_devices_page_summary({
            count: String(items.length),
            online: String(items.filter((item) => item.connected).length),
          })}
          accessDetailsLabel={m.settings_devices_access_details()}
          readOnlyLabel={m.settings_devices_access_readonly()}
          operationsLabel={m.settings_devices_access_allowed()}
          closeLabel={m.common_close()}
          guidedLabel={m.settings_devices_router_help()}
          agentsLabel={m.settings_devices_agents_label()}
          discoveredLabel={m.settings_devices_discovered()}
          emptyAgentsLabel={m.settings_devices_agents_empty()}
          emptyLabel={m.settings_devices_empty()}
          accessLabel={m.settings_devices_allow_operations()}
          addLabel={m.settings_devices_add()}
          manualLabel={m.settings_devices_manual()}
          addDisabled={pending || !registry || !workspaceId}
          manualDisabled={pending}
          onManual={() => {
            if (needsDesktopApp()) {
              requestDesktopApp("device-connect");
              return;
            }
            setDialog("manual");
            setActionError(undefined);
            setCopied(false);
          }}
          localLabel={m.settings_devices_local_label()}
          loadingLabel={m.common_loading()}
          devices={items}
          loading={loading}
          hasMore={!!cursor}
          {...(actionError && !dialog
            ? { error: actionError }
            : failed
              ? { error: m.settings_devices_unavailable() }
              : local.error || accessError
                ? { error: m.settings_devices_permission_failed() }
                : {})}
          onAdd={() => {
            void openRouter();
          }}
          onLoadMore={() => {
            if (cursor) {
              void load(cursor);
            }
          }}
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
        {dialog && (
          <Dialog
            isOpen
            showCloseButton
            title={m.settings_devices_manual()}
            description={m.settings_devices_manual_description()}
            onOpenChange={(open) => {
              if (!open) {
                action.current?.abort();
                setPending(false);
                setDialog(undefined);
              }
            }}
            actions={[
              {
                label: copied ? m.common_copied() : m.common_copy(),
                hierarchy: "primary",
                shortcut: false,
                disabled: pending || copied || !workspaceId,
                onPress: () => {
                  void copyCommand();
                },
              },
            ]}
          >
            {actionError && (
              <p className="text-sm text-error-primary" role="alert">
                {actionError}
              </p>
            )}
          </Dialog>
        )}
      </>
    ),
  };
}
