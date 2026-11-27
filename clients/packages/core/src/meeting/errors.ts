// How a meeting submission's failure is worded and whether it is retried on its own. The words name the stage and a
// class of cause only: no response body, credential, host path or arbitrary exception message reaches a person.
import { CoreError, HostError } from "@comma/core-kernel";
import type { CommaLocale } from "@comma/i18n";
import * as messages from "@comma/i18n/messages";
import type { MeetingFailure } from "../host.ts";

export type MeetingSubmissionStage =
  | "journal"
  | "prepare"
  | "snapshot"
  | "register"
  | "submit"
  | "confirm";

/** Main could not do what the core asked, for the reason it named. */
export class MeetingPortFailure extends Error {
  readonly failure: MeetingFailure;

  constructor(failure: MeetingFailure) {
    super(
      failure.kind === "failed" && failure.reason
        ? failure.reason
        : `Meeting recorder: ${failure.kind}`
    );
    this.failure = failure;
  }
}

function billingReason(detail: unknown): string | undefined {
  if (typeof detail !== "object" || detail === null) return undefined;
  const reason = (detail as { reason?: unknown }).reason;
  return typeof reason === "string" ? reason : undefined;
}

export function meetingSubmissionError(
  stage: MeetingSubmissionStage,
  error: unknown,
  locale: CommaLocale = "en"
): string {
  let detail = "Unexpected failure. Retry this meeting.";
  if (error instanceof CoreError) {
    if (
      error.status === 402 ||
      error.code === "billing_unavailable" ||
      error.code === "budget_exhausted"
    ) {
      const reason = billingReason(error.detail);
      if (reason === "insufficient_credits" || error.code === "budget_exhausted")
        return messages.meeting_submission_insufficient_credits({}, { locale });
      if (reason === "account_inactive")
        return messages.meeting_submission_account_inactive({}, { locale });
      if (reason === "missing_account")
        return messages.meeting_submission_account_missing({}, { locale });
      return messages.meeting_submission_billing_unavailable({}, { locale });
    }
    if (error.status === 429 || error.code === "rate_limited")
      return messages.meeting_submission_rate_limited({}, { locale });
    if (error.status === 503)
      return messages.meeting_submission_service_unavailable({}, { locale });
    if (error.status !== undefined) detail = `HTTP ${error.status}.`;
    else if (error.code === "timeout" || error.code === "signed_out")
      detail = "The request timed out or the session changed.";
    else if (error.code === "network") detail = "The request could not complete.";
  } else if (error instanceof MeetingPortFailure) {
    const failure = error.failure;
    if (failure.kind === "registration")
      detail = failure.remediation
        ? "Reconnect the workspace's station."
        : failure.retryable
          ? "The station or file registration is temporarily unavailable."
          : "File registration was rejected or local confirmation failed.";
    else if (failure.kind === "snapshot")
      detail = `Local file error: ${failure.errorClass}.`;
    else if (failure.kind === "storage")
      detail = `Local storage error: ${failure.code}.`;
    else if (failure.kind === "session")
      detail = "The request timed out or the session changed.";
  } else if (error instanceof HostError && stage === "journal")
    detail = "Local storage error: the journal could not be written.";
  return `Meeting submission (${stage}): ${detail}`;
}

/** Only registration and submission are retried on their own, and only when a later try may succeed. */
export function canRetryMeetingSubmission(
  stage: MeetingSubmissionStage,
  error: unknown
): boolean {
  if (stage !== "register" && stage !== "submit") return false;
  if (error instanceof MeetingPortFailure)
    return error.failure.kind === "registration" && error.failure.retryable;
  if (error instanceof CoreError) {
    if (error.status !== undefined)
      return error.status === 408 || error.status === 429 || error.status >= 500;
    return error.code === "network" || error.code === "timeout";
  }
  return false;
}
