import { useEffect, useState, type ReactNode } from "react";
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
  /** In place of the status icon: whom the toast is about, as their 20px avatar. */
  leading?: ReactNode;
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

// Tracks the latest live publication per toast id. Sonner inserts a created
// toast asynchronously on a macrotask while applying `dismiss(id)` across
// animation frames without re-checking `dismissedToasts` on insert: if the
// dismissal lands first (e.g. after background throttling), an indefinite
// toast would otherwise stay mounted forever.
let nextToastToken = 0;
const liveToastTokens = new Map<string | number, number>();

const isLiveToast = (id: string | number, token: number) =>
  id === "" || liveToastTokens.get(id) === token;

function GuardedToastContent({
  children,
  getId,
  token,
}: {
  children: ReactNode;
  getId: () => string | number;
  token: number;
}) {
  const id = getId();
  // Decided once per publication, when sonner mounts (or swaps in) this
  // content: a later re-render after the toast retires, e.g. during its exit
  // animation, must not blank it.
  const [decision, setDecision] = useState(() => ({
    id,
    token,
    isLive: isLiveToast(id, token),
  }));
  let isLive = decision.isLive;
  if (decision.id !== id || decision.token !== token) {
    isLive = isLiveToast(id, token);
    setDecision({ id, token, isLive });
  }

  useEffect(() => {
    if (isLive || id === "") return;
    // Only dismiss when the id is genuinely retired (not replaced by a newer token).
    if (!liveToastTokens.has(id)) {
      sonnerToast.dismiss(id);
    }
  }, [id, isLive, token]);

  return isLive ? children : null;
}

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
  const token = ++nextToastToken;
  const onClose = options?.onClose;
  const onAutoClose = options?.onAutoClose;

  let toastId: string | number = options?.id ?? "";
  if (toastId !== "") liveToastTokens.set(toastId, token);

  const retireToken = () => {
    if (toastId !== "" && liveToastTokens.get(toastId) === token) {
      liveToastTokens.delete(toastId);
    }
  };

  toastId = sonnerToast(
    <GuardedToastContent getId={() => toastId} token={token}>
      <Toast
        title={title}
        variant={variant}
        intent={intent}
        {...definedProps({
          description: options?.description,
          icon: options?.icon,
          leading: options?.leading,
          actions: options?.actions,
          testId: options?.testId,
        })}
        onClose={() => {
          retireToken();
          sonnerToast.dismiss(toastId);
          onClose?.();
        }}
      />
    </GuardedToastContent>,
    {
      ...definedProps({ id: options?.id, position: options?.position }),
      duration: options?.duration ?? defaultDuration[variant],
      onDismiss: () => {
        retireToken();
        onClose?.();
      },
      onAutoClose: () => {
        retireToken();
        onAutoClose?.();
      },
    }
  );

  if (toastId !== "") liveToastTokens.set(toastId, token);
  return toastId;
};

/**
 * A transfer card whose lifetime its owner drives: it stays until dismissed by
 * id, and `onClose` answers both its close control and a swipe away. Raising
 * the same id again updates the card in place.
 */
const showFileTransferToast = ({
  id,
  onClose,
  ...props
}: FileTransferToastProps & { id: string }) => {
  if (!toastsEnabled) return "";
  const token = ++nextToastToken;
  liveToastTokens.set(id, token);
  const retireToken = () => {
    if (liveToastTokens.get(id) === token) {
      liveToastTokens.delete(id);
    }
  };
  return sonnerToast(
    <GuardedToastContent getId={() => id} token={token}>
      <FileTransferToast {...props} {...definedProps({ onClose })} />
    </GuardedToastContent>,
    {
      className: "comma-sonner-file-transfer",
      duration: Number.POSITIVE_INFINITY,
      id,
      onDismiss: () => {
        retireToken();
        onClose?.();
      },
    }
  );
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
      if (id === undefined) liveToastTokens.clear();
      else liveToastTokens.delete(id);
      return sonnerToast.dismiss(id);
    },
    dismissAll: () => {
      if (!toastsEnabled) return;
      liveToastTokens.clear();
      sonnerToast.dismiss();
    },
  }
);
