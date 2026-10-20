import { useCommaMessages } from "@comma/i18n/react";
import { Button } from "@comma/ui/components/Button";
import { ArrowUpRightIcon, CopyIcon } from "@comma/ui/components/icons";
import { InputField } from "@comma/ui/components/input";
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
  return `sms:${encodeURIComponent(line)}&body=${encodeURIComponent(code)}`;
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

/** The attempt under way: the line, the code, time left, and a one-tap Messages link. */
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
  phone: string;
  remainingMs: number;
  busy: boolean;
  onNewCode: () => void;
  onChangeNumber: () => void;
}) {
  const m = useCommaMessages();
  const [copied, setCopied] = useState<"line" | "code">();
  const copy = (value: string, what: "line" | "code") => {
    void nativePlatformClipboard.writeText(value).then(
      () => setCopied(what),
      () => undefined
    );
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
          <Button
            disabled={busy}
            hierarchy="secondary-gray"
            onPress={onChangeNumber}
            size="sm"
          >
            {m.settings_imessage_change_number()}
          </Button>
        </div>
      </div>
    );

  return (
    <section
      aria-label={m.settings_imessage_code_title()}
      className="flex w-full flex-col gap-md"
      data-testid="imessage-code"
    >
      <p className="m-0 text-sm font-medium text-primary">
        {m.settings_imessage_code_title()}
      </p>
      <p className="m-0 text-sm leading-5 text-tertiary">
        {m.settings_imessage_code_steps({ line, phone })}
      </p>
      <dl className="m-0 grid grid-cols-[auto_1fr] items-center gap-x-xl gap-y-sm">
        <dt className="text-xs text-tertiary">{m.settings_imessage_line_label()}</dt>
        <dd className="m-0 font-mono text-sm text-primary" data-testid="imessage-line">
          {line}
        </dd>
        <dt className="text-xs text-tertiary">{m.settings_imessage_code_label()}</dt>
        <dd
          className="m-0 font-mono text-lg font-semibold tracking-wide text-primary [overflow-wrap:anywhere]"
          data-testid="imessage-code-value"
        >
          {code}
        </dd>
      </dl>
      <div className="flex flex-wrap gap-sm">
        <Button
          hierarchy="primary"
          iconTrailing={<ArrowUpRightIcon />}
          onPress={() => {
            void openNativePlatformExternalUrl(messagesLink(line, code)).catch(
              () => undefined
            );
          }}
          size="sm"
        >
          {m.settings_imessage_open_messages()}
        </Button>
        <Button
          hierarchy="secondary-gray"
          iconLeading={<CopyIcon />}
          onPress={() => copy(code, "code")}
          size="sm"
        >
          {copied === "code" ? m.common_copied() : m.settings_imessage_copy_code()}
        </Button>
        <Button
          hierarchy="secondary-gray"
          iconLeading={<CopyIcon />}
          onPress={() => copy(line, "line")}
          size="sm"
        >
          {copied === "line" ? m.common_copied() : m.settings_imessage_copy_number()}
        </Button>
      </div>
      <p
        className="m-0 text-xs leading-5 text-quaternary"
        data-testid="imessage-expiry"
      >
        {m.settings_imessage_expires_in({ time: formatRemaining(remainingMs) })}
        {" · "}
        {m.settings_imessage_waiting_reply()}
      </p>
    </section>
  );
}
