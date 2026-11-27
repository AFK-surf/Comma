import type { useCommaMessages } from "@comma/i18n/react";

type Messages = ReturnType<typeof useCommaMessages>;

export type BillingFailureReason =
  | "insufficient_credits"
  | "account_inactive"
  | "missing_account"
  | "sandbox_restricted"
  | "billing_unavailable";

/** Extracts an allowlisted billing refusal reason from a core RPC error, or undefined if not a billing refusal. */
export function billingFailureReason(
  failure: unknown
): BillingFailureReason | undefined {
  const err = (failure ?? {}) as {
    status?: unknown;
    code?: unknown;
    detail?: unknown;
  };
  const isBilling =
    err.status === 402 ||
    err.code === "billing_unavailable" ||
    err.code === "budget_exhausted";
  if (!isBilling) return undefined;
  if (err.code === "budget_exhausted") return "insufficient_credits";
  const reason =
    typeof err.detail === "object" && err.detail !== null
      ? (err.detail as { reason?: unknown }).reason
      : undefined;
  switch (reason) {
    case "insufficient_credits":
    case "account_inactive":
    case "missing_account":
    case "sandbox_restricted":
      return reason;
    default:
      return "billing_unavailable";
  }
}

/** Localized refusal copy when creating a cloud/station or sandbox task fails due to billing. */
export function taskCreateBillingFailure(
  failure: unknown,
  m: Messages,
  kind: "task" | "sandbox"
): string | undefined {
  const reason = billingFailureReason(failure);
  if (!reason) return undefined;
  if (kind === "sandbox") {
    switch (reason) {
      case "insufficient_credits":
        return m.sandbox_task_create_insufficient_credits();
      case "sandbox_restricted":
        return m.sandbox_task_create_restricted();
      case "account_inactive":
        return m.sandbox_task_create_account_inactive();
      case "missing_account":
        return m.sandbox_task_create_account_missing();
      default:
        return m.sandbox_task_create_billing_unavailable();
    }
  }
  switch (reason) {
    case "insufficient_credits":
      return m.station_task_create_insufficient_credits();
    case "sandbox_restricted":
      return m.sandbox_task_create_restricted();
    case "account_inactive":
      return m.station_task_create_account_inactive();
    case "missing_account":
      return m.station_task_create_account_missing();
    default:
      return m.station_task_create_billing_unavailable();
  }
}

/** Localized refusal copy when accepting a Task Request fails due to billing. */
export function taskRequestAcceptBillingFailure(
  failure: unknown,
  m: Messages
): string | undefined {
  const reason = billingFailureReason(failure);
  if (!reason) return undefined;
  switch (reason) {
    case "insufficient_credits":
      return m.task_requests_accept_insufficient_credits();
    case "account_inactive":
      return m.task_requests_accept_account_inactive();
    case "missing_account":
      return m.task_requests_accept_account_missing();
    case "sandbox_restricted":
      return m.task_requests_accept_sandbox_restricted();
    default:
      return m.task_requests_accept_billing_unavailable();
  }
}
