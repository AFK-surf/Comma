import { useEffect, useState } from "react";
import { useCall, useTopic } from "@comma/core-client";
import { useCommaMessages } from "@comma/i18n/react";
import { uiClock } from "@comma/ui/clock";
import { IMessageProviderLogo } from "@comma/ui/components/provider-brand-logos";
import {
  type SettingsControl,
  type SettingsPanelItem,
} from "@comma/ui/components/settings-panel";
import { IMessageCodePanel, IMessageAccountForm } from "./IMessageSettings";

type Messages = ReturnType<typeof useCommaMessages>;

/** A refused start, in words the person can act on. */
function startErrorMessage(error: unknown, m: Messages): string {
  const code = (error as { code?: unknown } | null)?.code;
  if (code === "invalid_imessage_handle") return m.settings_imessage_invalid_account();
  if (code === "imessage_capacity_reached") return m.settings_imessage_no_lines();
  if (code === "imessage_unavailable") return m.settings_imessage_offline();
  return m.settings_imessage_failed();
}

/** The UI clock's time, again every second while `on` (a countdown is presentation, not business timing). */
function useSecondTick(on: boolean): number {
  const [now, setNow] = useState(() => uiClock.now());
  useEffect(() => {
    if (!on) return;
    setNow(uiClock.now());
    return uiClock.every(1_000, () => setNow(uiClock.now()));
  }, [on]);
  return now;
}

/**
 * Settings › Channels › iMessage over Photon shared lines: the person enters the
 * phone number or email iMessage uses, gets a line and a ten-minute code, and sends the
 * code to that line from that account (docs/messaging-voice.md). The core reads
 * the state and checks the attempt; this shows it and asks for changes.
 *
 * Shown only when the server says Photon is set up; the relay transport stays hidden.
 */
export function useIMessageIntegration(
  workspaceId: string | undefined,
  active: boolean
): SettingsPanelItem | null {
  const m = useCommaMessages();
  const call = useCall();
  const { value } = useTopic(
    active && workspaceId ? { topic: "imessage", workspace: workspaceId } : null
  );
  const state = value?.state ?? undefined;
  const loadError = value?.error ?? false;
  const busy = value?.busy ?? false;
  const [entering, setEntering] = useState(false);
  const [startError, setStartError] = useState<string>();
  const [actionFailed, setActionFailed] = useState(false);

  useEffect(() => {
    setEntering(false);
    setStartError(undefined);
    setActionFailed(false);
  }, [active, workspaceId]);

  const claim = state?.pending_claim;
  const attempt =
    claim?.transport === "photon" && claim.line_handle && claim.sender_handle
      ? claim
      : undefined;
  const link = state?.link;
  const now = useSecondTick(Boolean(attempt));
  const remainingMs = attempt ? attempt.expires_at * 1000 - now : 0;
  const expired = Boolean(attempt) && remainingMs <= 0;

  if (!state?.photon_configured && !loadError) return null;
  // A read failed before Photon was known: say nothing about a channel that may not exist.
  if (loadError && !state) return null;

  const ask = (
    name: "imessage.refresh" | "imessage.cancel" | "imessage.disconnect"
  ) => {
    if (busy || !workspaceId) return;
    setActionFailed(false);
    void call(name, { workspace: workspaceId }).catch(() => setActionFailed(true));
  };
  const start = (handle: string) => {
    if (busy || !workspaceId) return;
    setStartError(undefined);
    setActionFailed(false);
    void call("imessage.start", { workspace: workspaceId, handle }).then(
      () => setEntering(false),
      (error: unknown) => setStartError(startErrorMessage(error, m))
    );
  };
  const changeNumber = () => {
    setStartError(undefined);
    setEntering(true);
    ask("imessage.cancel");
  };

  const showForm = entering && !attempt;

  // The subtitle reports only trouble or progress.
  let description: string | undefined;
  if (loadError || actionFailed) description = m.settings_imessage_failed();
  else if (expired) description = m.settings_imessage_code_expired();
  else if (attempt) description = m.settings_imessage_waiting_reply();
  else if (link && !state.connection_active)
    description = m.settings_telegram_repair_required();
  else if (!link) description = m.settings_imessage_description();

  let control: SettingsControl;
  if (loadError)
    control = {
      type: "button",
      label: m.settings_imessage_refresh(),
      disabled: busy || !workspaceId,
      onPress: () => ask("imessage.refresh"),
    };
  else if (attempt)
    control = {
      type: "button",
      label: m.settings_telegram_cancel_connect(),
      disabled: busy,
      onPress: () => ask("imessage.cancel"),
    };
  else if (link)
    control = {
      type: "menu",
      label: m.settings_telegram_manage(),
      disabled: busy,
      items: [
        {
          id: "disconnect",
          label: m.settings_telegram_disconnect(),
          tone: "destructive",
          onPress: () => ask("imessage.disconnect"),
        },
        {
          id: "refresh",
          label: m.settings_imessage_refresh(),
          onPress: () => ask("imessage.refresh"),
        },
      ],
    };
  else
    control = {
      type: "button",
      label: m.settings_telegram_connect(),
      disabled: busy || !workspaceId || showForm,
      onPress: () => {
        setStartError(undefined);
        setEntering(true);
      },
    };

  let status: NonNullable<SettingsPanelItem["integration"]>["status"];
  if (loadError || actionFailed || expired || (link && !state.connection_active))
    status = { label: m.settings_telegram_needs_attention(), color: "warning" };
  else if (attempt) status = { label: m.settings_telegram_pending(), color: "blue" };
  else if (link) status = { label: m.settings_telegram_connected(), color: "success" };
  else status = { label: m.settings_telegram_disconnected(), color: "gray" };

  let content;
  if (attempt)
    content = (
      <IMessageCodePanel
        busy={busy}
        code={attempt.code}
        line={attempt.line_handle!}
        onChangeNumber={changeNumber}
        onNewCode={() => start(attempt.sender_handle!)}
        phone={attempt.sender_handle!}
        remainingMs={remainingMs}
      />
    );
  else if (showForm)
    content = (
      <IMessageAccountForm
        busy={busy}
        error={startError}
        initial={link?.sender_handle ?? ""}
        onCancel={() => {
          setStartError(undefined);
          setEntering(false);
        }}
        onSubmit={start}
      />
    );

  return {
    id: "imessage.connection",
    title: m.settings_imessage(),
    icon: <IMessageProviderLogo />,
    ...(description ? { description } : {}),
    descriptionLoading: false,
    control,
    keywords: ["iMessage", "Messages", "信息", m.settings_imessage_get_code()],
    integration: {
      status,
      content,
      details: link
        ? [{ label: m.settings_imessage_account(), value: link.sender_handle }]
        : [],
      note: m.settings_imessage_photon_scope(),
    },
  };
}
