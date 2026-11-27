import { describe, expect, it, vi } from "vitest";

import type { LocationAuthorizationStatus } from "../../../native/macos/NotificationAuthorization";
import {
  authorizeSystemPermission,
  MACOS_LOCATION_SETTINGS_URL,
  systemPermissionStatus,
} from "../system-permission-authorization";

const settings = MACOS_LOCATION_SETTINGS_URL;

function macos(
  before: LocationAuthorizationStatus,
  answer: LocationAuthorizationStatus
) {
  const authorizer = {
    request: vi.fn(async () => answer),
    status: vi.fn(async () => before),
  };
  const openExternalUrl = vi.fn(async () => undefined);
  return {
    authorizer,
    openExternalUrl,
    run: () =>
      authorizeSystemPermission({ authorizer, openExternalUrl, settingsUrl: settings }),
  };
}

describe("authorizeSystemPermission", () => {
  it("answers a grant without asking or opening anything", async () => {
    const mac = macos("authorized", "authorized");
    await expect(mac.run()).resolves.toBe("authorized");
    expect(mac.authorizer.request).not.toHaveBeenCalled();
    expect(mac.openExternalUrl).not.toHaveBeenCalled();
  });

  it("prompts while undecided and takes the person's answer", async () => {
    const yes = macos("notDetermined", "authorized");
    await expect(yes.run()).resolves.toBe("authorized");
    expect(yes.authorizer.request).toHaveBeenCalledOnce();

    // They have just said no in the prompt: no System Settings on top of it.
    const no = macos("notDetermined", "denied");
    await expect(no.run()).resolves.toBe("denied");
    expect(no.openExternalUrl).not.toHaveBeenCalled();
  });

  it.each(["denied", "restricted", "servicesOff"] as const)(
    "opens the resource's System Settings pane when macOS will not ask again (%s)",
    async (status) => {
      const mac = macos(status, status);
      await expect(mac.run()).resolves.toBe("denied");
      expect(mac.authorizer.request).not.toHaveBeenCalled();
      expect(mac.openExternalUrl).toHaveBeenCalledWith(settings);
    }
  );

  it("leaves the decision to the read when there is nothing to ask through", async () => {
    const openExternalUrl = vi.fn(async () => undefined);
    await expect(
      authorizeSystemPermission({
        authorizer: undefined,
        openExternalUrl,
        settingsUrl: settings,
      })
    ).resolves.toBe("unknown");
    // A build macOS would not ask for, or an app not in use, stays undecided.
    const undecided = macos("notDetermined", "notDetermined");
    await expect(undecided.run()).resolves.toBe("unknown");
    const unavailable = macos("unavailable", "unavailable");
    await expect(unavailable.run()).resolves.toBe("unknown");
    expect(openExternalUrl).not.toHaveBeenCalled();
  });

  it("reads back what Settings shows: off for Comma or the whole Mac is denied", () => {
    expect(systemPermissionStatus("authorized")).toBe("authorized");
    expect(systemPermissionStatus("notDetermined")).toBe("notDetermined");
    for (const status of ["denied", "restricted", "servicesOff"] as const) {
      expect(systemPermissionStatus(status)).toBe("denied");
    }
    expect(systemPermissionStatus("unavailable")).toBe("unknown");
    expect(systemPermissionStatus(undefined)).toBe("unknown");
  });
});
