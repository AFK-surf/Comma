import { useCallback, useEffect, useRef, useState } from "react";
import { QRCodeCanvas } from "qrcode.react";
import {
  Button,
  WeChatProviderLogo,
  InputField,
  type SettingsPanelItem,
  type SettingsControl,
} from "@comma/ui";
import { useCommaMessages } from "@comma/i18n/react";
import type {
  CommaApiClient,
  CommaWeChatConnection,
  CommaWeChatIntegrationState,
} from "../api";

const stopped = new Set([
  "need_verifycode",
  "expired",
  "verify_code_blocked",
  "binded_redirect",
]);

export function useWeChatIntegration(
  api: CommaApiClient,
  workspaceId: string | undefined,
  active: boolean
): SettingsPanelItem {
  const m = useCommaMessages();
  const [state, setState] = useState<CommaWeChatIntegrationState>();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(false);
  const [code, setCode] = useState("");
  const action = useRef<AbortController | undefined>(undefined);
  const pending = state?.pending;
  const connection = state?.connection;
  const attempt =
    pending ?? (connection?.status === "prepared" ? connection : undefined);
  const attemptId = attempt?.connect_id;
  const expiresAt = attempt?.expires_at;
  const loginStatus = attempt?.login_status;
  const attemptStatus = attempt?.status;

  useEffect(() => {
    setState(undefined);
    setError(false);
    setBusy(false);
    setCode("");
    const controller = new AbortController();
    if (active && workspaceId) {
      void api.getWeChatIntegration(workspaceId, { signal: controller.signal }).then(
        (next) => {
          if (!controller.signal.aborted) setState(next);
        },
        () => {
          if (!controller.signal.aborted) setError(true);
        }
      );
    }
    return () => {
      controller.abort();
      action.current?.abort();
    };
  }, [api, workspaceId, active]);

  const accept = useCallback((record: CommaWeChatConnection) => {
    setState((current) =>
      record.connection_active
        ? { connection: record, pending: null }
        : { connection: current?.connection ?? null, pending: record }
    );
  }, []);

  const canPoll =
    active &&
    !busy &&
    !error &&
    attemptStatus === "pending" &&
    !stopped.has(loginStatus ?? "");

  // One visible attempt per Workspace. Status updates do not reset the
  // three-second pause between requests. Leaving Settings aborts the poll.
  useEffect(() => {
    if (!canPoll || !workspaceId || !attemptId || !expiresAt) return;
    const controller = new AbortController();
    let timer: ReturnType<typeof setTimeout> | undefined;
    const poll = async () => {
      if (Date.now() >= expiresAt * 1000) {
        setState((current) =>
          current?.pending?.connect_id === attemptId
            ? { ...current, pending: { ...current.pending, login_status: "expired" } }
            : current
        );
        return;
      }
      try {
        const next = await api.pollWeChatConnect(workspaceId, attemptId, undefined, {
          signal: controller.signal,
        });
        if (controller.signal.aborted) return;
        accept(next);
        if (!next.connection_active && !stopped.has(next.login_status))
          timer = setTimeout(() => void poll(), 3000);
      } catch {
        if (!controller.signal.aborted) setError(true);
      }
    };
    void poll();
    return () => {
      controller.abort();
      clearTimeout(timer);
    };
  }, [api, workspaceId, attemptId, expiresAt, canPoll, accept]);
  const run = async (operation: (signal: AbortSignal) => Promise<void>) => {
    if (busy || !workspaceId) return;
    const controller = new AbortController();
    action.current?.abort();
    action.current = controller;
    setBusy(true);
    setError(false);
    try {
      await operation(controller.signal);
    } catch {
      if (!controller.signal.aborted) setError(true);
    } finally {
      if (!controller.signal.aborted) setBusy(false);
    }
  };
  const refresh = () =>
    void run(async (signal) => {
      const next = await api.getWeChatIntegration(workspaceId!, { signal });
      if (signal.aborted) return;
      setState(next);
      const repair = [next.pending, next.connection].find(
        (record) => record?.status === "prepared"
      );
      if (repair && !signal.aborted) {
        const recovered = await api.pollWeChatConnect(
          workspaceId!,
          repair.connect_id,
          undefined,
          { signal }
        );
        if (!signal.aborted) accept(recovered);
      }
    });
  const start = () =>
    void run(async (signal) => {
      const next = await api.startWeChatConnect(workspaceId!, { signal });
      if (!signal.aborted) {
        setCode("");
        accept(next);
      }
    });
  const cancel = () =>
    void run(async (signal) => {
      await api.cancelWeChatConnect(workspaceId!, pending!.connect_id, { signal });
      const next = await api.getWeChatIntegration(workspaceId!, { signal });
      if (!signal.aborted) {
        setCode("");
        setState(next);
      }
    });
  const disconnect = () =>
    void run(async (signal) => {
      await api.disconnectWeChat(workspaceId!, { signal });
      if (!signal.aborted) setState({ connection: null, pending: null });
    });
  const verify = () =>
    void run(async (signal) => {
      const next = await api.pollWeChatConnect(workspaceId!, attemptId!, code, {
        signal,
      });
      if (!signal.aborted) {
        setCode("");
        accept(next);
      }
    });

  const terminal =
    loginStatus &&
    ["expired", "verify_code_blocked", "binded_redirect"].includes(loginStatus);
  let description = m.settings_wechat_description();
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
    description,
    descriptionLoading: !error && !state,
    control,
    keywords: ["WeChat", "微信", "ClawBot"],
    integration: {
      status,
      content: attempt ? (
        <div className="flex flex-wrap items-center gap-xl">
          {!terminal && attempt.qrcode_url ? (
            <figure aria-label={m.settings_wechat_qr_label()} className="m-0 shrink-0">
              <QRCodeCanvas
                value={attempt.qrcode_url}
                size={192}
                marginSize={4}
                level="M"
                className="rounded-lg"
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
