/** Why a screen could not be shown, in the terms a person can act on. */
export type ScreenFailureKind =
  | "unreachable"
  | "refused"
  | "app-gone"
  | "unsupported"
  | "other";

const UNREACHABLE = new Set([
  "upstream_unavailable",
  "unreachable",
  "disconnected",
  "unavailable",
]);
const REFUSED = new Set(["forbidden", "unauthorized", "screen_refused"]);
/** This page cannot decode a screen at all (no WebCodecs): nothing to try again. */
export const SCREEN_DECODER_UNSUPPORTED = "decoder_unsupported";

export function screenFailureKind(failure: string | undefined): ScreenFailureKind {
  if (failure === undefined) return "other";
  if (UNREACHABLE.has(failure)) return "unreachable";
  if (REFUSED.has(failure)) return "refused";
  if (failure === SCREEN_DECODER_UNSUPPORTED) return "unsupported";
  return /App was not found/i.test(failure) ? "app-gone" : "other";
}

/** What a locked Mac says is frontmost: no app a person picked, and nothing to drive. */
export const screenIsLocked = (apps: readonly string[] | undefined) =>
  apps?.includes("loginwindow") === true;

/** A bare code means nothing to a person: with no message for it, nothing is said beyond that it failed. */
export function screenFailureDetail(
  failure: string | undefined,
  messages: {
    remote_screen_failure_unreachable(): string;
    remote_screen_failure_refused(): string;
    remote_screen_failure_app_gone(): string;
    remote_screen_failure_unsupported(): string;
  }
): string | undefined {
  switch (screenFailureKind(failure)) {
    case "unreachable":
      return messages.remote_screen_failure_unreachable();
    case "refused":
      return messages.remote_screen_failure_refused();
    case "app-gone":
      return messages.remote_screen_failure_app_gone();
    case "unsupported":
      return messages.remote_screen_failure_unsupported();
    default:
      return failure && /^[a-z0-9_.-]+$/.test(failure) ? undefined : failure;
  }
}

/**
 * Why the computer did not let a view drive, from the station's own words (systems/station/src/mesh/screens.ts
 * `refusedControl`): those are not a person's to read, and any other says only that it was not allowed.
 */
export function screenControlRefusal(
  why: string,
  messages: {
    remote_screen_control_refused(): string;
    remote_screen_control_refused_read_only(): string;
    remote_screen_control_refused_access(): string;
  }
): string {
  if (/may drive this computer/i.test(why))
    return messages.remote_screen_control_refused_read_only();
  if (/access is not Full/i.test(why))
    return messages.remote_screen_control_refused_access();
  return messages.remote_screen_control_refused();
}

/** A refusal stands until something changes, and an app that went is not back by itself: neither is tried again unasked. */
export const screenFailureRetries = (...said: readonly (string | undefined)[]) =>
  said.every((one) => {
    const kind = screenFailureKind(one);
    return kind === "unreachable" || kind === "other";
  });
