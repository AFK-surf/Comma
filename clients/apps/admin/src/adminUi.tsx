import { Badge, Button, Dialog, ScrollArea, XIcon, type BadgeColor } from "@comma/ui";
import { useEffect, useId, useState, type ReactNode } from "react";

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
        aria-label="Close details"
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
              aria-label="Close"
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

export function AdminPageHeader({
  actions,
  description,
  eyebrow,
  title,
}: {
  actions?: ReactNode;
  description: string;
  eyebrow: string;
  title: string;
}) {
  return (
    <header className="admin-page-header">
      <div className="admin-page-heading">
        <p className="admin-page-eyebrow">{eyebrow}</p>
        <h1>{title}</h1>
        <p className="admin-page-description">{description}</p>
      </div>
      {actions ? <div className="admin-page-actions">{actions}</div> : null}
    </header>
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
          Dismiss
        </Button>
      ) : null}
    </output>
  );
}

export function AdminConfirmationDialog({
  destructive = false,
  expected,
  isOpen,
  onBusyChange,
  onConfirm,
  onOpenChange,
  title,
}: {
  destructive?: boolean;
  expected: string;
  isOpen: boolean;
  onBusyChange?: (busy: boolean) => void;
  onConfirm: () => Promise<void>;
  onOpenChange: (open: boolean) => void;
  title: string;
}) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string>();
  const [value, setValue] = useState("");

  useEffect(() => {
    if (isOpen) {
      setBusy(false);
      onBusyChange?.(false);
      setError(undefined);
      setValue("");
    }
  }, [isOpen, onBusyChange]);

  const confirm = async () => {
    if (busy) {
      return;
    }
    if (value !== expected) {
      setError("The confirmation does not match this target.");
      return;
    }

    setBusy(true);
    onBusyChange?.(true);
    setError(undefined);
    try {
      await onConfirm();
      onBusyChange?.(false);
      onOpenChange(false);
    } catch (commandError) {
      setError(
        commandError instanceof Error && commandError.message
          ? commandError.message
          : "The operation could not be completed."
      );
      setBusy(false);
      onBusyChange?.(false);
    }
  };
  const requestOpenChange = (open: boolean) => {
    if (!open && busy) {
      return;
    }
    onOpenChange(open);
  };

  return (
    <Dialog
      actions={[
        ...(!busy
          ? [
              {
                hierarchy: "secondary-gray" as const,
                label: "Cancel",
                onPress: () => onOpenChange(false),
              },
            ]
          : []),
        {
          hierarchy: destructive ? "destructive" : "primary",
          label: busy ? "Working…" : "Confirm",
          onPress: () => void confirm(),
        },
      ]}
      description={`Type “${expected}” to bind this audited command to the intended target.`}
      input={{
        "aria-label": "Confirmation value",
        destructive,
        ...(error ? { errorMessage: error } : {}),
        label: "Confirmation",
        onChange: (event) => setValue(event.target.value),
        placeholder: expected,
        value,
      }}
      isDismissable={!busy}
      isOpen={isOpen}
      onOpenChange={requestOpenChange}
      showCloseButton={!busy}
      title={title}
      variant="input"
    />
  );
}

export function AdminState({
  actionLabel = "Retry",
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

export function ReasonField({
  onChange,
  value,
}: {
  onChange: (value: string) => void;
  value: string;
}) {
  return (
    <NativeField
      hint="Required. Stored in the durable Admin audit event."
      label="Reason"
    >
      <textarea
        maxLength={500}
        minLength={3}
        onChange={(event) => onChange(event.target.value)}
        placeholder="Why is this operation needed?"
        required
        rows={4}
        value={value}
      />
    </NativeField>
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

export function StatusBadge({ status }: { status?: string | null | undefined }) {
  const label = status?.trim() || "unknown";
  return (
    <Badge color={statusColor(label)} dot size="sm" type="pill-color">
      {label}
    </Badge>
  );
}

export function formatEpoch(value?: number | null) {
  if (!value) {
    return "—";
  }
  return new Intl.DateTimeFormat(undefined, {
    dateStyle: "medium",
    timeStyle: "short",
  }).format(new Date(value * 1_000));
}

export function formatIso(value?: string | null) {
  if (!value) {
    return "—";
  }

  const date = new Date(value);
  if (Number.isNaN(date.valueOf())) {
    return value;
  }

  return new Intl.DateTimeFormat(undefined, {
    dateStyle: "medium",
    timeStyle: "short",
  }).format(date);
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
