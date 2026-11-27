import { messages, type CommaLocale } from "@comma/i18n";
import { toast } from "@comma/ui/components/toast";
import type { BillingEntry } from "../../analytics/client";

export const OUT_OF_CREDITS_TOAST_ID = "out-of-credits";

/** Settings › Usage & billing, where credits are added. `from` names the notice that opened it. */
export function openUsageBillingSettings(from: BillingEntry) {
  window.location.hash = `/settings?${new URLSearchParams({ category: "usage-billing", from })}`;
}

/** Opens the Settings page that fixes a funding stop. */
export function openFundingSettings(
  category: "usage-billing" | "models",
  profile?: string
) {
  const query = new URLSearchParams({ category });
  if (category === "models" && profile) query.set("profile", profile);
  window.location.hash = `/settings?${query.toString()}`;
}

/**
 * The shared out-of-credits notice for chat and background work. Every refusal raises the
 * same id, so repeated attempts replace the toast instead of stacking it. The
 * action keeps it up until it is closed or the member leaves for billing.
 */
export function showOutOfCreditsToast(
  locale: CommaLocale,
  onClose?: () => void,
  copy?: { title?: string; description?: string }
) {
  return toast.error(
    copy?.title ?? messages.billing_out_of_credits_title(undefined, { locale }),
    {
      actions: [
        {
          label: messages.chat_add_credits(undefined, { locale }),
          onPress: () => {
            toast.dismiss(OUT_OF_CREDITS_TOAST_ID);
            onClose?.();
            openUsageBillingSettings("out_of_credits");
          },
        },
      ],
      description:
        copy?.description ??
        messages.billing_out_of_credits_detail(undefined, { locale }),
      icon: "gauge",
      id: OUT_OF_CREDITS_TOAST_ID,
      testId: OUT_OF_CREDITS_TOAST_ID,
      ...(onClose ? { onClose } : {}),
    }
  );
}
