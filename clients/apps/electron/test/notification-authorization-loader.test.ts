import { resolve } from "node:path";

import { describe, expect, it, vi } from "vitest";

import {
  loadNotificationAuthorizationAddon,
  notificationAuthorizationAddonFileName,
  notificationAuthorizationCandidateBinaryPaths,
} from "../native/macos/NotificationAuthorization";

describe("notification authorization addon candidate paths", () => {
  const cwd = "/untrusted/development-checkout";
  const environmentPath = "/untrusted/environment/authorization.node";
  const explicitPath = "/trusted/explicit/authorization.node";
  const resourcesPath = "/Applications/Comma.app/Contents/Resources";
  const packagedResourcePath = resolve(
    resourcesPath,
    "native/macos",
    notificationAuthorizationAddonFileName
  );

  it("treats an explicit path as an exclusive override", () => {
    expect(
      notificationAuthorizationCandidateBinaryPaths({
        cwd,
        environmentPath,
        explicitPath,
        isPackaged: true,
        resourcesPath,
      })
    ).toEqual([explicitPath]);
  });

  it("only looks inside the bundle when packaged", () => {
    const candidates = notificationAuthorizationCandidateBinaryPaths({
      cwd,
      environmentPath,
      isPackaged: true,
      resourcesPath,
    });

    expect(candidates).toEqual([packagedResourcePath]);
  });

  it("treats the development environment path as an exclusive override", () => {
    expect(
      notificationAuthorizationCandidateBinaryPaths({
        cwd,
        environmentPath,
        isPackaged: false,
        resourcesPath,
      })
    ).toEqual([environmentPath]);
  });

  it("keeps the dist and node-gyp outputs discoverable in development", () => {
    const candidates = notificationAuthorizationCandidateBinaryPaths({
      cwd,
      environmentPath: "",
      isPackaged: false,
      resourcesPath,
    });

    expect(candidates[0]).toBe(packagedResourcePath);
    expect(candidates).toContain(
      resolve(cwd, "dist/native/macos", notificationAuthorizationAddonFileName)
    );
    expect(candidates).toContain(
      resolve(
        cwd,
        "clients/apps/electron/native/macos/NotificationAuthorization/build/Release/comma_notification_authorization.node"
      )
    );
  });
});

describe("loadNotificationAuthorizationAddon", () => {
  it("answers from a loaded addon", async () => {
    const addon = loadNotificationAuthorizationAddon({
      binaryPath: resolve(
        process.cwd(),
        "apps/electron/test/fixtures/notification-authorization-denied.cjs"
      ),
      platform: "darwin",
    });

    expect(addon.loaded).toBe(true);
    await expect(addon.authorizationStatus()).resolves.toBe("denied");
    await expect(addon.requestAuthorization()).resolves.toBe("denied");
    await expect(addon.setBadgeCount(3)).resolves.toBe("cleared");
  });

  it("rejects an addon built before it could request authorization", async () => {
    const logger = { warn: vi.fn() };
    const addon = loadNotificationAuthorizationAddon({
      binaryPath: resolve(
        process.cwd(),
        "apps/electron/test/fixtures/notification-authorization-status-only.cjs"
      ),
      logger,
      platform: "darwin",
    });

    // A stale dist binary must fail loudly, not answer half the contract.
    expect(addon.loaded).toBe(false);
    expect(addon.loadError?.message).toContain("has an invalid API");
    await expect(addon.requestAuthorization()).resolves.toBe("unavailable");
  });

  it("rejects an addon that cannot report authorization", async () => {
    const logger = { warn: vi.fn() };
    const addon = loadNotificationAuthorizationAddon({
      binaryPath: resolve(
        process.cwd(),
        "apps/electron/test/fixtures/notification-authorization-missing-api.cjs"
      ),
      logger,
      platform: "darwin",
    });

    expect(addon.loaded).toBe(false);
    expect(addon.loadError?.message).toContain("has an invalid API");
    expect(logger.warn).toHaveBeenCalled();
    await expect(addon.authorizationStatus()).resolves.toBe("unavailable");
  });

  it("is unavailable off macOS without touching the filesystem", async () => {
    const addon = loadNotificationAuthorizationAddon({ platform: "win32" });

    expect(addon.loaded).toBe(false);
    await expect(addon.authorizationStatus()).resolves.toBe("unavailable");
    await expect(addon.requestAuthorization()).resolves.toBe("unavailable");
  });
});
