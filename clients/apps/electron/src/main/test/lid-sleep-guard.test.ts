import { describe, expect, it, vi } from "vitest";
import type {
  SleepGuardAddon,
  SleepGuardDaemonStatus,
} from "../../../native/macos/SleepGuard";
import { LidSleepGuard } from "../lid-sleep-guard";

function fakeAddon(
  status: SleepGuardDaemonStatus,
  registered: { status: SleepGuardDaemonStatus; error?: string } = { status }
) {
  return {
    status: vi.fn((_plistName: string) => status),
    register: vi.fn((_plistName: string) => registered),
    openLoginItemsSettings: vi.fn(),
    setSleepDisabled: vi.fn(
      async (
        _serviceName: string,
        _disabled: boolean
      ): Promise<{ ok: boolean; error?: string }> => ({ ok: true })
    ),
  } satisfies SleepGuardAddon;
}

describe("LidSleepGuard", () => {
  it("holds and releases the flag through the approved daemon of this app flavor", async () => {
    const addon = fakeAddon("enabled");
    const guard = new LidSleepGuard({ addon, appBundleId: "surf.comma.dev" });

    await expect(guard.set(true)).resolves.toBe("available");
    await expect(guard.set(false)).resolves.toBe("available");

    expect(addon.register).not.toHaveBeenCalled();
    expect(addon.status).toHaveBeenCalledWith("surf.comma.dev.sleep-guard.plist");
    expect(addon.setSleepDisabled.mock.calls).toEqual([
      ["surf.comma.dev.sleep-guard", true],
      ["surf.comma.dev.sleep-guard", false],
    ]);
  });

  // macOS reports a daemon it never registered as notFound as well.
  it.each(["notRegistered", "notFound"] as const)(
    "registers a %s daemon on first use and reports the approval it waits for",
    async (unregistered) => {
      const addon = fakeAddon(unregistered, { status: "requiresApproval" });
      const guard = new LidSleepGuard({ addon, appBundleId: "surf.comma" });

      expect(guard.status()).toBe("not-registered");
      await expect(guard.set(true)).resolves.toBe("requires-approval");
      expect(addon.register).toHaveBeenCalledWith("surf.comma.sleep-guard.plist");
      // Settings explains the approval; Main does not open System Settings itself.
      expect(addon.openLoginItemsSettings).not.toHaveBeenCalled();
      expect(addon.setSleepDisabled).not.toHaveBeenCalled();
    }
  );

  it("reports why macOS refused to register the daemon", async () => {
    const addon = fakeAddon("notFound", {
      status: "notFound",
      error: "Operation not permitted",
    });
    await expect(
      new LidSleepGuard({ addon, appBundleId: "surf.comma" }).set(true)
    ).rejects.toMatchObject({
      reason: "unavailable",
      message: "macOS did not register the sleep guard: Operation not permitted",
    });
  });

  it("resumes at launch only an approved daemon and never registers one", async () => {
    const revoked = fakeAddon("requiresApproval");
    await expect(
      new LidSleepGuard({ addon: revoked, appBundleId: "surf.comma" }).set(true, {
        atLaunch: true,
      })
    ).resolves.toBe("requires-approval");
    expect(revoked.setSleepDisabled).not.toHaveBeenCalled();

    const unregistered = fakeAddon("notFound");
    await expect(
      new LidSleepGuard({ addon: unregistered, appBundleId: "surf.comma" }).set(true, {
        atLaunch: true,
      })
    ).resolves.toBe("not-registered");
    expect(unregistered.register).not.toHaveBeenCalled();
    expect(unregistered.setSleepDisabled).not.toHaveBeenCalled();
  });

  it("opens Login Items on request", () => {
    const addon = fakeAddon("requiresApproval");
    expect(
      new LidSleepGuard({ addon, appBundleId: "surf.comma" }).openLoginItemsSettings()
    ).toEqual({ opened: true });
    expect(addon.openLoginItemsSettings).toHaveBeenCalledOnce();
  });

  it("reports a refused request and a build without the guard", async () => {
    const addon = fakeAddon("enabled");
    addon.setSleepDisabled.mockResolvedValueOnce({
      ok: false,
      error: "pmset exited with 1",
    });
    await expect(
      new LidSleepGuard({ addon, appBundleId: "surf.comma" }).set(true)
    ).rejects.toMatchObject({ reason: "failed", message: "pmset exited with 1" });

    const missing = new LidSleepGuard({ addon: undefined, appBundleId: "surf.comma" });
    expect(missing.status()).toBe("unavailable");
    await expect(missing.set(true)).rejects.toMatchObject({ reason: "unavailable" });
    await expect(missing.set(false)).resolves.toBe("unavailable");
    expect(missing.openLoginItemsSettings()).toEqual({ opened: false });
  });
});
