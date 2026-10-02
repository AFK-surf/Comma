import { describe, expect, it, vi } from "vitest";
import {
  openSystemNotificationSettings,
  systemNotificationSettingsUrl,
  runningMacAppBundleId,
  systemNotificationsMayPost,
  systemNotificationsStatusFromAuthorization,
} from "../system-notification-settings";

/** An Info.plist naming `id` as the bundle's identifier. */
const plist = (id: string) =>
  `<dict><key>CFBundleName</key><string>x</string><key>CFBundleIdentifier</key>\n  <string>${id}</string></dict>`;

describe("system notification settings", () => {
  it("opens the Notifications pane on the bundle macOS knows the running app by", () => {
    const reads: string[] = [];
    // A run from source is the Electron bundle; macOS lists its notifications there.
    expect(
      runningMacAppBundleId(
        "/x/Electron.app/Contents/MacOS/Electron",
        (path) => (reads.push(path), plist("com.github.Electron")),
        "surf.comma.desktop.dev"
      )
    ).toBe("com.github.Electron");
    expect(reads).toEqual(["/x/Electron.app/Contents/Info.plist"]);
    // An unreadable bundle keeps the release id.
    expect(
      runningMacAppBundleId(
        "/x/Comma.app/Contents/MacOS/Comma",
        () => {
          throw new Error("missing");
        },
        "surf.comma.desktop"
      )
    ).toBe("surf.comma.desktop");
  });

  it("tells a macOS that has not asked about Comma yet apart from one that allows or refuses it", () => {
    expect(systemNotificationsStatusFromAuthorization("notDetermined")).toBe(
      "undetermined"
    );
    expect(systemNotificationsStatusFromAuthorization("denied")).toBe("denied");
    expect(systemNotificationsStatusFromAuthorization("authorized")).toBe("available");
    expect(systemNotificationsStatusFromAuthorization("provisional")).toBe("available");
    // Nothing to ask through (an unbuilt addon, no bundle, a failed read):
    // Electron decides, and nothing may claim the user allowed it.
    expect(systemNotificationsStatusFromAuthorization("unavailable")).toBe("unknown");
  });

  it("lets a banner go out unless macOS refused it or notifications are unsupported", () => {
    // Router reminders stay in Comma for a user macOS has not asked yet (the
    // first banner prompts) and when the authorization could not be read.
    expect(systemNotificationsMayPost("available")).toBe(true);
    expect(systemNotificationsMayPost("undetermined")).toBe(true);
    expect(systemNotificationsMayPost("unknown")).toBe(true);
    expect(systemNotificationsMayPost("denied")).toBe(false);
    expect(systemNotificationsMayPost("unsupported")).toBe(false);
    expect(systemNotificationsMayPost(undefined)).toBe(false);
  });

  it("opens the macOS Notifications pane, and Comma's row when a bundle id is known", () => {
    expect(systemNotificationSettingsUrl("macos")).toBe(
      "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
    );
    expect(systemNotificationSettingsUrl("macos", "surf.comma.desktop")).toBe(
      "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=surf.comma.desktop"
    );
    expect(systemNotificationSettingsUrl("windows")).toBe("ms-settings:notifications");
    expect(systemNotificationSettingsUrl("linux")).toBeUndefined();
  });

  it("reports whether System Settings opened", async () => {
    const openExternalUrl = vi.fn(async () => undefined);
    await expect(
      openSystemNotificationSettings({
        bundleId: "surf.comma.desktop",
        openExternalUrl,
        os: "macos",
      })
    ).resolves.toEqual({ opened: true });
    expect(openExternalUrl).toHaveBeenCalledWith(
      "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=surf.comma.desktop"
    );

    await expect(
      openSystemNotificationSettings({
        openExternalUrl,
        os: "linux",
      })
    ).resolves.toEqual({ opened: false });

    await expect(
      openSystemNotificationSettings({
        openExternalUrl: async () => {
          throw new Error("blocked");
        },
        os: "windows",
      })
    ).resolves.toEqual({ opened: false });
  });
});
