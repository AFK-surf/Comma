import { useCall, useTopic, type CreditWarning } from "@comma/core-client";
import { useCallback, useEffect, useSyncExternalStore } from "react";
import { messages, type CommaLocale } from "@comma/i18n";
import { toast } from "@comma/ui/components/toast";
import {
  openUsageBillingSettings,
  OUT_OF_CREDITS_TOAST_ID,
  showOutOfCreditsToast,
} from "./outOfCredits";

export type { CreditWarning };

// The toast on screen: one per renderer, whichever chat surface showed it.
let presented: { workspace: string; warning: string } | undefined;
/** How many mounted surfaces watch each workspace. */
const watchers = new Map<string, number>();

function clearToast() {
  // Sonner also calls onClose when a toast is removed in code. Forget it first so a warning going away is not taken
  // for the person closing it.
  const was = presented;
  presented = undefined;
  if (was) toast.dismiss(OUT_OF_CREDITS_TOAST_ID);
}

function subscribeVisibility(listener: () => void) {
  document.addEventListener("visibilitychange", listener);
  return () => document.removeEventListener("visibilitychange", listener);
}
const pageVisible = () => document.visibilityState !== "hidden";

/**
 * Whether a workspace is low on credits (the core reads its balance once a minute while a visible page asks), and its
 * toast. A hidden page lets the topic go: after the UI's linger and the core's grace (about 90 s) it is no longer read.
 * Focus reads it again.
 */
export function useCreditWarning(workspaceId: string | undefined, active: boolean) {
  const call = useCall();
  const visible = useSyncExternalStore(subscribeVisibility, pageVisible, () => true);
  const watched = active && visible && workspaceId ? workspaceId : undefined;
  const { value } = useTopic(
    watched ? { topic: "creditWarning", workspace: watched } : null
  );
  const warning = watched ? (value ?? undefined) : undefined;

  useEffect(() => {
    if (!watched) return;
    const refresh = () => {
      if (pageVisible())
        void call("billing.refresh", { workspace: watched }).catch(() => undefined);
    };
    window.addEventListener("focus", refresh);
    return () => window.removeEventListener("focus", refresh);
  }, [call, watched]);

  const dismiss = useCallback(() => {
    if (workspaceId)
      void call("billing.dismissWarning", { workspace: workspaceId }).catch(
        () => undefined
      );
  }, [call, workspaceId]);

  const key = warning ? `${warning.threshold}:${warning.percent}` : undefined;
  useEffect(() => {
    if (!warning && presented?.workspace === workspaceId) clearToast();
  }, [key, warning, workspaceId]);

  const showToast = useCallback(
    (locale: CommaLocale) => {
      if (!warning || !workspaceId || !key) return;
      if (presented?.workspace === workspaceId && presented.warning === key) return;
      const shown = { workspace: workspaceId, warning: key };
      presented = shown;
      const onClose = () => {
        if (presented === shown) {
          presented = undefined;
          dismiss();
        }
      };
      if (warning.threshold === 0) {
        showOutOfCreditsToast(locale, onClose);
        return;
      }
      const notify = warning.threshold === 50 ? toast.info : toast.warning;
      notify(
        messages.billing_low_credits_title({ percent: warning.percent }, { locale }),
        {
          id: OUT_OF_CREDITS_TOAST_ID,
          testId: OUT_OF_CREDITS_TOAST_ID,
          icon: "gauge",
          description:
            warning.threshold === 50
              ? messages.billing_credits_reminder_detail(undefined, { locale })
              : messages.billing_low_credits_detail(undefined, { locale }),
          onClose,
          actions: [
            {
              label:
                warning.threshold === 50
                  ? messages.settings_usage_billing(undefined, { locale })
                  : messages.chat_add_credits(undefined, { locale }),
              onPress: () => {
                if (presented === shown) presented = undefined;
                dismiss();
                openUsageBillingSettings();
              },
            },
          ],
        }
      );
    },
    [dismiss, key, warning, workspaceId]
  );

  // The last surface showing the workspace went away: its toast goes too.
  useEffect(() => {
    if (!watched) return;
    watchers.set(watched, (watchers.get(watched) ?? 0) + 1);
    return () => {
      const left = (watchers.get(watched) ?? 1) - 1;
      if (left > 0) watchers.set(watched, left);
      else watchers.delete(watched);
      queueMicrotask(() => {
        if (!watchers.has(watched) && presented?.workspace === watched) clearToast();
      });
    };
  }, [watched]);

  return { warning, dismiss, showToast };
}
