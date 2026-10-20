import { Badge, type BadgeColor } from "@comma/ui/components/Badge";
import { Button } from "@comma/ui/components/Button";
import { Dialog } from "@comma/ui/components/dialog";
import { InputField } from "@comma/ui/components/input";
import { ScrollArea } from "@comma/ui/components/scroll-area";
import { CopyIcon, XIcon } from "@comma/ui/components/icons";
import { DateTime, Effect, Option } from "effect";
import { useEffect, useId, useState, type ReactNode } from "react";
import { AdminBrowser } from "./adminBrowser";
import type { Confirmation } from "./adminModel";
import { useAdminCommand, useAdminState } from "./adminRuntime";
import { messages } from "@comma/i18n";

export function AdminDrawer({
  children,
  eyebrow,
  isDismissable = true,
  onClose,
  title,
}: {
  children: ReactNode;
  eyebrow: string;
  isDismissable?: boolean;
  onClose: () => void;
  title: string;
}) {
  const titleId = useId();

  useEffect(() => {
    const priorFocus =
      document.activeElement instanceof HTMLElement
        ? document.activeElement
        : undefined;
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape" && isDismissable) {
        onClose();
      }
    };
    document.addEventListener("keydown", onKeyDown);

    return () => {
      document.removeEventListener("keydown", onKeyDown);
      priorFocus?.focus();
    };
  }, [isDismissable, onClose]);

  return (
    <dialog
      aria-labelledby={titleId}
      aria-modal="true"
      className="admin-drawer-backdrop"
      open
    >
      <button
        aria-label={messages.admin_close_details()}
        className="admin-drawer-dismiss"
        onClick={() => {
          if (isDismissable) onClose();
        }}
        tabIndex={-1}
        type="button"
      />
      <section className="admin-drawer">
        <header className="admin-drawer-header">
          <div className="admin-drawer-heading">
            <p>{eyebrow}</p>
            <h2 id={titleId}>{title}</h2>
          </div>
          {isDismissable ? (
            <Button
              aria-label={messages.admin_close()}
              autoFocus
              hierarchy="tertiary-gray"
              iconLeading={<XIcon />}
              iconOnly
              onPress={onClose}
              size="sm"
            />
          ) : null}
        </header>
        <ScrollArea
          className="admin-drawer-scroll"
          contentClassName="admin-drawer-content"
          edgeEffect="none"
          orientation="vertical"
          scrollbarVisibility="hover"
          viewportClassName="admin-drawer-viewport"
        >
          {children}
        </ScrollArea>
      </section>
    </dialog>
  );
}

/**
 * A titled group of rows in one card, as Comma's settings lay them out: the title sits above the card, and the rows
 * inside are separated by hairlines, never boxed again.
 */
export function AdminSection({
  action,
  children,
  label,
  title,
}: {
  action?: ReactNode;
  children: ReactNode;
  /** The accessible name when it differs from the visible title. */
  label?: string;
  title: string;
}) {
  const titleId = useId();
  return (
    <section
      {...(label ? { "aria-label": label } : { "aria-labelledby": titleId })}
      className="admin-section"
    >
      <div className="admin-section-header">
        <h2 id={titleId}>{title}</h2>
        {action ? <div className="admin-section-action">{action}</div> : null}
      </div>
      <div className="admin-section-body">{children}</div>
    </section>
  );
}

/** One row of a section: what it is on the left, its value or control on the right. */
export function AdminRow({
  children,
  description,
  title,
  titleId,
}: {
  children?: ReactNode;
  description?: ReactNode;
  title: ReactNode;
  titleId?: string;
}) {
  return (
    <div className="admin-row">
      <div className="admin-row-copy">
        <p className="admin-row-title" {...(titleId ? { id: titleId } : {})}>
          {title}
        </p>
        {description ? <p className="admin-row-description">{description}</p> : null}
      </div>
      {children !== undefined ? <div className="admin-row-end">{children}</div> : null}
    </div>
  );
}

/** An identifier, with a button that copies it. */
export function CopyableId({ value }: { value: string | null | undefined }) {
  const run = useAdminCommand();
  const [copied, setCopied] = useState(false);
  if (!value) return <>—</>;
  return (
    <span className="admin-copyable-id">
      <code>{value}</code>
      <Button
        aria-label={
          copied
            ? messages.admin_copied_value({ value })
            : messages.admin_copy_value({ value })
        }
        hierarchy="tertiary-gray"
        iconLeading={<CopyIcon />}
        iconOnly
        onPress={() =>
          run(
            AdminBrowser.use((browser) => browser.copy(value)).pipe(
              Effect.tap(() => Effect.sync(() => setCopied(true))),
              Effect.ignore
            )
          )
        }
        size="sm"
      />
    </span>
  );
}

export function AdminPageHeader({
  actions,
  description,
  title,
}: {
  actions?: ReactNode;
  description: string;
  title: string;
}) {
  return (
    <header className="admin-page-header">
      <div className="admin-page-heading">
        <h1>{title}</h1>
        <p className="admin-page-description">{description}</p>
      </div>
      {actions ? <div className="admin-page-actions">{actions}</div> : null}
    </header>
  );
}

/** The bar under an edited settings form: it shows that the form has unsaved changes and saves them after review. */
export function AdminSaveBar({
  canSave,
  changes,
  disabled = false,
  onDiscard,
  onSave,
  saveLabel,
}: {
  canSave: boolean;
  /** How many settings differ from the saved ones; zero hides the bar. */
  changes: number;
  disabled?: boolean;
  onDiscard: () => void;
  onSave: () => void;
  saveLabel: string;
}) {
  if (changes === 0) return null;
  return (
    <section aria-label={messages.admin_unsaved_changes()} className="admin-save-bar">
      <StatusText color="blue">
        {changes === 1
          ? messages.admin_unsaved_change_count_one()
          : messages.admin_unsaved_change_count({ count: changes })}
      </StatusText>
      <span className="admin-save-bar-spacer" />
      <Button hierarchy="secondary-gray" isDisabled={disabled} onPress={onDiscard}>
        {messages.admin_discard()}
      </Button>
      <Button isDisabled={disabled || !canSave} onPress={onSave}>
        {saveLabel}
      </Button>
    </section>
  );
}

export function AdminNotice({
  message,
  onDismiss,
  tone = "success",
}: {
  message: string;
  onDismiss?: () => void;
  tone?: "error" | "success";
}) {
  return (
    <output className="admin-operation-notice" data-tone={tone}>
      <span>{message}</span>
      {onDismiss ? (
        <Button hierarchy="link-gray" onPress={onDismiss} size="sm">
          {messages.admin_dismiss()}
        </Button>
      ) : null}
    </output>
  );
}

/**
 * The audited-command review (adminModel.ts): what the command changes, the reason the audit event keeps, and for a
 * guarded command the target's name, typed.
 */
export function AdminConfirmationDialog({
  confirmation,
}: {
  confirmation: Confirmation;
}) {
  const run = useAdminCommand();
  const state = useAdminState(confirmation.state);
  const busy = state?.busy ?? false;
  const destructive = state?.destructive ?? false;
  const typed = state?.typed;
  const changes = state?.changes ?? [];
  const error = state?.error;

  return (
    <Dialog
      actions={[
        ...(!busy
          ? [
              {
                hierarchy: "secondary-gray" as const,
                label: messages.admin_cancel(),
                onPress: () => run(confirmation.cancel),
              },
            ]
          : []),
        {
          hierarchy: destructive ? "destructive" : "primary",
          label: busy ? messages.admin_working() : messages.admin_confirm(),
          onPress: () => run(confirmation.confirm),
        },
      ]}
      {...(state?.explanation ? { description: state.explanation } : {})}
      isDismissable={!busy}
      isOpen={state?.open ?? false}
      onOpenChange={(open) => {
        if (!open) run(confirmation.cancel);
      }}
      showCloseButton={!busy}
      title={state?.title ?? ""}
    >
      <div className="admin-review">
        {changes.length ? (
          <dl
            aria-label={messages.admin_review_changes()}
            className="admin-review-changes"
          >
            {changes.map((change) => (
              <div key={change.label}>
                <dt>{change.label}</dt>
                <dd>
                  <s>{change.before}</s>
                  <span aria-hidden="true">→</span>
                  <strong>{change.after}</strong>
                </dd>
              </div>
            ))}
          </dl>
        ) : null}
        <InputField
          className="w-full"
          hint={messages.admin_review_reason_hint()}
          disabled={busy}
          label={messages.admin_review_reason()}
          maxLength={500}
          onChange={(event) => run(confirmation.setReason(event.target.value))}
          placeholder={messages.admin_review_reason_placeholder()}
          value={state?.reason ?? ""}
        />
        {typed !== undefined ? (
          <InputField
            className="w-full"
            destructive={destructive}
            disabled={busy}
            label={messages.admin_review_typed({ name: typed })}
            onChange={(event) => run(confirmation.setValue(event.target.value))}
            placeholder={typed}
            value={state?.value ?? ""}
          />
        ) : null}
        {error ? (
          <p className="admin-review-error" role="alert">
            {error}
          </p>
        ) : null}
      </div>
    </Dialog>
  );
}

export function AdminState({
  actionLabel = messages.admin_retry(),
  message,
  onAction,
  title,
  tone = "default",
}: {
  actionLabel?: string;
  message?: string;
  onAction?: () => void;
  title: string;
  tone?: "default" | "error";
}) {
  return (
    <div className="admin-state" data-tone={tone}>
      <div className="admin-state-copy">
        <h2>{title}</h2>
        {message ? (
          <p role={tone === "error" ? "alert" : undefined}>{message}</p>
        ) : null}
      </div>
      {onAction ? (
        <Button hierarchy="secondary-gray" onPress={onAction}>
          {actionLabel}
        </Button>
      ) : null}
    </div>
  );
}

export function DetailList({
  items,
}: {
  items: Array<{ label: string; value: ReactNode }>;
}) {
  return (
    <dl className="admin-detail-list">
      {items.map((item) => (
        <div className="admin-detail-row" key={item.label}>
          <dt>{item.label}</dt>
          <dd>{item.value}</dd>
        </div>
      ))}
    </dl>
  );
}

export function NativeField({
  children,
  hint,
  label,
}: {
  children: ReactNode;
  hint?: string;
  label: string;
}) {
  return (
    <label className="admin-native-field">
      <span>{label}</span>
      {children}
      {hint ? <small>{hint}</small> : null}
    </label>
  );
}

/** A state as Comma's settings report one: a colored dot and a plain word, no pill. */
export function StatusBadge({ status }: { status?: string | null | undefined }) {
  const value = status?.trim() || "unknown";
  return <StatusText color={statusColor(value)}>{humanizeStatus(value)}</StatusText>;
}

export function StatusText({
  children,
  color,
}: {
  children: ReactNode;
  color: BadgeColor;
}) {
  return (
    <Badge
      className="border-0 bg-transparent p-0 font-normal text-tertiary"
      color={color}
      dot
      size="sm"
    >
      {children}
    </Badge>
  );
}

const statusLabels: Record<string, () => string> = {
  active: messages.admin_state_active,
  applied: messages.admin_state_applied,
  disabled: messages.admin_state_disabled,
  expired: messages.admin_state_expired,
  failed: messages.admin_state_failed,
  identity_mismatch: messages.admin_state_identity_mismatch,
  inactive: messages.admin_state_inactive,
  missing: messages.admin_state_missing,
  pending: messages.admin_state_pending,
  provisioning: messages.admin_state_provisioning,
  ready: messages.admin_state_ready,
  rejected: messages.admin_state_rejected,
  revoked: messages.admin_state_revoked,
  started: messages.admin_state_started,
  succeeded: messages.admin_state_succeeded,
  unknown: messages.admin_state_unknown,
};

/** A server state in the page's language; `identity_mismatch` reads `Identity mismatch`. */
export function humanizeStatus(value: string): string {
  const known = statusLabels[value.toLowerCase()];
  if (known) return known();
  const words = value.replaceAll("_", " ");
  return words.charAt(0).toUpperCase() + words.slice(1);
}

/** The page's language (set at startup from the chosen locale), for dates and numbers. */
export function pageLocale(): string | undefined {
  return (
    (typeof document !== "undefined" && document.documentElement.lang) || undefined
  );
}

/** A `datetime-local` value (wall time in the browser's time zone) as an instant; none when it is not a date. */
export function localDateTime(value: string) {
  return DateTime.makeZoned(value, {
    timeZone: DateTime.zoneMakeLocal(),
    adjustForTimeZone: true,
  });
}

export function formatEpoch(value?: number | null) {
  if (!value) {
    return "—";
  }
  return DateTime.formatLocal(DateTime.makeUnsafe(value * 1_000), {
    locale: pageLocale(),
    dateStyle: "medium",
    timeStyle: "short",
  });
}

/** `value` (an instant) in the browser's time zone, with `options`; `value` itself when it is not a date. */
export function formatLocalDate(value: string, options: Intl.DateTimeFormatOptions) {
  return Option.match(DateTime.make(value), {
    onNone: () => value,
    onSome: (date) => DateTime.formatLocal(date, { locale: pageLocale(), ...options }),
  });
}

export function formatIso(value?: string | null) {
  if (!value) {
    return "—";
  }
  return formatLocalDate(value, { dateStyle: "medium", timeStyle: "short" });
}

export function displayText(value?: string | null) {
  return value?.trim() || "—";
}

function statusColor(status: string): BadgeColor {
  switch (status.toLowerCase()) {
    case "active":
    case "applied":
    case "ready":
    case "succeeded":
      return "success";
    case "disabled":
    case "expired":
    case "revoked":
      return "gray";
    case "pending":
    case "started":
      return "warning";
    case "failed":
    case "invalid":
    case "rejected":
      return "error";
    default:
      return "blue";
  }
}
