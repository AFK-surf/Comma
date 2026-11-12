import { Button } from "@comma/ui/components/Button";
import { Checkbox } from "@comma/ui/components/checkbox";
import { Dialog } from "@comma/ui/components/dialog";
import { InputField } from "@comma/ui/components/input";
import { useState } from "react";
import type { BftConnectionStart, BftSecretField } from "./api";
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
  /** `managed_oauth`, `native_mcp_oauth`, `composio` or `secret`. */
  kind: string;
  action: ConnectionAction;
  dependentMcps: readonly string[];
  /** A connect of a credential that is already connected configures its MCP servers. */
  credentialConnected: boolean;
  /**
   * A name the reader gives the account (optional unless `required`); `run` receives it. `note` may say something
   * about the typed name in place of `hint`, without blocking the write.
   */
  input?: {
    label: string;
    placeholder: string;
    hint?: string;
    required?: boolean;
    note?: (name: string) => string | undefined;
  };
  credential?: { label: string; helpUrl: string } | undefined;
  /** A secret: the reader may name several values instead of one; `run` receives them. */
  fields?: boolean;
  /** The write: a provider address to open, or a notice when nothing is left to do. */
  run: (
    input: string,
    fields: readonly BftSecretField[]
  ) => Promise<BftConnectionStart>;
}

const maxFields = 8;
const reservedFields = ["access_token", "client_id"];

/** Why a secret's field name cannot be saved, or nothing; an empty name only blocks saving. */
export function secretFieldError(name: string, earlier: readonly string[]) {
  const value = name.trim();
  if (value === "") return undefined;
  if (!/^[A-Za-z][A-Za-z0-9_]*$/.test(value)) return t.fieldNameChars;
  if (value.length > 32) return t.fieldNameLong;
  if (reservedFields.includes(value.toLowerCase())) return t.fieldNameReserved;
  if (earlier.some((other) => other.trim().toLowerCase() === value.toLowerCase()))
    return t.fieldNameTaken;
  return undefined;
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

  const confirm = (
    request: ConnectionRequest,
    input: string,
    fields: readonly BftSecretField[]
  ) => {
    setBusy(true);
    setError(undefined);
    request.run(input.trim(), fields).then(
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
      onConfirm={(input, fields) => confirm(pending, input, fields)}
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
  onConfirm: (input: string, fields: readonly BftSecretField[]) => void;
  onClose: () => void;
}) {
  const [input, setInput] = useState("");
  const [fields, setFields] = useState<readonly FieldRow[]>([]);
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
        : (t.kindConnectNotes[kind] ?? t.connectNote);
  const inputHint = request.input?.note?.(input.trim()) ?? request.input?.hint;
  const missing =
    (!!request.credential && !/^[^\s]+$/.test(input.trim())) ||
    (!!request.input?.required && input.trim() === "") ||
    fields.some(
      (field, index) =>
        field.name.trim() === "" ||
        !!secretFieldError(
          field.name,
          fields.slice(0, index).map((other) => other.name)
        )
    );

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
          onPress: () =>
            onConfirm(
              input,
              fields.map((field) => ({ name: field.name.trim(), secret: field.secret }))
            ),
          disabled: busy || missing,
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
            {...(inputHint ? { hint: inputHint } : {})}
          />
        ) : null}
        {request.fields ? (
          <SecretFields busy={busy} fields={fields} onChange={setFields} />
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

interface FieldRow {
  id: number;
  name: string;
  secret: boolean;
}

/**
 * The values a secret holds: one by default, or a list of named fields, each
 * secret unless the reader says it may be shown.
 */
function SecretFields({
  fields,
  onChange,
  busy,
}: {
  fields: readonly FieldRow[];
  onChange: (fields: readonly FieldRow[]) => void;
  busy: boolean;
}) {
  const change = (id: number, update: Partial<FieldRow>) =>
    onChange(
      fields.map((field) => (field.id === id ? { ...field, ...update } : field))
    );
  const add = () =>
    onChange([
      ...fields,
      {
        id: Math.max(0, ...fields.map((field) => field.id)) + 1,
        name: "",
        secret: true,
      },
    ]);

  return (
    <div className="bft-secret-fields">
      <p className="bft-dialog-note">
        {fields.length === 0 ? t.secretFieldsNote : t.secretFieldsListNote}
      </p>
      {fields.length > 0 ? (
        <ul aria-label={t.fieldsTitle} className="bft-list bft-setting-rows">
          {fields.map((field, index) => {
            const label = t.fieldName(index + 1);
            const error = secretFieldError(
              field.name,
              fields.slice(0, index).map((other) => other.name)
            );
            return (
              <li className="bft-setting-row bft-secret-field" key={field.id}>
                <span className="bft-setting-row-main">
                  <InputField
                    aria-label={label}
                    autoComplete="off"
                    className="w-full"
                    disabled={busy}
                    fieldSize="sm"
                    maxLength={64}
                    onChange={(event) => change(field.id, { name: event.target.value })}
                    placeholder={t.fieldPlaceholder}
                    value={field.name}
                    wrapperClassName="bft-form-field"
                    {...(error ? { errorMessage: error } : {})}
                  />
                </span>
                <Checkbox
                  checked={field.secret}
                  disabled={busy}
                  label={t.fieldSecret}
                  onChange={(event) =>
                    change(field.id, { secret: event.target.checked })
                  }
                  size="sm"
                />
                <Button
                  aria-label={
                    field.name.trim()
                      ? t.removeFieldFor(field.name.trim())
                      : t.removeFieldNumber(index + 1)
                  }
                  hierarchy="tertiary-gray"
                  isDisabled={busy}
                  onPress={() =>
                    onChange(fields.filter((other) => other.id !== field.id))
                  }
                  size="xs"
                >
                  {t.removeField}
                </Button>
              </li>
            );
          })}
        </ul>
      ) : null}
      {fields.length < maxFields ? (
        <Button hierarchy="tertiary-gray" isDisabled={busy} onPress={add} size="xs">
          {t.addField}
        </Button>
      ) : (
        <p className="bft-dialog-note bft-muted">{t.fieldsMax}</p>
      )}
    </div>
  );
}
