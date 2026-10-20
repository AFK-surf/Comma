// How a meeting submission's failure is worded and whether it is retried on its own. The words name the stage and a
// class of cause only: no response body, credential, host path or arbitrary exception message reaches a person.
import { CoreError, HostError } from "@comma/core-kernel";
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

export function meetingSubmissionError(
  stage: MeetingSubmissionStage,
  error: unknown
): string {
  let detail = "Unexpected failure. Retry this meeting.";
  if (error instanceof CoreError) {
    if (error.status !== undefined) detail = `HTTP ${error.status}.`;
    else if (error.code === "timeout" || error.code === "signed_out")
      detail = "The request timed out or the session changed.";
    else if (error.code === "network") detail = "The request could not complete.";
  } else if (error instanceof MeetingPortFailure) {
    const failure = error.failure;
    if (failure.kind === "registration")
      detail = failure.remediation
        ? "Reconnect the workspace Connector."
        : failure.retryable
          ? "The Connector or file registration is temporarily unavailable."
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
