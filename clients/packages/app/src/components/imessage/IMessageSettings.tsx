import { copyWithFeedback } from "@comma/ui/components/toast";
import { useCommaMessages } from "@comma/i18n/react";
import { Button } from "@comma/ui/components/Button";
import { ArrowUpRightIcon, CopyIcon } from "@comma/ui/components/icons";
import { InputField } from "@comma/ui/components/input";
import { QRCodeSVG } from "qrcode.react";
import { useState } from "react";
import {
  nativePlatformClipboard,
  openNativePlatformExternalUrl,
} from "../../nativePlatformActions";

const E164 = /^\+[1-9]\d{6,14}$/;
const EMAIL = /^[^\s@]+@[^\s@]+\.[a-z]{2,}$/;

/** Match the server's handle normalization without removing punctuation from email. */
function normalizeHandle(value: string): string {
  const trimmed = value.trim();
  return trimmed.includes("@")
    ? trimmed.toLowerCase()
    : trimmed.replace(/[\s().-]/g, "");
}

/** A Messages compose link to `line` with `code` in the body (`sms:+1…&body=…`). */
export function messagesLink(line: string, code: string): string {
  return `sms:${line}&body=${encodeURIComponent(code)}`;
}

/** `m:ss` of what is left of an attempt. */
export function formatRemaining(ms: number): string {
  const seconds = Math.max(0, Math.ceil(ms / 1000));
  return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`;
}

/** The iMessage account form that starts a connection. */
export function IMessageAccountForm({
  initial,
  error,
  busy,
  onSubmit,
  onCancel,
}: {
  initial: string;
  /** A localized reason the last start failed. */
  error: string | undefined;
  busy: boolean;
  onSubmit: (handle: string) => void;
  onCancel: (() => void) | undefined;
}) {
  const m = useCommaMessages();
  const [draft, setDraft] = useState(initial);
  const [tried, setTried] = useState(false);
  const [submitted, setSubmitted] = useState<string>();
  const handle = normalizeHandle(draft);
  const valid = E164.test(handle) || EMAIL.test(handle);
  // A refusal belongs to the account it refused. Editing the account clears it.
  const refusal = error && handle === submitted ? error : undefined;
  const submit = () => {
    setTried(true);
    if (!valid || busy) return;
    setSubmitted(handle);
    onSubmit(handle);
  };
  return (
    <form
      className="flex w-full flex-col gap-md"
      data-testid="imessage-account-form"
      onSubmit={(event) => {
        event.preventDefault();
        submit();
      }}
    >
      <p className="m-0 text-sm leading-5 text-tertiary">
        {m.settings_imessage_handle_intro()}
      </p>
      <InputField
        autoComplete="username"
        disabled={busy}
        label={m.settings_imessage_handle_label()}
        name="handle"
        onChange={(event) => setDraft(event.target.value)}
        placeholder="name@example.com"
        type="text"
        value={draft}
        {...(refusal
          ? { errorMessage: refusal }
          : tried && !valid
            ? { errorMessage: m.settings_imessage_handle_invalid() }
            : { hint: m.settings_imessage_handle_hint() })}
      />
      <div className="flex flex-wrap gap-sm">
        <Button disabled={busy || !handle} hierarchy="primary" size="sm" type="submit">
          {m.settings_imessage_get_code()}
        </Button>
        {onCancel ? (
          <Button
            disabled={busy}
            hierarchy="secondary-gray"
            onPress={onCancel}
            size="sm"
          >
            {m.settings_profile_cancel()}
          </Button>
        ) : null}
      </div>
    </form>
  );
}

/** The attempt under way: the line, the code, time left, a QR code and a one-tap Messages link. */
export function IMessageCodePanel({
  code,
  line,
  phone,
  remainingMs,
  busy,
  onNewCode,
  onChangeNumber,
}: {
  code: string;
  line: string;
  /** The account that must send the code. Without one, any account can. */
  phone: string | undefined;
  remainingMs: number;
  busy: boolean;
  onNewCode: () => void;
  onChangeNumber: (() => void) | undefined;
}) {
  const m = useCommaMessages();
  const copy = (value: string) => {
    void copyWithFeedback(() => nativePlatformClipboard.writeText(value), m);
  };
  const expired = remainingMs <= 0;

  if (expired)
    return (
      <div className="flex w-full flex-col gap-md" data-testid="imessage-expired">
        <p className="m-0 text-sm leading-5 text-tertiary">
          {m.settings_imessage_code_expired()}
        </p>
        <div className="flex flex-wrap gap-sm">
          <Button disabled={busy} hierarchy="primary" onPress={onNewCode} size="sm">
            {m.settings_imessage_new_code()}
          </Button>
          {onChangeNumber ? (
            <Button
              disabled={busy}
              hierarchy="secondary-gray"
              onPress={onChangeNumber}
              size="sm"
            >
              {m.settings_imessage_change_number()}
            </Button>
          ) : null}
        </div>
      </div>
    );

  return (
    <section
      aria-label={m.settings_imessage_code_title()}
      className="flex w-full flex-col gap-md"
      data-testid="imessage-code"
    >
      <div className="flex flex-col gap-xs">
        <div className="flex flex-wrap items-baseline justify-between gap-x-md">
          <p className="m-0 text-sm font-medium text-primary">
            {m.settings_imessage_code_title()}
          </p>
          <p className="m-0 text-sm text-tertiary" data-testid="imessage-expiry">
            {m.settings_imessage_expires_in({ time: formatRemaining(remainingMs) })}
          </p>
        </div>
        <p className="m-0 text-pretty text-sm leading-5 text-tertiary">
          {phone
            ? m.settings_imessage_code_steps({ phone })
            : m.settings_imessage_code_steps_any()}
        </p>
      </div>
      <div className="flex flex-wrap items-center gap-xl">
        <figure
          aria-label={m.settings_imessage_qr_label()}
          className="m-0 w-fit rounded-md border border-secondary bg-white p-sm"
          data-testid="imessage-qr"
        >
          <QRCodeSVG
            aria-hidden
            marginSize={0}
            size={112}
            value={messagesLink(line, code)}
          />
        </figure>
        <div className="flex min-w-0 flex-col items-start gap-sm">
          <p className="m-0 text-sm text-tertiary">
            {m.settings_imessage_manual_title()}
          </p>
          <dl className="m-0 grid grid-cols-[auto_auto_auto] items-center gap-x-md">
            <dt className="text-sm text-tertiary">
              {m.settings_imessage_line_label()}
            </dt>
            <dd className="m-0 text-sm text-primary" data-testid="imessage-line">
              {line}
            </dd>
            <dd className="m-0 flex">
              <Button
                aria-label={m.settings_imessage_copy_number()}
                hierarchy="tertiary-gray"
                iconLeading={<CopyIcon />}
                className="h-6 w-6 p-xs"
                iconOnly
                onPress={() => copy(line)}
                size="xs"
              />
            </dd>
            <dt className="text-sm text-tertiary">
              {m.settings_imessage_code_label()}
            </dt>
            <dd
              className="m-0 font-mono text-sm font-medium text-primary [overflow-wrap:anywhere]"
              data-testid="imessage-code-value"
            >
              {code}
            </dd>
            <dd className="m-0 flex">
              <Button
                aria-label={m.settings_imessage_copy_code()}
                hierarchy="tertiary-gray"
                iconLeading={<CopyIcon />}
                className="h-6 w-6 p-xs"
                iconOnly
                onPress={() => copy(code)}
                size="xs"
              />
            </dd>
          </dl>
          <Button
            hierarchy="link-color"
            iconTrailing={<ArrowUpRightIcon />}
            onPress={() => {
              void openNativePlatformExternalUrl(messagesLink(line, code)).catch(
                () => undefined
              );
            }}
            className="-ml-[2px] h-auto"
            size="sm"
          >
            {m.settings_imessage_open_messages()}
          </Button>
        </div>
      </div>
    </section>
  );
}
