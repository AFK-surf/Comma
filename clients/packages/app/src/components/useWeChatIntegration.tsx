import { useState } from "react";
import { QRCodeCanvas } from "qrcode.react";
import { Button } from "@comma/ui/components/Button";
import { WeChatProviderLogo } from "@comma/ui/components/provider-brand-logos";
import { InputField } from "@comma/ui/components/input";
import {
  type SettingsPanelItem,
  type SettingsControl,
} from "@comma/ui/components/settings-panel";
import { useCommaMessages } from "@comma/i18n/react";
import { useCall, useTopic } from "@comma/core-client";

/** Settings › Channels › WeChat: the core reads and checks the connection; this shows it and asks for changes. */
export function useWeChatIntegration(
  workspaceId: string | undefined,
  active: boolean
): SettingsPanelItem {
  const m = useCommaMessages();
  const call = useCall();
  const { value } = useTopic(
    active && workspaceId ? { topic: "wechat", workspace: workspaceId } : null
  );
  const state = value?.state ?? undefined;
  const error = value?.error ?? false;
  const busy = value?.busy ?? false;
  const [code, setCode] = useState("");
  const pending = state?.pending;
  const connection = state?.connection;
  const attempt =
    pending ?? (connection?.status === "prepared" ? connection : undefined);
  const loginStatus = attempt?.login_status;
  const attemptStatus = attempt?.status;

  const ask = (
    name: "wechat.refresh" | "wechat.start" | "wechat.cancel" | "wechat.disconnect",
    clearCode = false
  ) => {
    if (busy || !workspaceId) return;
    void call(name, { workspace: workspaceId }).then(
      () => {
        if (clearCode) setCode("");
      },
      // The core says it failed (`error`) and offers Refresh.
      () => undefined
    );
  };
  const refresh = () => ask("wechat.refresh");
  const start = () => ask("wechat.start", true);
  const cancel = () => ask("wechat.cancel", true);
  const disconnect = () => ask("wechat.disconnect");
  const verify = () => {
    if (busy || !workspaceId) return;
    void call("wechat.verify", { workspace: workspaceId, code }).then(
      () => setCode(""),
      () => undefined
    );
  };

  const terminal =
    loginStatus &&
    ["expired", "verify_code_blocked", "binded_redirect"].includes(loginStatus);
  // The subtitle reports only trouble or progress.
  let description: string | undefined;
  if (error) description = m.settings_wechat_failed();
  else if (!state) description = m.settings_telegram_loading();
  else if (loginStatus === "need_verifycode")
    description = m.settings_wechat_verify_hint();
  else if (loginStatus === "binded_redirect")
    description = m.settings_wechat_already_bound();
  else if (terminal) description = m.settings_wechat_expired();
  else if (attemptStatus === "prepared")
    description = m.settings_telegram_repair_required();
  else if (attempt) description = m.settings_wechat_waiting();
  else if (connection && !connection.connection_active)
    description = m.settings_telegram_repair_required();

  let control: SettingsControl;
  if (pending)
    control = {
      type: "button",
      label: m.settings_telegram_cancel_connect(),
      disabled: busy,
      onPress: cancel,
    };
  else if (connection)
    control = {
      type: "menu",
      label: m.settings_telegram_manage(),
      disabled: busy,
      items: [
        { id: "reconnect", label: m.settings_telegram_reconnect(), onPress: start },
        {
          id: "disconnect",
          label: m.settings_telegram_disconnect(),
          tone: "destructive",
          onPress: disconnect,
        },
        { id: "refresh", label: m.settings_imessage_refresh(), onPress: refresh },
      ],
    };
  else
    control = {
      type: "button",
      label: error ? m.settings_imessage_refresh() : m.settings_telegram_connect(),
      disabled: busy || !workspaceId || (!error && !state),
      onPress: error ? refresh : start,
    };

  let status: NonNullable<SettingsPanelItem["integration"]>["status"];
  if (error || terminal || (connection && !connection.connection_active && !attempt)) {
    status = { label: m.settings_telegram_needs_attention(), color: "warning" };
  } else if (attempt) {
    status = { label: m.settings_telegram_pending(), color: "blue" };
  } else if (connection?.connection_active) {
    status = { label: m.settings_telegram_connected(), color: "success" };
  } else {
    status = { label: m.settings_telegram_disconnected(), color: "gray" };
  }

  return {
    id: "wechat.connection",
    title: m.settings_wechat(),
    icon: <WeChatProviderLogo />,
    ...(description ? { description } : {}),
    descriptionLoading: !error && !state,
    control,
    keywords: ["WeChat", "微信", "ClawBot"],
    integration: {
      status,
      content: attempt ? (
        <div className="flex flex-wrap items-center gap-xl">
          {!terminal && attempt.qrcode_url ? (
            // The code's quiet zone reads as a tile, so its edge, not the
            // modules inside it, lines up with the text above.
            <figure
              aria-label={m.settings_wechat_qr_label()}
              className="m-0 shrink-0 overflow-hidden rounded-lg border-[0.5px] border-primary"
            >
              <QRCodeCanvas
                value={attempt.qrcode_url}
                size={192}
                marginSize={4}
                level="M"
                className="block"
              />
            </figure>
          ) : null}
          <div className="min-w-0 flex-1 basis-48 space-y-md">
            <p className="text-sm leading-5 text-tertiary">
              {m.settings_wechat_scan()}
            </p>
            <p className="text-xs leading-5 text-quaternary">
              {m.settings_wechat_expiry()}
            </p>
            {loginStatus === "need_verifycode" ? (
              <div className="space-y-md">
                <InputField
                  label={m.settings_wechat_verify_code()}
                  inputMode="numeric"
                  autoComplete="one-time-code"
                  value={code}
                  maxLength={16}
                  onChange={(event) => setCode(event.target.value.replace(/\D/g, ""))}
                  disabled={busy}
                />
                <Button
                  hierarchy="secondary-gray"
                  size="sm"
                  disabled={busy || !code}
                  onPress={verify}
                >
                  {m.settings_wechat_verify()}
                </Button>
              </div>
            ) : null}
            {terminal ? (
              <Button
                hierarchy="secondary-gray"
                size="sm"
                disabled={busy}
                onPress={start}
              >
                {m.settings_wechat_new_code()}
              </Button>
            ) : null}
            {error || attemptStatus === "prepared" ? (
              <Button
                hierarchy="secondary-gray"
                size="sm"
                disabled={busy}
                onPress={refresh}
              >
                {m.settings_imessage_refresh()}
              </Button>
            ) : null}
          </div>
        </div>
      ) : undefined,
      details: connection?.wechat_id
        ? [{ label: m.settings_wechat_account(), value: connection.wechat_id }]
        : [],
      note: m.settings_wechat_scope(),
    },
  };
}
