import { useCallback, useEffect, useRef, useState, type ReactNode } from "react";
import type { CommaLocale } from "@comma/i18n";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import {
  Button,
  SignalProviderLogo,
  type SettingsControl,
  type SettingsPanelItem,
} from "@comma/ui";
import {
  CommaApiError,
  type CommaApiClient,
  type CommaSignalIntegration,
  type CommaSignalNumber,
} from "../../api";
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
  const code = error instanceof CommaApiError ? error.body?.error : undefined;
  if (code === "signal_account_not_found") return m.settings_signal_number_not_found();
  if (code === "signal_account_scope") return m.settings_signal_number_scope();
  if (code === "signal_account_inactive") return m.settings_signal_number_inactive();
  return m.settings_signal_save_failed();
}

/** One-time connection code: its message lives only in this hook's state. */
interface CreatedCode {
  claimId: string;
  command: string;
  number: string;
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
  children: ReactNode;
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
  api: CommaApiClient,
  workspaceId: string | undefined,
  active: boolean
): { item: SettingsPanelItem; overlay: ReactNode } {
  const m = useCommaMessages();
  const locale = useCommaLocale();
  const [integration, setIntegration] = useState<CommaSignalIntegration>();
  const [number, setNumber] = useState<CommaSignalNumber>();
  const [loadError, setLoadError] = useState(false);
  const [saveError, setSaveError] = useState(false);
  const [busy, setBusy] = useState(false);
  const [created, setCreated] = useState<CreatedCode>();
  const [dialog, setDialog] = useState<SignalDialogState>();
  const [dialogError, setDialogError] = useState<string>();
  const action = useRef<AbortController | undefined>(undefined);

  const load = useCallback(
    async (signal: AbortSignal) => {
      if (!workspaceId) return;
      try {
        const [status, own] = await Promise.all([
          api.getSignalIntegration(workspaceId, { signal }),
          api.getSignalNumber(workspaceId, { signal }),
        ]);
        if (signal.aborted) return;
        setIntegration(status);
        setNumber(own);
        setLoadError(false);
      } catch {
        if (!signal.aborted) setLoadError(true);
      }
    },
    [api, workspaceId]
  );

  useEffect(() => {
    setIntegration(undefined);
    setNumber(undefined);
    setLoadError(false);
    setSaveError(false);
    setBusy(false);
    setCreated(undefined);
    setDialog(undefined);
    setDialogError(undefined);
    const controller = new AbortController();
    if (active && workspaceId) void load(controller.signal);
    return () => {
      controller.abort();
      action.current?.abort();
    };
  }, [active, workspaceId, load]);

  // While a code is unused, check every three seconds whether its chat has
  // connected. One open Settings view makes at most one request at a time,
  // and the server drops a code after ten minutes, which ends the polling.
  const waiting =
    active &&
    Boolean(workspaceId) &&
    !loadError &&
    (integration?.pending_claims.length ?? 0) > 0;
  useEffect(() => {
    if (!waiting || !workspaceId) return;
    const controller = new AbortController();
    let timer: ReturnType<typeof setTimeout> | undefined;
    const poll = async () => {
      try {
        const next = await api.getSignalIntegration(workspaceId, {
          signal: controller.signal,
        });
        if (controller.signal.aborted) return;
        setIntegration(next);
        if (next.pending_claims.length > 0) timer = setTimeout(() => void poll(), 3000);
      } catch {
        if (!controller.signal.aborted) setLoadError(true);
      }
    };
    timer = setTimeout(() => void poll(), 3000);
    return () => {
      controller.abort();
      clearTimeout(timer);
    };
  }, [api, workspaceId, waiting]);

  const openDialog = useCallback((next: SignalDialogState | undefined) => {
    setDialogError(undefined);
    setDialog(next);
  }, []);

  const write = (
    run: (workspace: string, signal: AbortSignal) => Promise<void>,
    inDialog: boolean
  ) => {
    if (busy || !workspaceId) return;
    const controller = new AbortController();
    action.current?.abort();
    action.current = controller;
    setBusy(true);
    setSaveError(false);
    setDialogError(undefined);
    void (async () => {
      try {
        await run(workspaceId, controller.signal);
        if (inDialog && !controller.signal.aborted) openDialog(undefined);
      } catch (error) {
        if (controller.signal.aborted) return;
        if (inDialog) setDialogError(numberErrorMessage(error, m));
        else setSaveError(true);
      } finally {
        if (!controller.signal.aborted) setBusy(false);
      }
    })();
  };

  const refresh = () => {
    setLoadError(false);
    write((_workspace, signal) => load(signal), false);
  };
  const newCode = () =>
    write(async (workspace, signal) => {
      const next = await api.startSignalClaim(workspace, { signal });
      if (signal.aborted) return;
      setIntegration(next);
      if (next.claim)
        setCreated({
          claimId: next.claim.claim_id,
          command: next.claim.command,
          number: next.claim.number ?? "",
        });
    }, false);
  const cancelCode = (claimId: string) =>
    write(async (workspace, signal) => {
      const next = await api.cancelSignalClaim(workspace, claimId, { signal });
      if (!signal.aborted) setIntegration(next);
    }, false);
  const saveNumber = (value: string, inDialog: boolean) =>
    write(async (workspace, signal) => {
      const own = await api.setSignalNumber(workspace, value, { signal });
      const status = await api.getSignalIntegration(workspace, { signal });
      if (signal.aborted) return;
      setNumber(own);
      setIntegration(status);
    }, inDialog);
  const disconnect = (bindingId: string) =>
    write(async (workspace, signal) => {
      const next = await api.removeSignalBinding(workspace, bindingId, { signal });
      if (!signal.aborted) setIntegration(next);
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

  let description = m.settings_signal_description();
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
        >
          {own ? (
            <Button
              disabled={busy}
              hierarchy="tertiary-gray"
              onPress={() => saveNumber("", false)}
              size="sm"
            >
              {m.settings_signal_use_platform()}
            </Button>
          ) : null}
          <Button
            disabled={busy}
            hierarchy="secondary-gray"
            onPress={() => openDialog({ kind: "number", current: own ?? "" })}
            size="sm"
          >
            {m.settings_signal_change_number()}
          </Button>
        </Row>
      </ul>
    </div>
  ) : undefined;

  return {
    item: {
      id: "signal.connection",
      title: m.settings_signal(),
      icon: <SignalProviderLogo />,
      description,
      descriptionLoading: !loadError && Boolean(workspaceId) && !loaded,
      control,
      keywords: [
        "Signal",
        "信号",
        m.settings_signal_new_code(),
        m.settings_signal_change_number(),
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
