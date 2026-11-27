import type { useCommaMessages } from "@comma/i18n/react";
import { billingFailureReason } from "../billing/billingError";

/** Why a Task together did not start, in words: never a server's code. */
export function startFailure(
  failure: unknown,
  m: ReturnType<typeof useCommaMessages>
): string {
  const { status, code } = (failure ?? {}) as { status?: number; code?: string };
  if (code === "invite_daily_limit_reached")
    return m.people_start_failed_invite_daily_limit();
  const billing = billingFailureReason(failure);
  if (billing) {
    switch (billing) {
      case "insufficient_credits":
        return m.people_start_failed_credits();
      case "account_inactive":
        return m.people_start_failed_account_inactive();
      case "missing_account":
        return m.people_start_failed_account_missing();
      default:
        return m.people_start_failed_billing_unavailable();
    }
  }
  if (status === 409 || code === "conflict") return m.people_start_failed_started();
  if (status === 400) return m.people_start_failed_input();
  return m.people_start_failed();
}
