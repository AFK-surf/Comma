import { useEffect, useRef, useState, type ReactNode } from "react";
import { getActiveCommaConfig } from "@comma/config";
import { useCall, useTopic } from "@comma/core-client";
import { useCommaMessages } from "@comma/i18n/react";
import { Button } from "@comma/ui/components/Button";
import { Dialog } from "@comma/ui/components/dialog";
import { LinearProviderLogo } from "@comma/ui/components/provider-brand-logos";
import type {
  SettingsControl,
  SettingsPanelItem,
} from "@comma/ui/components/settings-panel";
import { Dropdown } from "@comma/ui/components/dropdown";
import { openNativePlatformExternalUrlFromUserAction } from "../../nativePlatformActions";

type Policy = "unchanged" | "in_review" | "done";
const POLICIES: readonly Policy[] = ["unchanged", "in_review", "done"];

/**
 * Settings › Channels › Linear: connect the person's Linear account to this
 * workspace (an OAuth window Linear answers; the first person in an
 * organization also installs Comma there), see the link and the
 * organization, choose what happens to an issue when its Task completes (its
 * Task runs where and on what the workspace's defaults say), reconnect, disconnect,
 * or, as the installer, remove Comma from the organization
 * (docs/architecture/DOMAIN_CONCEPTS.md#linear-agent-installation).
 *
 * The core follows the connect while this page is away; a login window this
 * window opened and then closed cancels it here.
 */
export function useLinearIntegration(
  workspaceId: string | undefined,
  active: boolean
): { item: SettingsPanelItem; overlay: ReactNode } {
  const m = useCommaMessages();
  const call = useCall();
  const { value: shown } = useTopic(
    active && workspaceId ? { topic: "linear", workspace: workspaceId } : null
  );
  const state = shown?.state ?? undefined;
  const installation = state?.installation ?? undefined;
  const member = state?.member ?? undefined;
  const attempt = shown?.attempt ?? undefined;
  const busy = shown?.busy ?? false;
  const checks = shown?.checks ?? 0;
  const [failedHere, setFailedHere] = useState(false);
  const [dialog, setDialog] = useState<"reconnect" | "uninstall">();
  const error = (shown?.error ?? false) || failedHere;
  // The connect window this window opened: a connect whose window was closed is cancelled.
  const connectWindow = useRef<Window | undefined>(undefined);

  useEffect(() => {
    if (!active) setDialog(undefined);
    setFailedHere(false);
  }, [active, workspaceId]);

  useEffect(() => {
    if (!workspaceId || !attempt || !connectWindow.current?.closed) return;
    connectWindow.current = undefined;
    void call("linear.cancel", { workspace: workspaceId, closed: true }).catch(
      () => undefined
    );
  }, [call, workspaceId, attempt, checks]);

  const connect = async () => {
    if (!workspaceId || busy) return;
    const workspace = workspaceId;
    setFailedHere(false);
    try {
      const popup = await openNativePlatformExternalUrlFromUserAction(async () => {
        const started = await call("linear.connect", {
          workspace,
          environment: getActiveCommaConfig().channel,
        });
        return started.authorizationUrl;
      });
      connectWindow.current = popup ?? undefined;
    } catch {
      // A blocked window never reached the core: say so here. A refused start the core says itself.
      setFailedHere(true);
    }
  };

  const cancel = () => {
    if (!workspaceId) return;
    connectWindow.current = undefined;
    void call("linear.cancel", { workspace: workspaceId }).catch(() => undefined);
  };

  const disconnect = (scope: "member" | "organization") => {
    if (!workspaceId || busy) return;
    void call("linear.disconnect", { workspace: workspaceId, scope }).catch(
      () => undefined
    );
  };

  const update = (change: { completion_state_policy?: Policy }) => {
    if (!workspaceId || busy) return;
    void call("linear.updateSettings", { workspace: workspaceId, ...change }).catch(
      () => undefined
    );
  };

  const revoked = Boolean(installation?.revoked);
  const live = Boolean(member && installation && !revoked);
  const installer = Boolean(installation?.installer);
  const loaded = Boolean(state);
  const organization = installation
    ? (installation.organization_name ??
      installation.organization_url_key ??
      installation.organization_id)
    : undefined;

  let description = m.settings_linear_description();
  if (error) description = m.settings_linear_action_failed();
  else if (!loaded && !attempt) description = m.settings_telegram_loading();
  else if (busy || attempt) description = m.settings_linear_connecting();
  else if (member && revoked) description = m.settings_linear_revoked();
  else if (state && !state.configured) description = m.settings_linear_unavailable();

  let control: SettingsControl;
  if (attempt) {
    control = {
      type: "button",
      label: m.settings_telegram_cancel_connect(),
      onPress: cancel,
    };
  } else if (member) {
    control = {
      type: "menu",
      label: m.settings_telegram_manage(),
      disabled: busy,
      items: [
        {
          id: "reconnect",
          label: m.settings_telegram_reconnect(),
          onPress: () => setDialog("reconnect"),
        },
        {
          id: "disconnect",
          label: m.settings_telegram_disconnect(),
          tone: "destructive",
          onPress: () => disconnect("member"),
        },
        ...(installer
          ? [
              {
                id: "uninstall",
                label: m.settings_linear_uninstall(),
                tone: "destructive" as const,
                onPress: () => setDialog("uninstall"),
              },
            ]
          : []),
      ],
    };
  } else {
    control = {
      type: "button",
      label: m.settings_telegram_connect(),
      disabled: busy || !workspaceId || !state?.configured,
      onPress: () => void connect(),
    };
  }

  let status: NonNullable<SettingsPanelItem["integration"]>["status"] = {
    label: m.settings_telegram_disconnected(),
    color: "gray",
  };
  if (error)
    status = { label: m.settings_telegram_needs_attention(), color: "warning" };
  else if (!loaded && !attempt)
    status = { label: m.settings_telegram_loading(), color: "gray", loading: true };
  else if (attempt || busy)
    status = { label: m.settings_telegram_pending(), color: "blue" };
  else if (member && revoked)
    status = { label: m.settings_telegram_needs_attention(), color: "warning" };
  else if (live) status = { label: m.settings_telegram_connected(), color: "success" };

  const policyLabel = (policy: Policy) =>
    policy === "in_review"
      ? m.settings_linear_completion_in_review()
      : policy === "done"
        ? m.settings_linear_completion_done()
        : m.settings_linear_completion_unchanged();

  let content: ReactNode;
  if (live) {
    content = (
      <div className="flex flex-col gap-lg" data-setting-id="linear.settings">
        <Dropdown
          disabled={busy}
          items={POLICIES.map((policy) => ({ id: policy, label: policyLabel(policy) }))}
          label={m.settings_linear_completion()}
          onChange={(id) => update({ completion_state_policy: id as Policy })}
          value={member?.completion_state_policy ?? "unchanged"}
        />
      </div>
    );
  } else if (installer && !member && !attempt && organization) {
    // The person unlinked but their workspace still holds the organization's
    // installation: it can be removed from here.
    content = (
      <div
        className="flex flex-wrap items-center gap-md"
        data-setting-id="linear.installed"
      >
        <p className="m-0 min-w-0 flex-1 basis-40 text-xs leading-5 text-tertiary [overflow-wrap:anywhere]">
          {m.settings_linear_installed_by_you({ organization })}
        </p>
        <Button
          disabled={busy}
          hierarchy="secondary-gray"
          onPress={() => setDialog("uninstall")}
          size="sm"
        >
          {m.settings_linear_uninstall()}
        </Button>
      </div>
    );
  }

  const account = member
    ? (member.linear_user_name ?? member.linear_user_email ?? member.linear_user_id)
    : m.settings_telegram_disconnected();

  return {
    item: {
      id: "linear.connection",
      title: m.settings_linear(),
      icon: <LinearProviderLogo />,
      description,
      descriptionLoading:
        !error && Boolean(workspaceId) && (!loaded || busy || Boolean(attempt)),
      control,
      keywords: [
        "Linear",
        m.settings_telegram_connect(),
        m.settings_telegram_reconnect(),
        m.settings_telegram_disconnect(),
      ],
      integration: {
        status,
        content,
        details: [
          {
            label: m.settings_linear_organization(),
            value: organization ?? m.settings_telegram_disconnected(),
          },
          { label: m.settings_linear_account(), value: account },
        ],
        note: live
          ? m.settings_linear_installed_note()
          : m.settings_linear_setup_note(),
      },
    },
    overlay:
      dialog === "reconnect" && active ? (
        <Dialog
          isOpen
          isDismissable
          onOpenChange={(open) => !open && setDialog(undefined)}
          title={m.settings_linear_replace_title()}
          description={m.settings_linear_replace_description()}
          actions={[
            {
              label: m.settings_profile_cancel(),
              hierarchy: "secondary-gray",
              onPress: () => setDialog(undefined),
            },
            {
              label: m.settings_telegram_reconnect(),
              hierarchy: "primary",
              disabled: busy || !workspaceId,
              onPress: () => {
                setDialog(undefined);
                void connect();
              },
            },
          ]}
        />
      ) : dialog === "uninstall" && active ? (
        <Dialog
          isOpen
          isDismissable
          onOpenChange={(open) => !open && setDialog(undefined)}
          title={m.settings_linear_uninstall_title({
            organization: organization ?? "Linear",
          })}
          description={m.settings_linear_uninstall_description()}
          actions={[
            {
              label: m.settings_profile_cancel(),
              hierarchy: "secondary-gray",
              onPress: () => setDialog(undefined),
            },
            {
              label: m.settings_linear_uninstall(),
              hierarchy: "destructive",
              disabled: busy || !workspaceId,
              onPress: () => {
                setDialog(undefined);
                disconnect("organization");
              },
            },
          ]}
        />
      ) : null,
  };
}
