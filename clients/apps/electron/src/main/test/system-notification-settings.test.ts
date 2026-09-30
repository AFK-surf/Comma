import { describe, expect, it, vi } from "vitest";
import {
  openSystemNotificationSettings,
  systemNotificationSettingsUrl,
} from "../system-notification-settings";

describe("system notification settings", () => {
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
