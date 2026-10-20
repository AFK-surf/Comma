import { useCallback, useEffect, useState, type ReactNode } from "react";
import { useCall, useTopic, type SignalCode } from "@comma/core-client";
import type { CommaLocale } from "@comma/i18n";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import { Button } from "@comma/ui/components/Button";
import { SignalProviderLogo } from "@comma/ui/components/provider-brand-logos";
import {
  type SettingsControl,
  type SettingsPanelItem,
} from "@comma/ui/components/settings-panel";
import {
  SignalCodePanel,
  SignalDialog,
  type SignalDialogState,
} from "./SignalSettings";

type Messages = ReturnType<typeof useCommaMessages>;

function formatDate(ms: number | null | undefined, locale: CommaLocale): string {
  if (!ms) return "—";
  return new Date(ms).toLocaleDateString(locale, { month: "short", day: "numeric" });
}

function formatTime(ms: number, locale: CommaLocale): string {
  return new Date(ms).toLocaleTimeString(locale, {
    hour: "numeric",
    minute: "2-digit",
  });
}

/** A refused number, in words the person can act on. */
function numberErrorMessage(error: unknown, m: Messages): string {
  const code = (error as { code?: unknown } | null)?.code;
  if (code === "signal_account_not_found") return m.settings_signal_number_not_found();
  if (code === "signal_account_scope") return m.settings_signal_number_scope();
  if (code === "signal_account_inactive") return m.settings_signal_number_inactive();
  return m.settings_signal_save_failed();
}

function Row({
  id,
  title,
  description,
  children,
}: {
  id: string;
  title: string;
  description: string;
  children?: ReactNode;
}) {
  return (
    <li className="flex flex-wrap items-center gap-md" data-setting-id={id}>
      <div className="min-w-0 flex-1 basis-40">
        <p className="text-sm leading-5 text-primary [overflow-wrap:anywhere]">
          {title}
        </p>
        <p className="text-xs leading-5 text-tertiary [overflow-wrap:anywhere]">
          {description}
        </p>
      </div>
      <div className="flex shrink-0 flex-wrap gap-sm">{children}</div>
    </li>
  );
}

/**
 * Settings › Channels › Signal: connect Signal chats to the workspace's
 * default group with a one-time code sent from Signal, see and disconnect
 * connected chats, and choose the workspace's own Signal number
 * (docs/messaging-voice.md).
 *
 * A new code is never written to storage; it is gone once the person
 * dismisses it or leaves the category.
 */
export function useSignalIntegration(
  workspaceId: string | undefined,
  active: boolean
): { item: SettingsPanelItem; overlay: ReactNode } {
  const m = useCommaMessages();
  const locale = useCommaLocale();
  const call = useCall();
  const { value: shown } = useTopic(
    active && workspaceId ? { topic: "signal", workspace: workspaceId } : null
  );
  const integration = shown?.integration ?? undefined;
  const number = shown?.number ?? undefined;
  const loadError = shown?.error ?? false;
  const busy = shown?.busy ?? false;
  const [saveError, setSaveError] = useState(false);
  const [created, setCreated] = useState<SignalCode>();
  const [dialog, setDialog] = useState<SignalDialogState>();
  const [dialogError, setDialogError] = useState<string>();

  useEffect(() => {
    setSaveError(false);
    setCreated(undefined);
    setDialog(undefined);
    setDialogError(undefined);
  }, [active, workspaceId]);

  const openDialog = useCallback((next: SignalDialogState | undefined) => {
    setDialogError(undefined);
    setDialog(next);
  }, []);

  const write = (run: (workspace: string) => Promise<void>, inDialog: boolean) => {
    if (busy || !workspaceId) return;
    const workspace = workspaceId;
    setSaveError(false);
    setDialogError(undefined);
    void (async () => {
      try {
        await run(workspace);
        if (inDialog) openDialog(undefined);
      } catch (error) {
        if (inDialog) setDialogError(numberErrorMessage(error, m));
        else setSaveError(true);
      }
    })();
  };

  const refresh = () => {
    if (busy || !workspaceId) return;
    setSaveError(false);
    void call("signal.refresh", { workspace: workspaceId }).catch(() => undefined);
  };
  const newCode = () =>
    write(async (workspace) => {
      const code = await call("signal.newCode", { workspace });
      if (code) setCreated(code);
    }, false);
  const cancelCode = (claim: string) =>
    write(async (workspace) => {
      await call("signal.cancelCode", { workspace, claim });
    }, false);
  const saveNumber = (value: string, inDialog: boolean) =>
    write(async (workspace) => {
      await call("signal.setNumber", { workspace, number: value });
    }, inDialog);
  const disconnect = (binding: string) =>
    write(async (workspace) => {
      await call("signal.disconnect", { workspace, binding });
    }, true);

  const loaded = Boolean(integration && number);
  const account = integration?.account?.e164;
  const bindings = integration?.bindings ?? [];
  const claims = integration?.pending_claims ?? [];
  // A used, cancelled or expired code leaves the pending list; so does its panel.
  const code = claims.some((claim) => claim.claim_id === created?.claimId)
    ? created
    : undefined;
  const own = number?.override?.e164;
  const platform = number?.platform?.e164;

  // The subtitle reports only trouble or progress.
  let description: string | undefined;
  if (loadError) description = m.settings_signal_error();
  else if (saveError) description = m.settings_signal_save_failed();
  else if (!workspaceId || !loaded) description = m.settings_telegram_loading();
  else if (!account) description = m.settings_signal_no_number_description();
  else if (claims.length > 0) description = m.settings_signal_waiting();

  let control: SettingsControl;
  if (loadError)
    control = {
      type: "button",
      label: m.settings_imessage_refresh(),
      disabled: busy || !workspaceId,
      onPress: refresh,
    };
  else if (bindings.length > 0)
    control = {
      type: "button",
      label: m.settings_signal_new_code(),
      disabled: busy || !account,
      onPress: newCode,
    };
  else
    control = {
      type: "button",
      label: m.settings_telegram_connect(),
      disabled: busy || !loaded || !account,
      onPress: newCode,
    };

  let status: NonNullable<SettingsPanelItem["integration"]>["status"];
  if (loadError || saveError)
    status = { label: m.settings_telegram_needs_attention(), color: "warning" };
  else if (!loaded)
    status = { label: m.settings_telegram_loading(), color: "gray", loading: true };
  else if (claims.length > 0)
    status = { label: m.settings_telegram_pending(), color: "blue" };
  else if (bindings.length > 0)
    status = { label: m.settings_telegram_connected(), color: "success" };
  else status = { label: m.settings_telegram_disconnected(), color: "gray" };

  const content = loaded ? (
    <div className="flex flex-col gap-xl">
      {code ? (
        <SignalCodePanel
          command={code.command}
          number={code.number}
          onDismiss={() => setCreated(undefined)}
        />
      ) : null}
      {claims.length > 0 || bindings.length > 0 ? (
        <ul
          aria-label={m.settings_signal_chats()}
          className="m-0 list-none space-y-md p-0"
        >
          {claims.map((claim) => (
            <Row
              description={m.settings_signal_pending_code_description({
                time: formatTime(claim.expires_at, locale),
              })}
              id={`signal.claim.${claim.claim_id}`}
              key={claim.claim_id}
              title={m.settings_signal_pending_code()}
            >
              <Button
                disabled={busy}
                hierarchy="secondary-gray"
                onPress={() => cancelCode(claim.claim_id)}
                size="sm"
              >
                {m.settings_signal_cancel_code()}
              </Button>
            </Row>
          ))}
          {bindings.map((binding) => {
            const kind =
              binding.kind === "group"
                ? m.settings_signal_chat_group()
                : m.settings_signal_chat_person();
            const name = binding.display_name || kind;
            return (
              <Row
                description={m.settings_signal_chat_details({
                  kind,
                  date: formatDate(binding.bound_at, locale),
                  number: binding.number ?? "—",
                })}
                id={`signal.chat.${binding.binding_id}`}
                key={binding.binding_id}
                title={name}
              >
                <Button
                  aria-label={`${m.settings_signal_disconnect()} (${name})`}
                  disabled={busy}
                  hierarchy="secondary-gray"
                  onPress={() =>
                    openDialog({
                      kind: "disconnect",
                      bindingId: binding.binding_id,
                      name,
                    })
                  }
                  size="sm"
                >
                  {m.settings_signal_disconnect()}
                </Button>
              </Row>
            );
          })}
        </ul>
      ) : null}
      <ul className="m-0 list-none p-0">
        <Row
          description={
            own
              ? m.settings_signal_number_own({ number: own })
              : platform
                ? m.settings_signal_number_platform({ number: platform })
                : m.settings_signal_number_none()
          }
          id="signal.number"
          title={m.settings_signal_number_row()}
        />
      </ul>
    </div>
  ) : undefined;

  return {
    item: {
      id: "signal.connection",
      title: m.settings_signal(),
      icon: <SignalProviderLogo />,
      ...(description ? { description } : {}),
      descriptionLoading: !loadError && Boolean(workspaceId) && !loaded,
      control,
      keywords: [
        "Signal",
        "信号",
        m.settings_signal_new_code(),
        m.settings_signal_disconnect(),
      ],
      integration: {
        status,
        content,
        details: [],
        note: m.settings_signal_scope(),
      },
    },
    overlay: dialog ? (
      <SignalDialog
        dialog={dialog}
        error={dialogError}
        onClose={() => openDialog(undefined)}
        onDisconnect={disconnect}
        onSaveNumber={(value) => saveNumber(value, true)}
        pending={busy}
      />
    ) : null,
  };
}
