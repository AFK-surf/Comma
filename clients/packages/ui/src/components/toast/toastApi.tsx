import { toast as sonnerToast, type ExternalToast } from "sonner";
import { definedProps } from "../utils";
import { FileTransferToast, type FileTransferToastProps } from "./FileTransferToast";
import { Toast } from "./Toast";
import type { ToastAction, ToastGlyph, ToastIntent, ToastVariant } from "./types";

export type ToastPosition = NonNullable<ExternalToast["position"]>;

export type ToastOptions = {
  description?: string;
  intent?: ToastIntent;
  icon?: ToastGlyph;
  duration?: number;
  actions?: ToastAction[];
  onClose?: () => void;
  /** Fires when the toast is closed by its timer rather than an interaction. */
  onAutoClose?: () => void;
  id?: string | number;
  /** Overrides `<Toaster position>` for this toast. */
  position?: ToastPosition;
  /** Stable hook for tests; rendered as `data-testid` on the toast shell. */
  testId?: string;
};

/**
 * Auto-dismiss after 5s unless the pointer is over the stack (sonner pauses
 * timers on hover) or the toast carries actions, which wait for the user.
 */
const defaultDuration: Record<ToastVariant, number> = {
  single: 5000,
  description: 5000,
  action: Number.POSITIVE_INFINITY,
};

export const resolveToastVariant = (options?: ToastOptions): ToastVariant => {
  if (options?.actions?.length) return "action";
  if (options?.description) return "description";
  return "single";
};

let toastsEnabled = true;

/**
 * Turns the imperative API into a no-op for a window that intentionally has no
 * toast surface (Side Chat and its child windows). Call it once at the renderer
 * entry point, before the first render.
 *
 * Not merely cosmetic: sonner's store is a module-level singleton while its
 * auto-dismiss timers live inside `<Toaster />`. A `toast(...)` raised from a
 * shared chat component in a window that never mounts one would be appended and
 * never retired — an unbounded retention in a long-lived accessory window.
 */
export function setToastsEnabled(enabled: boolean) {
  toastsEnabled = enabled;
}

const showCommaToast = (title: string, options?: ToastOptions) => {
  if (!toastsEnabled) return "";
  const variant = resolveToastVariant(options);
  const intent = options?.intent ?? (variant === "action" ? "success" : "info");

  let toastId: string | number = options?.id ?? "";

  toastId = sonnerToast(
    <Toast
      title={title}
      variant={variant}
      intent={intent}
      {...definedProps({
        description: options?.description,
        icon: options?.icon,
        actions: options?.actions,
        testId: options?.testId,
      })}
      onClose={() => {
        sonnerToast.dismiss(toastId);
        options?.onClose?.();
      }}
    />,
    {
      ...definedProps({ id: options?.id, position: options?.position }),
      duration: options?.duration ?? defaultDuration[variant],
      ...definedProps({
        onDismiss: options?.onClose,
        onAutoClose: options?.onAutoClose,
      }),
    }
  );

  return toastId;
};

/**
 * A transfer card whose lifetime its owner drives: it stays until dismissed by
 * id, and `onClose` answers both its close control and a swipe away. Raising
 * the same id again updates the card in place.
 */
const showFileTransferToast = ({
  id,
  ...props
}: FileTransferToastProps & { id: string }) => {
  if (!toastsEnabled) return "";
  return sonnerToast(<FileTransferToast {...props} />, {
    className: "comma-sonner-file-transfer",
    duration: Number.POSITIVE_INFINITY,
    id,
    ...definedProps({ onDismiss: props.onClose }),
  });
};

/**
 * Imperative toast API backed by sonner. Mount `<Toaster />` once at the root of
 * every window that should show toasts; calls from a window without one are
 * inert by design (Side Chat and its child surfaces have no toast stack).
 */
export const toast = Object.assign(
  (title: string, options?: ToastOptions) => showCommaToast(title, options),
  {
    success: (title: string, options?: Omit<ToastOptions, "intent">) =>
      showCommaToast(title, { ...options, intent: "success" }),
    info: (title: string, options?: Omit<ToastOptions, "intent">) =>
      showCommaToast(title, { ...options, intent: "info" }),
    warning: (title: string, options?: Omit<ToastOptions, "intent">) =>
      showCommaToast(title, { ...options, intent: "warning" }),
    error: (title: string, options?: Omit<ToastOptions, "intent">) =>
      showCommaToast(title, { ...options, intent: "error" }),
    fileTransfer: showFileTransferToast,
    dismiss: (id?: string | number) => {
      if (!toastsEnabled) return id;
      return sonnerToast.dismiss(id);
    },
    dismissAll: () => {
      if (!toastsEnabled) return;
      sonnerToast.dismiss();
    },
  }
);
