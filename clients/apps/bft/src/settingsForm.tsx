import { Button, Dialog, InputField, ScrollArea } from "@comma/ui";
import { useId, useState, type ReactNode } from "react";
import { BftApiError, type BftFieldErrors } from "./api";
import { ConfirmDialog, DialogError, writeErrorMessage } from "./dialogs";
import { messages } from "./messages";
import type { Resource } from "./resource";
import { ErrorState, Skeleton } from "./states";

const t = messages.settings;

/**
 * A Settings-style page: the header, then one scrolling column of sections.
 * The Integrations page passes `wide` to lay its sections out in a grid. A
 * runtime outage or a conflict is a quiet notice with a retry, not an error page.
 */
export function SettingsPage<T>({
  title,
  description,
  resource,
  onRetry,
  wide = false,
  actions,
  children,
}: {
  title: string;
  description: string | undefined;
  resource: Resource<T>;
  onRetry: () => void;
  wide?: boolean;
  actions?: ReactNode;
  children: (data: T) => ReactNode;
}) {
  return (
    <div className="bft-page">
      <div className="bft-page-header">
        <div className="bft-page-heading">
          <h1>{title}</h1>
          <p>{description ?? <Skeleton width={220} />}</p>
        </div>
        {actions ? <div className="bft-page-actions">{actions}</div> : null}
      </div>
      {resource.state === "error" ? (
        // An outage, or a state the reader can act on (409), is said in place.
        resource.error instanceof BftApiError &&
        (resource.error.code === "runtime_unavailable" ||
          resource.error.status === 409) ? (
          <output className="bft-quiet-row">
            <p className="bft-quiet bft-quiet-inline">{resource.error.message}</p>
            <button className="bft-btn bft-btn-sm" onClick={onRetry} type="button">
              {messages.states.retry}
            </button>
          </output>
        ) : (
          <ErrorState onRetry={onRetry} />
        )
      ) : (
        <ScrollArea
          className="bft-panel-scroll"
          edgeEffect="none"
          orientation="vertical"
          scrollbarVisibility="hover"
          viewportClassName="bft-scroll-viewport"
        >
          <div className={wide ? "bft-settings bft-settings-wide" : "bft-settings"}>
            {resource.state === "ready" ? (
              children(resource.data)
            ) : (
              <div className="bft-rows-skeleton bft-rows-skeleton-flush">
                <Skeleton height={14} width="30%" />
                <Skeleton height={32} />
                <Skeleton height={32} />
                <Skeleton height={32} width="60%" />
              </div>
            )}
          </div>
        </ScrollArea>
      )}
    </div>
  );
}

/** A titled group of fields or rows, separated from the next by a hairline. */
export function FormSection({
  id,
  title,
  description,
  action,
  children,
}: {
  id?: string;
  title: string;
  description?: string | undefined;
  /** One button or link at the end of the heading row. */
  action?: ReactNode;
  children: ReactNode;
}) {
  const headingId = useId();
  return (
    <section aria-labelledby={headingId} className="bft-form-section" id={id}>
      <div className="bft-form-section-head">
        <h2 id={headingId}>{title}</h2>
        {action}
      </div>
      {description ? <p className="bft-form-section-note">{description}</p> : null}
      <div className="bft-form">{children}</div>
    </section>
  );
}

export interface WriteState {
  busy: boolean;
  error: string | undefined;
  fields: BftFieldErrors;
  saved: boolean;
}

const idle: WriteState = { busy: false, error: undefined, fields: {}, saved: false };

/**
 * One write at a time for a form or dialog: the server's message and its
 * field errors on failure, the refreshed data to `onDone` on success.
 */
export function useWrite() {
  const [state, setState] = useState<WriteState>(idle);
  const run = <T,>(write: () => Promise<T>, onDone: (data: T) => void) => {
    setState({ ...idle, busy: true });
    write().then(
      (data) => {
        setState({ ...idle, saved: true });
        onDone(data);
      },
      (caught: unknown) =>
        setState({
          ...idle,
          error: writeErrorMessage(caught),
          fields: caught instanceof BftApiError ? caught.fields : {},
        })
    );
  };
  return { ...state, run, reset: () => setState(idle) };
}

/** The submit row of a form: its error or a quiet "Saved", then the buttons. */
export function FormActions({
  write,
  children,
}: {
  write: WriteState;
  children: ReactNode;
}) {
  return (
    <div className="bft-form-actions">
      {write.error ? (
        <p className="bft-dialog-error" role="alert">
          {write.error}
        </p>
      ) : write.saved ? (
        <output className="bft-form-saved">{t.saved}</output>
      ) : null}
      {children}
    </div>
  );
}

export function SaveButton({
  busy,
  disabled = false,
  onPress,
  label = t.save,
}: {
  busy: boolean;
  disabled?: boolean;
  onPress: () => void;
  label?: string;
}) {
  return (
    <Button disabled={busy || disabled} hierarchy="primary" onPress={onPress} size="sm">
      {busy ? t.saving : label}
    </Button>
  );
}

/** Error text under a control that has no error slot of its own. */
export function FieldError({ message }: { message: string | undefined }) {
  return message ? <p className="bft-dialog-error">{message}</p> : null;
}

/**
 * A write-only secret. The stored value is never sent back, so the field
 * starts blank and a blank save keeps it.
 */
export function SecretField({
  label,
  configured,
  value,
  onChange,
  error,
  disabled,
}: {
  label: string;
  configured: boolean;
  value: string;
  onChange: (value: string) => void;
  error?: string | undefined;
  disabled?: boolean;
}) {
  return (
    <InputField
      autoComplete="new-password"
      className="w-full"
      fieldSize="sm"
      disabled={disabled}
      hint={configured ? t.secretConfigured : t.secretWriteOnly}
      label={label}
      onChange={(event) => onChange(event.target.value)}
      placeholder={configured ? "••••••••" : ""}
      type="password"
      value={value}
      wrapperClassName="bft-form-field"
      {...(error ? { errorMessage: error } : {})}
    />
  );
}

/** A plain text field bound to a string. */
export function TextField({
  label,
  value,
  onChange,
  error,
  hint,
  placeholder,
  disabled,
}: {
  label: string;
  value: string;
  onChange: (value: string) => void;
  error?: string | undefined;
  hint?: string;
  placeholder?: string;
  disabled?: boolean;
}) {
  return (
    <InputField
      autoComplete="off"
      className="w-full"
      fieldSize="sm"
      disabled={disabled}
      label={label}
      onChange={(event) => onChange(event.target.value)}
      value={value}
      wrapperClassName="bft-form-field"
      {...(error ? { errorMessage: error } : {})}
      {...(hint ? { hint } : {})}
      {...(placeholder ? { placeholder } : {})}
    />
  );
}

/** A multi-line text field; `mono` for identifiers and JSON. */
export function TextAreaField({
  label,
  value,
  onChange,
  hint,
  mono = false,
  rows = 2,
  disabled,
}: {
  label: string;
  value: string;
  onChange: (value: string) => void;
  hint?: string;
  mono?: boolean;
  rows?: number;
  disabled?: boolean;
}) {
  return (
    <label className="bft-textarea-field">
      <span>{label}</span>
      <textarea
        className={mono ? "bft-textarea bft-textarea-mono" : "bft-textarea"}
        disabled={disabled}
        onChange={(event) => onChange(event.target.value)}
        rows={rows}
        spellCheck={!mono}
        value={value}
      />
      {hint ? <small>{hint}</small> : null}
    </label>
  );
}

/** A section the runtime could not load, said quietly in place. */
export function Unavailable({ onRetry }: { onRetry?: () => void }) {
  const notice = <p className="bft-quiet bft-quiet-inline">{t.unavailable}</p>;
  return onRetry ? (
    <div className="bft-quiet-row">
      {notice}
      <button className="bft-btn bft-btn-sm" onClick={onRetry} type="button">
        {messages.states.retry}
      </button>
    </div>
  ) : (
    notice
  );
}

/** A small form in the shared dialog; stays open while its write runs. */
export function FormDialog({
  title,
  description,
  submitLabel = t.save,
  wide = false,
  write,
  onSubmit,
  onClose,
  children,
}: {
  title: string;
  description: string;
  submitLabel?: string;
  wide?: boolean;
  write: WriteState;
  onSubmit: () => void;
  onClose: () => void;
  children: ReactNode;
}) {
  return (
    <Dialog
      {...(wide ? { className: "bft-dialog-wide" } : {})}
      actions={[
        {
          label: messages.common.cancel,
          hierarchy: "secondary-gray",
          onPress: onClose,
          disabled: write.busy,
        },
        {
          label: write.busy ? t.saving : submitLabel,
          hierarchy: "primary",
          onPress: onSubmit,
          disabled: write.busy,
        },
      ]}
      description={description}
      isDismissable={!write.busy}
      isOpen
      onOpenChange={(open) => {
        if (!open && !write.busy) onClose();
      }}
      title={title}
    >
      <ScrollArea
        className="bft-dialog-body"
        edgeEffect="none"
        orientation="vertical"
        scrollbarVisibility="hover"
        viewportClassName="bft-dialog-scroll"
      >
        <div className="bft-form">
          {children}
          <DialogError message={write.error} />
        </div>
      </ScrollArea>
    </Dialog>
  );
}

export interface ConfirmRequest {
  title: string;
  description: string;
  confirmLabel: string;
  /** The write; it applies its own result before resolving. */
  action: () => Promise<unknown>;
}

/** A destructive write behind the shared confirmation; render `dialog`. */
export function useConfirm() {
  const [pending, setPending] = useState<ConfirmRequest | null>(null);
  const write = useWrite();
  const close = () => {
    if (write.busy) return;
    setPending(null);
    write.reset();
  };
  const dialog = pending ? (
    <ConfirmDialog
      busy={write.busy}
      confirmLabel={pending.confirmLabel}
      description={pending.description}
      destructive
      error={write.error}
      onClose={close}
      onConfirm={() => write.run(pending.action, () => setPending(null))}
      title={pending.title}
    />
  ) : null;
  return { ask: setPending, dialog };
}
