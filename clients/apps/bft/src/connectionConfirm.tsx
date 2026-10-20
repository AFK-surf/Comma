import { Dialog } from "@comma/ui/components/dialog";
import { InputField } from "@comma/ui/components/input";
import { useState } from "react";
import type { BftConnectionStart } from "./api";
import { DialogError, writeErrorMessage } from "./dialogs";
import { humanize } from "./format";
import { messages } from "./messages";
import { TextField } from "./settingsForm";

/*
 * The confirmation before an account credential is connected, authorized
 * again or disconnected: what the credential is, which MCP servers depend on
 * it, and what happens next. Plugin credentials and the Agent Swarm
 * Connections page (OAuth accounts and Composio toolkits) use it.
 */

const t = messages.connections;

export type ConnectionAction = "connect" | "reconnect" | "disconnect";

export interface ConnectionRequest {
  label: string;
  /** `managed_oauth`, `native_mcp_oauth` or `composio`. */
  kind: string;
  action: ConnectionAction;
  dependentMcps: readonly string[];
  /** A connect of a credential that is already connected configures its MCP servers. */
  credentialConnected: boolean;
  /** An optional name the reader may give the account; `run` receives it. */
  input?: { label: string; placeholder: string };
  credential?: { label: string; helpUrl: string } | undefined;
  /** The write: a provider address to open, or a notice when nothing is left to do. */
  run: (input: string) => Promise<BftConnectionStart>;
}

type Tone = "ok" | "warn" | "error" | "neutral";

const stateTones: Record<string, Tone> = {
  connected: "ok",
  ready_on_use: "ok",
  running: "ok",
  missing_scopes: "warn",
  reauthorization_required: "warn",
  authorization_pending: "warn",
  waiting_for_oauth: "warn",
  waiting_for_credentials: "warn",
  degraded: "warn",
  conflict: "error",
};

export const connectionKindLabel = (kind: string) => t.kinds[kind] ?? humanize(kind);

/** A credential's or MCP server's setup state, with its status dot. */
export function ConnectionState({ state }: { state: string | null }) {
  const value = state ?? "unavailable";
  return (
    <span className="bft-status" data-tone={stateTones[value] ?? "neutral"}>
      <span className="bft-truncate">{t.states[value] ?? t.states.unavailable}</span>
    </span>
  );
}

/** Opens the absolute provider address the server returned; anything but http(s) is refused. */
export function openProvider(
  href: string,
  assign = (url: string) => window.location.assign(url)
) {
  let url: URL;
  try {
    url = new URL(href);
  } catch {
    return false;
  }
  if (url.protocol !== "https:" && url.protocol !== "http:") return false;
  assign(url.toString());
  return true;
}

/**
 * Asks before a credential write; render `dialog`. A provider address takes
 * the browser there; a notice goes to `onNotice`.
 */
export function useConnectionConfirm(onNotice: (notice: string) => void) {
  const [pending, setPending] = useState<ConnectionRequest | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string>();

  const close = () => {
    if (busy) return;
    setPending(null);
    setError(undefined);
  };

  const confirm = (request: ConnectionRequest, input: string) => {
    setBusy(true);
    setError(undefined);
    request.run(input.trim()).then(
      (result) => {
        if ("redirect_url" in result) {
          // The page stays busy while the browser leaves for the provider.
          if (!openProvider(result.redirect_url)) {
            setBusy(false);
            setError(messages.common.writeFailed);
          }
          return;
        }
        setBusy(false);
        setPending(null);
        onNotice(result.notice);
      },
      (caught: unknown) => {
        setBusy(false);
        setError(writeErrorMessage(caught));
      }
    );
  };

  const dialog = pending ? (
    <ConnectionDialog
      busy={busy}
      error={error}
      onClose={close}
      onConfirm={(input) => confirm(pending, input)}
      request={pending}
    />
  ) : null;

  return { ask: setPending, dialog };
}

function ConnectionDialog({
  request,
  busy,
  error,
  onConfirm,
  onClose,
}: {
  request: ConnectionRequest;
  busy: boolean;
  error: string | undefined;
  onConfirm: (input: string) => void;
  onClose: () => void;
}) {
  const [input, setInput] = useState("");
  const { action, kind } = request;
  const disconnect = action === "disconnect";
  const body = disconnect ? t.disconnectBody : t.kindBodies[kind];
  const footnote =
    disconnect ||
    request.credential ||
    (action === "connect" && request.credentialConnected)
      ? undefined
      : action === "reconnect"
        ? t.reconnectNote
        : t.connectNote;

  return (
    <Dialog
      actions={[
        {
          label: messages.common.cancel,
          hierarchy: "secondary-gray",
          onPress: onClose,
          disabled: busy,
        },
        {
          label: busy
            ? disconnect
              ? t.disconnecting
              : t.connecting
            : disconnect
              ? t.disconnect
              : request.credential
                ? t.saveToken
                : t.continue,
          hierarchy: disconnect ? "destructive" : "primary",
          onPress: () => onConfirm(input),
          disabled: busy || (!!request.credential && !/^[^\s]+$/.test(input.trim())),
        },
      ]}
      description={connectionKindLabel(kind)}
      isDismissable={!busy}
      isOpen
      onOpenChange={(open) => {
        if (!open) onClose();
      }}
      title={request.label}
    >
      <div className="bft-form">
        {body ? <p className="bft-dialog-note">{body}</p> : null}
        {request.credential ? (
          <>
            <InputField
              autoComplete="new-password"
              className="w-full ph-no-capture"
              fieldSize="sm"
              disabled={busy}
              label={request.credential.label}
              onChange={(event) => setInput(event.target.value)}
              type="password"
              maxLength={4096}
              value={input}
            />
            <p className="bft-dialog-note bft-muted">{t.tokenNote}</p>
            <a
              className="bft-link"
              href={request.credential.helpUrl}
              target="_blank"
              rel="noopener noreferrer"
            >
              {t.tokenHelp}
            </a>
          </>
        ) : null}
        {request.input ? (
          <TextField
            disabled={busy}
            label={request.input.label}
            onChange={setInput}
            placeholder={request.input.placeholder}
            value={input}
          />
        ) : null}
        {request.dependentMcps.length > 0 ? (
          <p className="bft-dialog-note">
            {t.dependentMcps(request.dependentMcps.join(", "))}
          </p>
        ) : null}
        {footnote ? <p className="bft-dialog-note bft-muted">{footnote}</p> : null}
        <DialogError message={error} />
      </div>
    </Dialog>
  );
}
