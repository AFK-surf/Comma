import type {
  CommaOperatingSystem,
  SystemNotificationsStatus,
} from "@comma/native-bridge";
import type { NotificationAuthorizationStatus } from "../../native/macos/NotificationAuthorization";

/**
 * The bundle id macOS knows this running app by, from the Info.plist of the
 * bundle around `executablePath`. A packaged Comma carries its release id; a
 * run from source is the Electron bundle ("com.github.Electron"), and macOS
 * lists its notifications under that id, so the Notifications pane has to
 * open on it. `fallback` when the bundle cannot be read.
 */
export function runningMacAppBundleId(
  executablePath: string,
  readText: (path: string) => string,
  fallback: string | undefined
) {
  // …/Name.app/Contents/MacOS/<executable> → …/Name.app/Contents/Info.plist
  const infoPlist = executablePath.replace(/\/MacOS\/[^/]+$/, "/Info.plist");
  if (infoPlist === executablePath) return fallback;
  try {
    const match = /<key>CFBundleIdentifier<\/key>\s*<string>([^<]+)<\/string>/.exec(
      readText(infoPlist)
    );
    return match?.[1]?.trim() || fallback;
  } catch {
    return fallback;
  }
}

const MACOS_NOTIFICATION_SETTINGS_URL =
  "x-apple.systempreferences:com.apple.Notifications-Settings.extension";
const WINDOWS_NOTIFICATION_SETTINGS_URL = "ms-settings:notifications";

/**
 * The readback a macOS authorization status gives Settings. Only a refusal
 * turns Comma's notifications off. An app macOS has not asked about yet is
 * `undetermined`: the prompt still comes, with the first banner or on request.
 * With nothing to ask through (an unbuilt addon, no bundle, a failed read) it
 * is `unknown`: Electron decides, as it does for the banners themselves, and
 * no surface may present it as allowed.
 */
export function systemNotificationsStatusFromAuthorization(
  status: NotificationAuthorizationStatus
): SystemNotificationsStatus {
  switch (status) {
    case "notDetermined":
      return "undetermined";
    case "denied":
      return "denied";
    case "authorized":
    case "provisional":
      return "available";
    case "unavailable":
      return "unknown";
  }
}

/**
 * Whether a banner Comma posts can reach the person: every readback but a
 * refusal or no notification support. `undetermined` prompts with the first
 * banner and `unknown` leaves the decision to Electron, as before the readback
 * told them apart from `available`. Nothing read back yet counts as no.
 */
export function systemNotificationsMayPost(
  status: SystemNotificationsStatus | undefined
) {
  return status !== undefined && status !== "denied" && status !== "unsupported";
}

export function systemNotificationSettingsUrl(
  os: CommaOperatingSystem,
  bundleId?: string
) {
  if (os === "macos") {
    if (!bundleId) return MACOS_NOTIFICATION_SETTINGS_URL;
    return `${MACOS_NOTIFICATION_SETTINGS_URL}?id=${encodeURIComponent(bundleId)}`;
  }
  if (os === "windows") return WINDOWS_NOTIFICATION_SETTINGS_URL;
  return undefined;
}

export async function openSystemNotificationSettings({
  bundleId,
  openExternalUrl,
  os,
}: {
  bundleId?: string;
  openExternalUrl: (url: string) => Promise<void>;
  os: CommaOperatingSystem;
}): Promise<{ opened: boolean }> {
  const url = systemNotificationSettingsUrl(os, bundleId);
  if (!url) return { opened: false };
  try {
    await openExternalUrl(url);
    return { opened: true };
  } catch {
    return { opened: false };
  }
}
