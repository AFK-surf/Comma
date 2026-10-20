import { useEffect, useState } from "react";
import { useCall, useTopic, type TailnetStatus } from "@comma/core-client";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import { Button } from "@comma/ui/components/Button";
import { Checkbox } from "@comma/ui/components/checkbox";
import { Dialog } from "@comma/ui/components/dialog";
import { InputField } from "@comma/ui/components/input";
import type {
  SettingsCategoryDefinition,
  SettingsCategoryDetail,
} from "@comma/ui/components/settings";
import type {
  SettingsControl,
  SettingsPanelItem,
} from "@comma/ui/components/settings-panel";
import { useWorkspacePreference } from "../activeWorkspace";
import {
  nativePlatformClipboard,
  openNativePlatformExternalUrl,
} from "../../nativePlatformActions";

type Messages = ReturnType<typeof useCommaMessages>;
type Draft = { tags: string; expected: string; acceptRoutes: boolean };

const WAITING = new Set<TailnetStatus["state"]>([
  "starting",
  "needs_login",
  "needs_approval",
]);

/** Tags as typed in one field: comma- or space-separated. */
export function tailnetTags(text: string): string[] {
  return text
    .split(/[\s,]+/)
    .map((tag) => tag.trim())
    .filter(Boolean);
}

function stateLabel(state: TailnetStatus["state"], m: Messages): string {
  switch (state) {
    case "idle":
      return m.settings_tailscale_state_idle();
    case "starting":
      return m.settings_tailscale_state_starting();
    case "needs_login":
      return m.settings_tailscale_state_needs_login();
    case "needs_approval":
      return m.settings_tailscale_state_needs_approval();
    case "running":
      return m.settings_tailscale_state_running();
    case "error":
      return m.settings_tailscale_state_error();
    default:
      return m.settings_tailscale_state_disabled();
  }
}

/**
 * Settings › Tailscale: the workspace's node in the owner's own Tailscale
 * network. Connect returns a login link for a tailnet admin; the core reads
 * the status every 3 s while the node waits. The link is never written to
 * storage: whoever opens it adds the node to their tailnet.
 */
export function useTailscaleCategory(active: boolean): SettingsCategoryDefinition {
  const m = useCommaMessages();
  const locale = useCommaLocale();
  const call = useCall();
  // The active workspace, as the Models category resolves it: the remembered
  // choice, else the first workspace the API lists.
  const prefer = useWorkspacePreference();
  const { value: shown } = useTopic(
    active && prefer !== undefined ? { topic: "tailnet", prefer } : null
  );
  const workspaceId = shown?.workspace ?? undefined;
  const status = shown?.status ?? undefined;
  const peers = shown?.peers ?? [];
  const loadError = shown?.error ?? false;
  const busy = shown?.busy ?? false;
  const [saveError, setSaveError] = useState(false);
  const [draft, setDraft] = useState<Draft>();
  const [confirming, setConfirming] = useState(false);

  useEffect(() => {
    setSaveError(false);
    setDraft(undefined);
    setConfirming(false);
  }, [active, workspaceId]);

  const write = (run: (workspace: string) => Promise<unknown>, onDone?: () => void) => {
    if (busy || !workspaceId) return;
    const workspace = workspaceId;
    setSaveError(false);
    void run(workspace).then(
      () => onDone?.(),
      () => setSaveError(true)
    );
  };

  const refresh = () => {
    if (busy || !workspaceId) return;
    setSaveError(false);
    void call("tailnet.refresh", { workspace: workspaceId }).catch(() => undefined);
  };
  const edit = () =>
    status &&
    setDraft({
      tags: (status.enabled ? status.settings.tags : ["tag:comma-agent"]).join(", "),
      expected: status.settings.expected_tailnet ?? "",
      acceptRoutes: status.settings.accept_routes,
    });
  const save = () => {
    if (!draft) return;
    write(
      (workspace) =>
        call("tailnet.connect", {
          workspace,
          tags: tailnetTags(draft.tags),
          accept_routes: draft.acceptRoutes,
          expected_tailnet: draft.expected.trim() || null,
        }),
      () => setDraft(undefined)
    );
  };
  const disconnect = () =>
    write(
      (workspace) => call("tailnet.disconnect", { workspace }),
      () => setConfirming(false)
    );

  const loaded = Boolean(status);
  let description = m.settings_tailscale_description();
  if (loadError) description = m.settings_tailscale_error();
  else if (saveError) description = m.settings_tailscale_save_failed();
  else if (!workspaceId || !status) description = m.settings_telegram_loading();
  else if (status.state === "error" || status.error)
    description = m.settings_tailscale_node_error({
      code: status.error?.code ?? "tailnet_unavailable",
    });
  else if (status.state === "running" && status.tailnet)
    description = m.settings_tailscale_running_description({
      tailnet: status.tailnet,
      node: status.node_name ?? "—",
    });
  else if (status.state === "idle" && status.tailnet)
    description = m.settings_tailscale_idle_description({ tailnet: status.tailnet });
  else if (status.state === "needs_approval")
    description = m.settings_tailscale_needs_approval_description();
  else if (status.state === "needs_login")
    description = m.settings_tailscale_login_note();

  let control: SettingsControl;
  if (loadError || (status && WAITING.has(status.state)))
    control = {
      type: "button",
      label: m.settings_tailscale_refresh(),
      disabled: busy || !workspaceId,
      onPress: refresh,
    };
  else
    control = {
      type: "button",
      label: status?.enabled
        ? m.settings_tailscale_settings()
        : m.settings_tailscale_connect(),
      disabled: busy || !loaded,
      onPress: edit,
    };

  let badge: NonNullable<SettingsPanelItem["integration"]>["status"];
  if (loadError || saveError || status?.state === "error")
    badge = { label: m.settings_tailscale_state_error(), color: "warning" };
  else if (!status)
    badge = { label: m.settings_telegram_loading(), color: "gray", loading: true };
  else if (WAITING.has(status.state))
    badge = { label: stateLabel(status.state, m), color: "blue" };
  else if (status.enabled)
    badge = { label: stateLabel(status.state, m), color: "success" };
  else badge = { label: stateLabel(status.state, m), color: "gray" };

  const details: { label: string; value: string }[] = [];
  if (status?.node_name)
    details.push({ label: m.settings_tailscale_node(), value: status.node_name });
  if (status?.addresses.length)
    details.push({
      label: m.settings_tailscale_addresses(),
      value: status.addresses.join(", "),
    });

  const loginUrl = status?.state === "needs_login" ? status.login_url : null;
  const content = status ? (
    <div className="flex flex-col gap-xl">
      {loginUrl ? (
        <div className="flex flex-col gap-md" data-testid="tailscale-login">
          <p className="text-sm leading-5 text-primary">
            {m.settings_tailscale_login_title()}
          </p>
          <p className="text-xs leading-5 text-tertiary [overflow-wrap:anywhere]">
            {m.settings_tailscale_login_note()}
          </p>
          <code
            className="text-xs leading-5 text-primary [overflow-wrap:anywhere]"
            data-testid="tailscale-login-url"
          >
            {loginUrl}
          </code>
          <div className="flex flex-wrap gap-sm">
            <Button
              hierarchy="primary"
              onPress={() => void openNativePlatformExternalUrl(loginUrl)}
              size="sm"
            >
              {m.settings_tailscale_login_open()}
            </Button>
            <Button
              hierarchy="secondary-gray"
              onPress={() => void nativePlatformClipboard.writeText(loginUrl)}
              size="sm"
            >
              {m.settings_tailscale_login_copy()}
            </Button>
          </div>
        </div>
      ) : null}
      {status.enabled && (status.tailnet || status.state === "running") ? (
        <p className="text-xs leading-5 text-tertiary">
          {status.key_expiry
            ? m.settings_tailscale_key_expiry({
                date: new Date(status.key_expiry).toLocaleDateString(locale, {
                  year: "numeric",
                  month: "short",
                  day: "numeric",
                }),
              })
            : m.settings_tailscale_key_never()}
        </p>
      ) : null}
      {peers.length > 0 ? (
        <ul
          aria-label={m.settings_tailscale_devices()}
          className="m-0 list-none space-y-md p-0"
        >
          {peers.map((peer) => (
            <li
              className="flex flex-wrap items-center gap-md"
              key={peer.dns_name ?? peer.name}
            >
              <div className="min-w-0 flex-1 basis-40">
                <p className="text-sm leading-5 text-primary [overflow-wrap:anywhere]">
                  {peer.dns_name ?? peer.name}
                </p>
                <p className="text-xs leading-5 text-tertiary [overflow-wrap:anywhere]">
                  {[peer.ips.join(", "), peer.os, ...peer.routes]
                    .filter(Boolean)
                    .join(" · ")}
                </p>
              </div>
              <p className="text-xs leading-5 text-tertiary">
                {peer.online
                  ? m.settings_tailscale_device_online()
                  : m.settings_tailscale_device_offline()}
              </p>
            </li>
          ))}
        </ul>
      ) : null}
      {status.enabled ? (
        <div>
          <Button
            hierarchy="secondary-gray"
            isDisabled={busy}
            onPress={() => setConfirming(true)}
            size="sm"
          >
            {m.settings_tailscale_disconnect()}
          </Button>
        </div>
      ) : null}
    </div>
  ) : undefined;

  const item: SettingsPanelItem = {
    id: "tailscale.connection",
    title: m.settings_tailscale(),
    description,
    descriptionLoading: !loadError && Boolean(workspaceId) && !loaded,
    control,
    keywords: ["Tailscale", "tailnet", "VPN", "network", "网络"],
    integration: {
      status: badge,
      content,
      details,
      note: m.settings_tailscale_description(),
    },
  };

  const detail: SettingsCategoryDetail | undefined = draft
    ? {
        id: "tailscale.settings",
        title: m.settings_tailscale_title(),
        description: m.settings_tailscale_description(),
        backLabel: m.settings_tailscale(),
        onBack: () => setDraft(undefined),
        onSubmit: save,
        actions: (
          <Button hierarchy="primary" isDisabled={busy} onPress={save} size="sm">
            {status?.enabled
              ? m.settings_tailscale_save()
              : m.settings_tailscale_connect()}
          </Button>
        ),
        content: (
          <div className="flex flex-col gap-lg">
            <InputField
              hint={m.settings_tailscale_tags_hint()}
              label={m.settings_tailscale_tags()}
              onChange={(event) => setDraft({ ...draft, tags: event.target.value })}
              placeholder="tag:comma-agent"
              value={draft.tags}
              {...(saveError
                ? { errorMessage: m.settings_tailscale_save_failed() }
                : {})}
            />
            <InputField
              hint={m.settings_tailscale_expected_hint()}
              label={m.settings_tailscale_expected()}
              onChange={(event) => setDraft({ ...draft, expected: event.target.value })}
              placeholder="example.com"
              value={draft.expected}
            />
            <Checkbox
              checked={draft.acceptRoutes}
              label={m.settings_tailscale_accept_routes()}
              onChange={(event) =>
                setDraft({ ...draft, acceptRoutes: event.target.checked })
              }
              size="sm"
            />
          </div>
        ),
      }
    : undefined;

  return {
    id: "tailscale",
    icon: "tailscale",
    keywords: ["tailscale", "tailnet", "vpn", "network", "网络"],
    label: m.settings_tailscale(),
    title: m.settings_tailscale_title(),
    sections: [{ id: "tailscale.network", title: "", items: [item] }],
    ...(detail ? { detail } : {}),
    overlay: confirming ? (
      <Dialog
        actions={[
          {
            label: m.settings_tailscale_cancel(),
            hierarchy: "secondary-gray",
            onPress: () => setConfirming(false),
          },
          {
            label: m.settings_tailscale_disconnect(),
            hierarchy: "destructive",
            disabled: busy,
            onPress: disconnect,
          },
        ]}
        description={m.settings_tailscale_disconnect_body()}
        isDismissable
        isOpen
        onOpenChange={(open) => {
          if (!open) setConfirming(false);
        }}
        title={m.settings_tailscale_disconnect_title()}
      />
    ) : null,
  };
}
