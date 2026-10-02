import { Button, Dialog } from "@comma/ui";
import { useEffect, useState, type ReactNode } from "react";
import { BftApiError, BftUnauthenticatedError, csrfRejectedCode } from "./api";
import { messages } from "./messages";

const t = messages.common;

/**
 * What to tell the reader after a failed write: the server's own localized
 * message when it sent one, a reload hint when the CSRF token was refused,
 * and a generic line otherwise.
 */
export function writeErrorMessage(error: unknown): string | undefined {
  // The browser is already leaving for /login.
  if (error instanceof BftUnauthenticatedError) return undefined;
  if (error instanceof BftApiError) {
    if (error.code === csrfRejectedCode) return t.reloadRequired;
    if (error.code && error.code !== "invalid_response") return error.message;
  }
  return t.writeFailed;
}

/** A confirmation built on the shared dialog; stays open while the write runs. */
export function ConfirmDialog({
  title,
  description,
  confirmLabel,
  destructive = false,
  busy,
  error,
  onConfirm,
  onClose,
  children,
}: {
  title: string;
  description: string;
  confirmLabel: string;
  destructive?: boolean;
  busy: boolean;
  error: string | undefined;
  onConfirm: () => void;
  onClose: () => void;
  children?: ReactNode;
}) {
  return (
    <Dialog
      actions={[
        {
          label: t.cancel,
          hierarchy: "secondary-gray",
          onPress: onClose,
          disabled: busy,
        },
        {
          label: busy ? t.working : confirmLabel,
          hierarchy: destructive ? "destructive" : "primary",
          onPress: onConfirm,
          disabled: busy,
        },
      ]}
      description={description}
      isDismissable={!busy}
      isOpen
      onOpenChange={(open) => {
        if (!open && !busy) onClose();
      }}
      title={title}
    >
      {children}
      <DialogError message={error} />
    </Dialog>
  );
}

export function DialogError({ message }: { message: string | undefined }) {
  return message ? (
    <p className="bft-dialog-error" role="alert">
      {message}
    </p>
  ) : null;
}

/** Copies `text`; the label confirms for two seconds. */
export function CopyButton({ text, label }: { text: string; label: string }) {
  const [state, setState] = useState<"idle" | "copied" | "failed">("idle");

  useEffect(() => {
    if (state === "idle") return undefined;
    const timer = window.setTimeout(() => setState("idle"), 2000);
    return () => window.clearTimeout(timer);
  }, [state]);

  const copy = () => {
    const clipboard = navigator.clipboard as Clipboard | undefined;
    if (!clipboard) {
      setState("failed");
      return;
    }
    clipboard.writeText(text).then(
      () => setState("copied"),
      () => setState("failed")
    );
  };

  return (
    <span className="bft-copy">
      <Button aria-label={label} hierarchy="secondary-gray" onPress={copy} size="xs">
        {state === "copied" ? t.copied : t.copy}
      </Button>
      {state === "failed" ? (
        <span className="bft-copy-failed" role="alert">
          {t.copyFailed}
        </span>
      ) : null}
    </span>
  );
}

/** A shell command or prompt, wrapped so nothing scrolls sideways. */
export function CodeBlock({ text, label }: { text: string; label: string }) {
  return (
    <pre aria-label={label} className="bft-code">
      <code>{text}</code>
    </pre>
  );
}
