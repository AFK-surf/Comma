import type { CommaOperatingSystem } from "@comma/native-bridge";

const MACOS_NOTIFICATION_SETTINGS_URL =
  "x-apple.systempreferences:com.apple.Notifications-Settings.extension";
const WINDOWS_NOTIFICATION_SETTINGS_URL = "ms-settings:notifications";

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
