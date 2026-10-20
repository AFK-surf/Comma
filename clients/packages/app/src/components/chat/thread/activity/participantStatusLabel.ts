import type { CommaLocale } from "@comma/i18n";
import type { useCommaMessages } from "@comma/i18n/react";
import {
  formatFundingReset,
  fundingSourceName,
  fundingStopKind,
} from "../../../billing/fundingStops";
import type {
  ChatParticipantIssueDetail,
  ChatParticipantStatus,
} from "@comma/core/chat";
import { formatConversationTimestamp } from "../layout/messageTimestamp";

type CommaMessages = ReturnType<typeof useCommaMessages>;

// Reason codes come from the agent runtime (SalixAgent.SessionActivity and
// its kernel). A code without wording reads as the generic line; its runtime
// text is never shown.
function issueLabel(
  messages: CommaMessages,
  issue: string | undefined,
  detail: ChatParticipantIssueDetail | undefined,
  locale: CommaLocale | undefined
): string {
  const provider = fundingSourceName(detail?.source);
  switch (issue) {
    case "model_connection_failed":
      return detail?.trigger === "background"
        ? messages.chat_issue_model_request_failed_background()
        : detail?.trigger === "voice_call"
          ? messages.chat_issue_model_request_failed_voice_call()
          : messages.chat_issue_model_request_failed();
    case "visible_reply_repair_exhausted":
      return messages.chat_issue_reply_unfinished();
    case "runaway_guard_parked":
      return messages.chat_issue_no_progress();
    case "repeated_tool_result_parked":
      return messages.chat_issue_repeating();
    case "input_round_budget_parked":
      return messages.chat_issue_too_many_steps();
    case "runtime_failed":
      return messages.chat_issue_failed();
    case "recovery_exhausted":
      return messages.chat_issue_recovery_failed();
    case "session_activity_unknown":
    case "runtime_status_unknown":
      return messages.chat_issue_status_unknown();
    case "native_start_unconfirmed":
      return messages.chat_issue_start_unconfirmed();
    case "runtime_observation_lost":
      return messages.chat_issue_connection_lost();
    case "quota_exhausted":
      return detail?.resetAt
        ? messages.chat_issue_usage_limit_reset({
            time: formatFundingReset(detail.resetAt, locale),
          })
        : messages.chat_issue_usage_limit();
    case "rate_limited":
      return messages.chat_issue_rate_limited();
    case "authentication_required":
      return messages.chat_issue_sign_in();
    case "model_unavailable":
      return messages.chat_issue_model_unavailable();
    case "insufficient_credits":
      return messages.chat_insufficient_credits();
    case "provider_quota_exhausted":
      if (fundingStopKind(issue, detail) === "subscription") {
        return messages.chat_issue_usage_limit();
      }
      if (provider && detail?.profileName) {
        return messages.chat_issue_provider_quota_named({
          profile: detail.profileName,
          provider,
        });
      }
      return provider
        ? messages.chat_issue_provider_quota_source({ provider })
        : messages.chat_issue_provider_quota();
    case "account_inactive":
      return messages.chat_billing_account_inactive();
    case "missing_account":
      return messages.chat_billing_account_missing();
    default:
      return messages.chat_issue_unknown();
  }
}

/**
 * Plain wording, in the reader's language, for a Participant's canonical
 * status. It comes from the state and the stable issue code: the runtime's
 * `status` text is English diagnosis, and waiting reasons in it are private.
 */
export function participantStatusLabel(
  messages: CommaMessages,
  participantStatus: ChatParticipantStatus,
  locale?: CommaLocale
): string | undefined {
  switch (participantStatus.state) {
    case "active":
      return messages.chat_activity_working();
    case "error": {
      const label = issueLabel(
        messages,
        participantStatus.issue,
        participantStatus.issueDetail,
        locale
      );
      // The line stays under the newest message until new input arrives, so a
      // failed model request says when it failed rather than reading as the
      // last reply failing.
      const failedAt =
        participantStatus.issue === "model_connection_failed" &&
        locale &&
        participantStatus.updatedAt > 0
          ? formatConversationTimestamp(participantStatus.updatedAt, locale)?.label
          : undefined;
      return failedAt ? `${failedAt} · ${label}` : label;
    }
    default:
      return undefined;
  }
}
