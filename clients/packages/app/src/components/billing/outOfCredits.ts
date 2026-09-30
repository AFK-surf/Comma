import { messages, type CommaLocale } from "@comma/i18n";
import { toast } from "@comma/ui";

export const OUT_OF_CREDITS_TOAST_ID = "out-of-credits";

/** Settings › Usage & billing, where credits are added. */
export function openUsageBillingSettings() {
  window.location.hash = "/settings?category=usage-billing";
}

/**
 * The out-of-credits notice for a surface with no chat thread to hold the
 * card: the card's words and its one way forward. Every refusal raises the
 * same id, so repeated attempts replace the toast instead of stacking it. The
 * action keeps it up until it is closed or the member leaves for billing.
 */
export function showOutOfCreditsToast(locale: CommaLocale) {
  return toast.error(messages.billing_out_of_credits_title(undefined, { locale }), {
    actions: [
      {
        label: messages.chat_add_credits(undefined, { locale }),
        onPress: () => {
          toast.dismiss(OUT_OF_CREDITS_TOAST_ID);
          openUsageBillingSettings();
        },
      },
    ],
    description: messages.billing_out_of_credits_detail(undefined, { locale }),
    icon: "gauge",
    id: OUT_OF_CREDITS_TOAST_ID,
    testId: OUT_OF_CREDITS_TOAST_ID,
  });
}
