import { useEffect, useState } from "react";
import { QRCodeSVG } from "qrcode.react";
import { useCall, useTopic } from "@comma/core-client";
import { useCommaMessages } from "@comma/i18n/react";
import { uiClock } from "@comma/ui/clock";
import { Button } from "@comma/ui/components/Button";
import { ArrowUpRightIcon, CopyIcon } from "@comma/ui/components/icons";
import { LineProviderLogo } from "@comma/ui/components/provider-brand-logos";
import {
  type SettingsControl,
  type SettingsPanelItem,
} from "@comma/ui/components/settings-panel";
import { copyWithFeedback } from "@comma/ui/components/toast";
import {
  nativePlatformClipboard,
  openNativePlatformExternalUrl,
} from "../../nativePlatformActions";
import { formatRemaining } from "../imessage/IMessageSettings";

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

/** The attempt under way: a QR code and a link that open the chat with `link <code>` typed in. */
export function LineCodePanel({
  code,
  messageUrl,
  basicId,
  remainingMs,
}: {
  code: string;
  messageUrl: string;
  basicId: string | undefined;
  remainingMs: number;
}) {
  const m = useCommaMessages();
  const command = `link ${code}`;
  return (
    <section
      aria-label={m.settings_line_code_title()}
      className="flex w-full flex-col gap-md"
      data-testid="line-code"
    >
      <div className="flex flex-col gap-xs">
        <div className="flex flex-wrap items-baseline justify-between gap-x-md">
          <p className="m-0 text-sm font-medium text-primary">
            {m.settings_line_code_title()}
          </p>
          <p className="m-0 text-sm text-tertiary">
            {m.settings_imessage_expires_in({ time: formatRemaining(remainingMs) })}
          </p>
        </div>
        <p className="m-0 text-pretty text-sm leading-5 text-tertiary">
          {m.settings_line_code_steps({ code })}
        </p>
      </div>
      <div className="flex flex-wrap items-center gap-xl">
        <figure
          aria-label={m.settings_line_qr_label()}
          className="m-0 w-fit rounded-md border border-secondary bg-white p-sm"
        >
          <QRCodeSVG aria-hidden marginSize={0} size={112} value={messageUrl} />
        </figure>
        <div className="flex min-w-0 flex-col items-start gap-sm">
          {basicId ? (
            <p className="m-0 text-sm text-tertiary">
              {m.settings_line_manual({ id: basicId })}
            </p>
          ) : null}
          <div className="flex items-center gap-md">
            <span
              className="font-mono text-sm font-medium text-primary [overflow-wrap:anywhere]"
              data-testid="line-command"
            >
              {command}
            </span>
            <Button
              aria-label={m.settings_imessage_copy_code()}
              hierarchy="tertiary-gray"
              iconLeading={<CopyIcon />}
              className="h-6 w-6 p-xs"
              iconOnly
              onPress={() => {
                void copyWithFeedback(
                  () => nativePlatformClipboard.writeText(command),
                  m
                );
              }}
              size="xs"
            />
          </div>
          <Button
            hierarchy="link-color"
            iconTrailing={<ArrowUpRightIcon />}
            onPress={() => {
              void openNativePlatformExternalUrl(messageUrl).catch(() => undefined);
            }}
            className="-ml-[2px] h-auto"
            size="sm"
          >
            {m.settings_line_open()}
          </Button>
        </div>
      </div>
    </section>
  );
}

/**
 * Settings › Channels › LINE over Comma's one LINE Official Account: Connect
 * answers a ten-minute code, and the person sends `link <code>` to the account
 * from LINE (docs/messaging-voice.md). The core reads the state and checks the
 * attempt; this shows it and asks for changes.
 *
 * Shown only when the server says Comma's LINE account is set up.
 */
export function useLineIntegration(
  workspaceId: string | undefined,
  active: boolean
): SettingsPanelItem | null {
  const m = useCommaMessages();
  const call = useCall();
  const { value } = useTopic(
    active && workspaceId ? { topic: "line", workspace: workspaceId } : null
  );
  const state = value?.state ?? undefined;
  const loadError = value?.error ?? false;
  const busy = value?.busy ?? false;
  const [actionFailed, setActionFailed] = useState(false);

  useEffect(() => setActionFailed(false), [active, workspaceId]);

  const attempt = state?.pending_claim ?? undefined;
  const link = state?.link;
  const now = useSecondTick(Boolean(attempt));
  const remainingMs = attempt ? attempt.expires_at * 1000 - now : 0;
  const expired = Boolean(attempt) && remainingMs <= 0;

  if (!state?.configured && !loadError) return null;
  // A read failed before LINE was known: say nothing about a channel that may not exist.
  if (loadError && !state) return null;

  const ask = (
    name: "line.refresh" | "line.start" | "line.cancel" | "line.disconnect"
  ) => {
    if (busy || !workspaceId) return;
    setActionFailed(false);
    void call(name, { workspace: workspaceId }).catch(() => setActionFailed(true));
  };

  // The subtitle reports only trouble or progress.
  let description: string | undefined;
  if (loadError || actionFailed) description = m.settings_line_failed();
  else if (expired) description = m.settings_imessage_code_expired();
  else if (attempt) description = m.settings_imessage_waiting_reply();
  else if (link && !state.connection_active)
    description = m.settings_telegram_repair_required();
  else if (!link) description = m.settings_line_description();

  let control: SettingsControl;
  if (loadError)
    control = {
      type: "button",
      label: m.settings_imessage_refresh(),
      disabled: busy || !workspaceId,
      onPress: () => ask("line.refresh"),
    };
  else if (attempt && expired)
    control = {
      type: "button",
      label: m.settings_imessage_new_code(),
      disabled: busy,
      onPress: () => ask("line.start"),
    };
  else if (attempt)
    control = {
      type: "button",
      label: m.settings_telegram_cancel_connect(),
      disabled: busy,
      tone: "quiet",
      onPress: () => ask("line.cancel"),
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
          onPress: () => ask("line.disconnect"),
        },
        {
          id: "reconnect",
          label: m.settings_telegram_reconnect(),
          onPress: () => ask("line.start"),
        },
      ],
    };
  else
    control = {
      type: "button",
      label: m.settings_telegram_connect(),
      disabled: busy || !workspaceId,
      onPress: () => ask("line.start"),
    };

  let status: NonNullable<SettingsPanelItem["integration"]>["status"];
  if (loadError || actionFailed || expired || (link && !state.connection_active))
    status = { label: m.settings_telegram_needs_attention(), color: "warning" };
  else if (attempt) status = { label: m.settings_telegram_pending(), color: "blue" };
  else if (link) status = { label: m.settings_telegram_connected(), color: "success" };
  else status = { label: m.settings_telegram_disconnected(), color: "gray" };

  const content =
    attempt && !expired ? (
      <LineCodePanel
        basicId={state?.basic_id ?? undefined}
        code={attempt.code}
        messageUrl={attempt.message_url}
        remainingMs={remainingMs}
      />
    ) : undefined;

  return {
    id: "line.connection",
    title: m.settings_line(),
    icon: <LineProviderLogo />,
    ...(description ? { description } : {}),
    descriptionLoading: false,
    control,
    keywords: ["LINE"],
    integration: {
      status,
      ...(content ? { content } : {}),
      details: link
        ? [
            {
              label: m.settings_line_account(),
              value: link.line_display_name || link.line_user_id,
            },
          ]
        : [],
      ...(attempt && !expired ? {} : { note: m.settings_line_scope() }),
    },
  };
}
