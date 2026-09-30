import { createElement, useEffect, useRef, useState } from "react";
import { useCommaMessages } from "@comma/i18n/react";
import type { SettingsControl, SettingsPanelItem } from "@comma/ui";
import type {
  CommaApiClient,
  CommaIMessageClaim,
  CommaIMessageIntegrationState,
} from "../api";
import { IMessageConnectCode } from "./IMessageConnectCode";
import {
  nativePlatformClipboard,
  openNativePlatformExternalUrl,
} from "../runtime-chat/nativePlatformActions";

/** One bounded foreground read loop through claim consumption and activation. */
export function useIMessageIntegration(
  api: CommaApiClient,
  workspaceId: string | undefined,
  active: boolean
): SettingsPanelItem {
  const m = useCommaMessages();
  const [state, setState] = useState<CommaIMessageIntegrationState>();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(false);
  const [revision, setRevision] = useState(0);
  const attempt = useRef<
    | {
        claim: CommaIMessageClaim;
        previousConnectionId: string | undefined;
      }
    | undefined
  >(undefined);
  const action = useRef<AbortController | undefined>(undefined);

  useEffect(() => {
    attempt.current = undefined;
    setState(undefined);
    setError(false);
    setBusy(false);
    return () => {
      action.current?.abort();
      action.current = undefined;
    };
  }, [workspaceId, active]);

  useEffect(() => {
    if (!active || !workspaceId) return;
    const controller = new AbortController();
    let timer: ReturnType<typeof setTimeout> | undefined;
    let reads = 0;
    const read = async () => {
      try {
        const next = await api.getIMessageIntegration(workspaceId, {
          signal: controller.signal,
        });
        if (controller.signal.aborted) return;
        if (
          next.pending_claim &&
          attempt.current?.claim.code !== next.pending_claim.code
        ) {
          attempt.current = {
            claim: next.pending_claim,
            previousConnectionId: next.link?.connection_id,
          };
        }
        if (
          !next.pending_claim &&
          next.connection_active &&
          next.link &&
          next.link.connection_id !== attempt.current?.previousConnectionId
        ) {
          attempt.current = undefined;
        }
        reads += 1;
        const expired =
          !!attempt.current &&
          (attempt.current.claim.expires_at * 1_000 <= Date.now() || reads >= 201);
        if (expired) attempt.current = undefined;
        setState(next);
        setError(expired);
        if (attempt.current) timer = setTimeout(() => void read(), 3_000);
      } catch {
        if (!controller.signal.aborted) setError(true);
      }
    };
    void read();
    return () => {
      controller.abort();
      clearTimeout(timer);
    };
  }, [api, workspaceId, active, revision]);

  const run = async <T>(operation: () => Promise<T>, after?: (result: T) => void) => {
    if (busy || !workspaceId) return;
    const controller = new AbortController();
    action.current?.abort();
    action.current = controller;
    setBusy(true);
    setError(false);
    try {
      const result = await operation();
      if (!controller.signal.aborted) {
        after?.(result);
        setRevision((value) => value + 1);
      }
    } catch {
      if (!controller.signal.aborted) setError(true);
    } finally {
      if (!controller.signal.aborted) setBusy(false);
    }
  };

  const startConnect = () =>
    void run(
      () => api.startIMessageConnect(workspaceId!),
      (claim) => {
        attempt.current = { claim, previousConnectionId: state?.link?.connection_id };
      }
    );
  const clearAttempt = () => {
    attempt.current = undefined;
  };
  const copy = (text: string) => {
    void nativePlatformClipboard.writeText(text).catch(() => setError(true));
  };
  const claim = state?.pending_claim;
  const connectingClaim = claim ?? attempt.current?.claim;
  const link = state?.link;
  const connected = !!link && state?.connection_active;
  let description = m.settings_imessage_description();
  if (error) description = m.settings_imessage_failed();
  else if (!state) description = m.settings_telegram_loading();
  else if (!state.configured) description = m.settings_imessage_unavailable();
  else if (connectingClaim) description = m.settings_imessage_waiting();
  else if (!state.relay_online) description = m.settings_imessage_offline();
  else if (link && !connected) description = m.settings_telegram_repair_required();

  let status: NonNullable<SettingsPanelItem["integration"]>["status"] = {
    label: m.settings_telegram_disconnected(),
    color: "gray",
  };
  if (error || (link && (!connected || !state?.relay_online))) {
    status = { label: m.settings_telegram_needs_attention(), color: "warning" };
  } else if (connectingClaim) {
    status = { label: m.settings_telegram_pending(), color: "blue" };
  } else if (connected) {
    status = { label: m.settings_telegram_connected(), color: "success" };
  }

  let control: SettingsControl;
  if (connectingClaim) {
    control = {
      type: "button",
      label: m.settings_telegram_cancel_connect(),
      disabled: busy,
      onPress: () =>
        void run(
          () => api.cancelIMessageConnect(workspaceId!, connectingClaim.code),
          clearAttempt
        ),
    };
  } else if (link) {
    control = {
      type: "menu",
      label: m.settings_telegram_manage(),
      disabled: busy,
      items: [
        {
          id: "reconnect",
          label: m.settings_telegram_reconnect(),
          onPress: startConnect,
        },
        {
          id: "disconnect",
          label: m.settings_telegram_disconnect(),
          tone: "destructive",
          onPress: () =>
            void run(() => api.disconnectIMessage(workspaceId!), clearAttempt),
        },
        {
          id: "refresh",
          label: m.settings_imessage_refresh(),
          onPress: () => setRevision((value) => value + 1),
        },
      ],
    };
  } else {
    control = {
      type: "button",
      label: error ? m.settings_imessage_refresh() : m.settings_telegram_connect(),
      disabled: busy || !workspaceId || (!error && !state?.configured),
      onPress: () => (error ? setRevision((value) => value + 1) : startConnect()),
    };
  }

  return {
    id: "imessage.connection",
    title: "iMessage",
    description,
    control,
    keywords: ["iMessage", "Messages", "信息"],
    integration: {
      status,
      content:
        claim && state?.shared_handle
          ? createElement(IMessageConnectCode, {
              handle: state.shared_handle,
              code: claim.code,
              onCopy: copy,
              onOpen: (url: string) => {
                void openNativePlatformExternalUrl(url).catch(() => setError(true));
              },
            })
          : undefined,
      details: [
        {
          label: m.settings_imessage_account(),
          value: link?.sender_label || link?.sender_handle || "—",
        },
        {
          label: m.settings_imessage_bot(),
          value: state?.shared_handle || "—",
          ...(state?.shared_handle
            ? { onPress: () => copy(state.shared_handle!) }
            : {}),
        },
      ],
      note:
        connectingClaim || !link
          ? m.settings_imessage_setup()
          : m.settings_imessage_scope(),
    },
  };
}
