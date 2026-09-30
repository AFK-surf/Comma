import { CommaApiError } from "@comma/app/api";
import { LocalFileRouteRegistrationError } from "../local-files/registration";
import { LocalFileSnapshotError } from "../local-files/snapshot-store";

export type MeetingSubmissionStage =
  | "journal"
  | "prepare"
  | "snapshot"
  | "register"
  | "submit"
  | "confirm";

export function meetingSubmissionError(stage: MeetingSubmissionStage, error: unknown) {
  // Do not expose response bodies, credentials, host paths, or arbitrary exception messages.
  let detail = "Unexpected failure. Retry this meeting.";
  if (error instanceof CommaApiError) detail = `HTTP ${error.status}.`;
  else if (error instanceof LocalFileRouteRegistrationError)
    detail = error.remediation
      ? "Reconnect the workspace Connector."
      : error.retryable
        ? "The Connector or file registration is temporarily unavailable."
        : "File registration was rejected or local confirmation failed.";
  else if (error instanceof LocalFileSnapshotError)
    detail = `Local file error: ${error.errorClass}.`;
  else if (
    error instanceof Error &&
    ["TimeoutError", "AbortError"].includes(error.name)
  )
    detail = "The request timed out or the session changed.";
  else if (error instanceof TypeError) detail = "The request could not complete.";
  else if (
    error &&
    typeof error === "object" &&
    "code" in error &&
    ["ENOSPC", "EACCES", "EPERM", "EIO", "ENOENT"].includes(String(error.code))
  )
    detail = `Local storage error: ${String(error.code)}.`;
  return `Meeting submission (${stage}): ${detail}`;
}

export function canRetryMeetingSubmission(
  stage: MeetingSubmissionStage,
  error: unknown
) {
  if (stage !== "register" && stage !== "submit") return false;
  if (error instanceof LocalFileRouteRegistrationError) return error.retryable;
  if (error instanceof CommaApiError)
    return error.status === 408 || error.status === 429 || error.status >= 500;
  return (
    error instanceof TypeError ||
    (error instanceof Error && error.name === "TimeoutError")
  );
}
