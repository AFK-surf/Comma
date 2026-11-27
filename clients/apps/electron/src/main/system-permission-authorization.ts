import type {
  SystemLocationAuthorization,
  SystemPermissionStatus,
} from "@comma/native-bridge";
import type { LocationAuthorizationStatus } from "../../native/macos/NotificationAuthorization";

export const MACOS_LOCATION_SETTINGS_URL =
  "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices";
export const MACOS_MICROPHONE_SETTINGS_URL =
  "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone";

/**
 * macOS: one privacy-protected resource of Comma's (location, the microphone),
 * read and requested in Comma's own process. Its answers use the location
 * addon's vocabulary; `servicesOff` is location's alone.
 */
export interface SystemPermissionAuthorizer {
  status(): Promise<LocationAuthorizationStatus>;
  request(): Promise<LocationAuthorizationStatus>;
}

const off = new Set<LocationAuthorizationStatus>([
  "denied",
  "restricted",
  "servicesOff",
]);

/** What Settings shows for a resource: the readback in the snapshot's terms. */
export function systemPermissionStatus(
  status: LocationAuthorizationStatus | undefined
): SystemPermissionStatus {
  if (status === "authorized") return "authorized";
  if (status === "notDetermined") return "notDetermined";
  if (status !== undefined && off.has(status)) return "denied";
  return "unknown";
}

/**
 * Asks macOS to let Comma use a resource before a window uses it. Without the
 * grant Chromium neither prompts nor refuses a position read: it only times
 * out, so the window could not tell a refusal from a slow fix.
 *
 * - Undecided: macOS prompts and this answers with the person's choice. A
 *   refusal there is only `denied`: they have just said no.
 * - Already off for Comma (or, for location, for the whole Mac): macOS never
 *   asks again, so this opens the resource's System Settings pane and answers
 *   `denied`.
 * - `unknown` (other systems, no addon, a build macOS would not ask for, or an
 *   app not in use): the read itself decides, as before.
 */
export async function authorizeSystemPermission({
  authorizer,
  openExternalUrl,
  settingsUrl,
}: {
  authorizer: SystemPermissionAuthorizer | undefined;
  openExternalUrl: (url: string) => Promise<void>;
  settingsUrl: string;
}): Promise<SystemLocationAuthorization> {
  if (!authorizer) return "unknown";
  const before = await authorizer.status();
  if (before === "authorized") return "authorized";
  if (off.has(before)) {
    await openExternalUrl(settingsUrl).catch(() => undefined);
    return "denied";
  }
  if (before !== "notDetermined") return "unknown";
  const answer = await authorizer.request();
  if (answer === "authorized") return "authorized";
  return off.has(answer) ? "denied" : "unknown";
}
