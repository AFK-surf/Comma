import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import {
  defaultAppPreferences,
  defaultCommaClientSettings,
  type KeepAwakeWhenLidClosedStatus,
  type SystemNotificationsStatus,
} from "@comma/native-bridge";
import { AppPreferencesService } from "../app-preferences";
import type { LaunchAtLoginReadback } from "../launch-at-login";

const temporaryDirectories: string[] = [];

afterEach(async () => {
  await Promise.all(
    temporaryDirectories.splice(0).map((path) => rm(path, { recursive: true }))
  );
});

describe("AppPreferencesService", () => {
  it("loads Meeting defaults from legacy settings and persists each independent preference", async () => {
    const filePath = await temporaryPreferencesPath();
    const {
      meetingStartRecording: _start,
      meetingHideRecorder: _hide,
      meetingSmartSummary: _summary,
      ...legacy
    } = defaultCommaClientSettings;
    const service = await AppPreferencesService.open({
      filePath,
      platform: createPlatform(),
    });
    await service.update({ clientSettings: legacy });
    expect(service.state().clientSettings).toMatchObject({
      meetingStartRecording: "reminder",
      meetingHideRecorder: false,
      meetingSmartSummary: true,
    });
    await service.update({ clientSettings: { meetingStartRecording: "auto" } });
    await service.update({
      clientSettings: { meetingHideRecorder: true, meetingSmartSummary: false },
    });
    await service.close();
    const reopened = await AppPreferencesService.open({
      filePath,
      platform: createPlatform(),
    });
    expect(reopened.state().clientSettings).toMatchObject({
      meetingStartRecording: "auto",
      meetingHideRecorder: true,
      meetingSmartSummary: false,
    });
    await reopened.close();
  });
  it("moves an Open Comma shortcut still at the old Option-Space default to Option-Comma, once", async () => {
    const optionSpace = {
      key: "space",
      modifiers: { alt: true, control: false, meta: false, shift: false },
    } as const;
    const optionComma = { ...optionSpace, key: "comma" } as const;
    const controlK = {
      key: "k",
      modifiers: { alt: false, control: true, meta: false, shift: false },
    } as const;
    // Written by a release before the change: every default saved, no revision.
    const { revision: _revision, ...legacyPreferences } = defaultAppPreferences;
    const legacyFile = async (openCommaShortcut: unknown, extra = {}) => {
      const filePath = await temporaryPreferencesPath();
      await writeFile(
        filePath,
        JSON.stringify({
          ...legacyPreferences,
          clientSettings: { ...defaultCommaClientSettings, openCommaShortcut },
          ...extra,
        })
      );
      return filePath;
    };

    const untouched = await legacyFile(optionSpace);
    const platform = { ...createPlatform(), setOpenCommaShortcut: vi.fn() };
    const service = await AppPreferencesService.open({ filePath: untouched, platform });
    expect(platform.setOpenCommaShortcut).toHaveBeenLastCalledWith(optionComma);
    expect(service.state().clientSettings?.openCommaShortcut).toEqual(optionComma);
    expect(JSON.parse(await readFile(untouched, "utf8"))).toMatchObject({
      clientSettings: { openCommaShortcut: optionComma },
      defaultsRevision: 1,
    });
    // Option-Space chosen again afterwards stays.
    await service.update({ clientSettings: { openCommaShortcut: optionSpace } });
    await service.close();
    const reopened = await AppPreferencesService.open({
      filePath: untouched,
      platform,
    });
    expect(reopened.state().clientSettings?.openCommaShortcut).toEqual(optionSpace);
    await reopened.close();

    // A shortcut the user chose, or cleared, before the change stays.
    for (const chosen of [controlK, null]) {
      const filePath = await legacyFile(chosen);
      const kept = await AppPreferencesService.open({ filePath, platform });
      expect(kept.state().clientSettings?.openCommaShortcut).toEqual(chosen);
      await kept.close();
    }
  });

  it("registers Open Comma by default, persists clearing, and restores after a failed edit", async () => {
    const filePath = await temporaryPreferencesPath();
    const platform = { ...createPlatform(), setOpenCommaShortcut: vi.fn() };
    const service = await AppPreferencesService.open({ filePath, platform });
    expect(platform.setOpenCommaShortcut).toHaveBeenLastCalledWith(
      defaultCommaClientSettings.openCommaShortcut
    );
    expect(service.state().openCommaShortcutStatus).toBe("registered");
    platform.setShowInDock.mockImplementationOnce(() => {
      throw new Error("Dock failed");
    });
    await expect(
      service.update({ clientSettings: { openCommaShortcut: null }, showInDock: false })
    ).rejects.toThrow("Dock failed");
    expect(platform.setOpenCommaShortcut).toHaveBeenLastCalledWith(
      defaultCommaClientSettings.openCommaShortcut
    );
    expect(service.state().openCommaShortcutStatus).toBe("registered");
    await service.update({ clientSettings: { openCommaShortcut: null } });
    await service.close();
    const reopened = await AppPreferencesService.open({ filePath, platform });
    expect(platform.setOpenCommaShortcut).toHaveBeenLastCalledWith(null);
    expect(reopened.state().clientSettings?.openCommaShortcut).toBeNull();
    expect(reopened.state().openCommaShortcutStatus).toBe("unset");
    await reopened.close();
  });

  it("keeps Comma available after a startup shortcut conflict and permits an explicit retry", async () => {
    const filePath = await temporaryPreferencesPath();
    const platform = {
      ...createPlatform(),
      setOpenCommaShortcut: vi.fn().mockImplementationOnce(() => {
        throw new Error("Occupied");
      }),
    };
    const service = await AppPreferencesService.open({ filePath, platform });
    expect(service.state().openCommaShortcutStatus).toBe("unavailable");
    await service.update({
      clientSettings: {
        openCommaShortcut: defaultCommaClientSettings.openCommaShortcut,
      },
    });
    expect(service.state().openCommaShortcutStatus).toBe("registered");
    await service.close();
  });

  it("defaults legacy Session visibility to off and persists explicit opt-in without resetting other settings", async () => {
    const filePath = await temporaryPreferencesPath();
    const { sessionHistoryEnabled: _absent, ...legacySettings } =
      defaultCommaClientSettings;
    await writeFile(
      filePath,
      JSON.stringify({
        launchAtLogin: false,
        showInDock: true,
        showInMenuBar: true,
        clientSettings: { ...legacySettings, localePreference: "zh-CN" },
      })
    );
    const service = await AppPreferencesService.open({
      filePath,
      platform: createPlatform(),
    });
    expect(service.state().clientSettings).toMatchObject({
      sessionHistoryEnabled: false,
      localePreference: "zh-CN",
    });
    await service.update({ clientSettings: { sessionHistoryEnabled: true } });
    const reopened = await AppPreferencesService.open({
      filePath,
      platform: createPlatform(),
    });
    expect(reopened.state().clientSettings).toMatchObject({
      sessionHistoryEnabled: true,
      localePreference: "zh-CN",
    });
    await reopened.update({ clientSettings: { sessionHistoryEnabled: false } });
    expect(JSON.parse(await readFile(filePath, "utf8")).clientSettings).toMatchObject({
      sessionHistoryEnabled: false,
      localePreference: "zh-CN",
    });
  });

  it("atomically adopts legacy client settings once and deep-merges later updates", async () => {
    const filePath = await temporaryPreferencesPath();
    const platform = createPlatform();
    const service = await AppPreferencesService.open({ filePath, platform });
    const legacy = {
      ...structuredClone(defaultCommaClientSettings),
      localePreference: "zh-CN" as const,
    };

    await expect(service.initializeClientSettings(legacy)).resolves.toMatchObject({
      clientSettings: legacy,
      revision: 1,
    });
    await expect(
      service.initializeClientSettings({
        ...structuredClone(defaultCommaClientSettings),
        localePreference: "en",
      })
    ).resolves.toMatchObject({
      clientSettings: legacy,
      revision: 1,
    });
    await expect(
      service.update({ clientSettings: { appearance: { theme: "dark" } } })
    ).resolves.toMatchObject({
      clientSettings: {
        ...legacy,
        appearance: {
          ...legacy.appearance,
          theme: "dark",
        },
      },
      revision: 2,
    });

    expect(JSON.parse(await readFile(filePath, "utf8"))).toMatchObject({
      clientSettings: {
        appearance: { theme: "dark" },
        localePreference: "zh-CN",
      },
    });
  });

  it("loads persisted shell visibility and uses the OS login-item truth", async () => {
    const filePath = await temporaryPreferencesPath();
    await writeFile(
      filePath,
      JSON.stringify({
        launchAtLogin: false,
        showInDock: false,
        showInMenuBar: false,
      })
    );
    const platform = createPlatform({ launchAtLogin: true });

    const service = await AppPreferencesService.open({ filePath, platform });

    expect(service.state()).toEqual({
      airDropName: null,
      keepAwakeWhenLidClosed: false,
      launchAtLogin: true,
      notchSideWidth: 156,
      notificationSound: true,
      notifyRouterMessages: true,
      revision: 0,
      showInAirDrop: true,
      showInDock: false,
      showInMenuBar: false,
      showInNotch: true,
      sideChatEnabled: true,
      systemNotifications: true,
      systemNotificationsStatus: "available",
    });
    expect(platform.setShowInDock).toHaveBeenCalledWith(false);
    expect(platform.setShowInMenuBar).toHaveBeenCalledWith(false);
  });

  it("keeps the Mac awake only after opting in and reapplies the choice on launch", async () => {
    const filePath = await temporaryPreferencesPath();
    const platform = { ...createPlatform(), setKeepAwakeWhenLidClosed: vi.fn() };
    const service = await AppPreferencesService.open({ filePath, platform });
    expect(service.state().keepAwakeWhenLidClosed).toBe(false);
    expect(platform.setKeepAwakeWhenLidClosed).not.toHaveBeenCalled();

    await service.update({ keepAwakeWhenLidClosed: true });
    expect(platform.setKeepAwakeWhenLidClosed).toHaveBeenLastCalledWith(true);
    await service.close();

    const relaunched = { ...createPlatform(), setKeepAwakeWhenLidClosed: vi.fn() };
    const reopened = await AppPreferencesService.open({
      filePath,
      platform: relaunched,
    });
    expect(reopened.state().keepAwakeWhenLidClosed).toBe(true);
    expect(relaunched.setKeepAwakeWhenLidClosed).toHaveBeenCalledWith(true, {
      atLaunch: true,
    });

    relaunched.setKeepAwakeWhenLidClosed.mockImplementationOnce(() => {
      throw new Error("sleep guard unavailable");
    });
    await expect(reopened.update({ keepAwakeWhenLidClosed: false })).rejects.toThrow(
      "sleep guard unavailable"
    );
    expect(reopened.state().keepAwakeWhenLidClosed).toBe(true);
    await reopened.close();

    // A daemon that refuses still lets Comma start, with the setting off.
    const refused = {
      ...createPlatform(),
      setKeepAwakeWhenLidClosed: vi.fn(() => {
        throw new Error("pmset exited with 1");
      }),
    };
    const afterRefusal = await AppPreferencesService.open({
      filePath,
      platform: refused,
    });
    expect(afterRefusal.state().keepAwakeWhenLidClosed).toBe(false);
    await afterRefusal.close();
  });

  it("waits for Login Items approval, holds once allowed, and releases when revoked", async () => {
    const filePath = await temporaryPreferencesPath();
    const daemon = createSleepGuardDaemon("not-registered");
    const platform = { ...createPlatform(), ...daemon.platform };
    const onStateChanged = vi.fn();
    const service = await AppPreferencesService.open({
      filePath,
      onStateChanged,
      platform,
    });
    expect(service.state()).toMatchObject({
      keepAwakeWhenLidClosed: false,
      keepAwakeWhenLidClosedStatus: "not-registered",
    });

    // Turning it on registers the daemon; the choice waits for the user.
    await expect(
      service.update({ keepAwakeWhenLidClosed: true })
    ).resolves.toMatchObject({
      keepAwakeWhenLidClosed: true,
      keepAwakeWhenLidClosedStatus: "requires-approval",
    });
    expect(daemon.platform.setKeepAwakeWhenLidClosed.mock.calls).toEqual([[true]]);
    // The choice persists; the status is a readback and never does.
    const persisted = JSON.parse(await readFile(filePath, "utf8"));
    expect(persisted.keepAwakeWhenLidClosed).toBe(true);
    expect(persisted).not.toHaveProperty("keepAwakeWhenLidClosedStatus");

    // Nothing changed in Login Items: no hold and nothing to publish.
    onStateChanged.mockClear();
    await service.refreshKeepAwakeWhenLidClosedStatus();
    expect(daemon.platform.setKeepAwakeWhenLidClosed).toHaveBeenCalledTimes(1);
    expect(onStateChanged).not.toHaveBeenCalled();

    // The user allows Comma in Login Items: the next readback takes the hold.
    daemon.setStatus("available");
    await expect(service.refreshKeepAwakeWhenLidClosedStatus()).resolves.toMatchObject({
      keepAwakeWhenLidClosed: true,
      keepAwakeWhenLidClosedStatus: "available",
    });
    expect(daemon.platform.setKeepAwakeWhenLidClosed).toHaveBeenLastCalledWith(true, {
      atLaunch: true,
    });
    expect(onStateChanged).toHaveBeenLastCalledWith(
      expect.objectContaining({ keepAwakeWhenLidClosedStatus: "available" })
    );

    // A revoked approval drops the hold but keeps the choice for a later approval.
    daemon.setStatus("requires-approval");
    await expect(service.refreshKeepAwakeWhenLidClosedStatus()).resolves.toMatchObject({
      keepAwakeWhenLidClosed: true,
      keepAwakeWhenLidClosedStatus: "requires-approval",
    });
    expect(daemon.platform.setKeepAwakeWhenLidClosed).toHaveBeenLastCalledWith(false);
    await service.close();
  });

  it("keeps a choice that waits for approval across launches and asks again when turned on", async () => {
    const filePath = await temporaryPreferencesPath();
    await writeFile(
      filePath,
      JSON.stringify({
        keepAwakeWhenLidClosed: true,
        launchAtLogin: false,
        showInDock: true,
        showInMenuBar: true,
      })
    );
    const daemon = createSleepGuardDaemon("not-registered");
    const service = await AppPreferencesService.open({
      filePath,
      platform: { ...createPlatform(), ...daemon.platform },
    });

    // At launch Comma neither registers the daemon nor drops the choice.
    expect(daemon.platform.setKeepAwakeWhenLidClosed.mock.calls).toEqual([
      [true, { atLaunch: true }],
    ]);
    expect(service.state()).toMatchObject({
      keepAwakeWhenLidClosed: true,
      keepAwakeWhenLidClosedStatus: "not-registered",
    });

    // Turning it on again asks again, which registers the daemon.
    await expect(
      service.update({ keepAwakeWhenLidClosed: true })
    ).resolves.toMatchObject({ keepAwakeWhenLidClosedStatus: "requires-approval" });
    expect(daemon.platform.setKeepAwakeWhenLidClosed).toHaveBeenLastCalledWith(true);
    await service.close();
  });

  it("retains an approval-required macOS registration while publishing native truth", async () => {
    const filePath = await temporaryPreferencesPath();
    await writeFile(
      filePath,
      JSON.stringify({
        launchAtLogin: false,
        showInDock: true,
        showInMenuBar: true,
      })
    );
    const platform = createPlatform();
    let nativeReadback: LaunchAtLoginReadback = {
      enabled: false,
      status: "not-registered",
    };
    platform.getLaunchAtLogin.mockImplementation(() => nativeReadback);
    platform.setLaunchAtLogin.mockImplementation((enabled: boolean) => {
      nativeReadback = enabled
        ? { enabled: false, status: "requires-approval" }
        : { enabled: false, status: "not-registered" };
      return nativeReadback;
    });
    const onStateChanged = vi.fn();
    const service = await AppPreferencesService.open({
      filePath,
      onStateChanged,
      platform,
    });

    await expect(service.update({ launchAtLogin: true })).resolves.toEqual({
      airDropName: null,
      keepAwakeWhenLidClosed: false,
      launchAtLogin: false,
      launchAtLoginStatus: "requires-approval",
      notchSideWidth: 156,
      notificationSound: true,
      notifyRouterMessages: true,
      revision: 1,
      showInAirDrop: true,
      showInDock: true,
      showInMenuBar: true,
      showInNotch: true,
      sideChatEnabled: true,
      systemNotifications: true,
      systemNotificationsStatus: "available",
    });

    expect(platform.setLaunchAtLogin.mock.calls.map(([enabled]) => enabled)).toEqual([
      true,
    ]);
    expect(onStateChanged).toHaveBeenCalledWith({
      airDropName: null,
      keepAwakeWhenLidClosed: false,
      launchAtLogin: false,
      launchAtLoginStatus: "requires-approval",
      notchSideWidth: 156,
      notificationSound: true,
      notifyRouterMessages: true,
      revision: 1,
      showInAirDrop: true,
      showInDock: true,
      showInMenuBar: true,
      showInNotch: true,
      sideChatEnabled: true,
      systemNotifications: true,
      systemNotificationsStatus: "available",
    });
    expect(service.state().launchAtLogin).toBe(false);
    expect(JSON.parse(await readFile(filePath, "utf8"))).toEqual({
      airDropName: null,
      defaultsRevision: 1,
      keepAwakeWhenLidClosed: false,
      launchAtLogin: false,
      notchSideWidth: 156,
      notificationSound: true,
      notifyRouterMessages: true,
      showInAirDrop: true,
      showInDock: true,
      showInMenuBar: true,
      showInNotch: true,
      sideChatEnabled: true,
      systemNotifications: true,
    });
    const reopened = await AppPreferencesService.open({ filePath, platform });
    expect(reopened.state()).toEqual({
      airDropName: null,
      keepAwakeWhenLidClosed: false,
      launchAtLogin: false,
      launchAtLoginStatus: "requires-approval",
      notchSideWidth: 156,
      notificationSound: true,
      notifyRouterMessages: true,
      revision: 0,
      showInAirDrop: true,
      showInDock: true,
      showInMenuBar: true,
      showInNotch: true,
      sideChatEnabled: true,
      systemNotifications: true,
      systemNotificationsStatus: "available",
    });
    await expect(reopened.update({ launchAtLogin: true })).resolves.toEqual({
      airDropName: null,
      keepAwakeWhenLidClosed: false,
      launchAtLogin: false,
      launchAtLoginStatus: "requires-approval",
      notchSideWidth: 156,
      notificationSound: true,
      notifyRouterMessages: true,
      revision: 0,
      showInAirDrop: true,
      showInDock: true,
      showInMenuBar: true,
      showInNotch: true,
      sideChatEnabled: true,
      systemNotifications: true,
      systemNotificationsStatus: "available",
    });
    expect(platform.setLaunchAtLogin).toHaveBeenCalledTimes(1);

    await expect(reopened.update({ launchAtLogin: false })).resolves.toEqual({
      airDropName: null,
      keepAwakeWhenLidClosed: false,
      launchAtLogin: false,
      launchAtLoginStatus: "not-registered",
      notchSideWidth: 156,
      notificationSound: true,
      notifyRouterMessages: true,
      revision: 1,
      showInAirDrop: true,
      showInDock: true,
      showInMenuBar: true,
      showInNotch: true,
      sideChatEnabled: true,
      systemNotifications: true,
      systemNotificationsStatus: "available",
    });
    expect(platform.setLaunchAtLogin.mock.calls.map(([enabled]) => enabled)).toEqual([
      true,
      false,
    ]);
  });

  it("refreshes an externally approved login item on state snapshots", async () => {
    const filePath = await temporaryPreferencesPath();
    const platform = createPlatform();
    platform.getLaunchAtLogin.mockReturnValue({
      enabled: false,
      status: "requires-approval",
    });
    const onStateChanged = vi.fn();
    const service = await AppPreferencesService.open({
      filePath,
      onStateChanged,
      platform,
    });
    platform.getLaunchAtLogin.mockReturnValue({
      enabled: true,
      status: "enabled",
    });

    expect(service.state()).toEqual({
      airDropName: null,
      keepAwakeWhenLidClosed: false,
      launchAtLogin: true,
      launchAtLoginStatus: "enabled",
      notchSideWidth: 156,
      notificationSound: true,
      notifyRouterMessages: true,
      revision: 1,
      showInAirDrop: true,
      showInDock: true,
      showInMenuBar: true,
      showInNotch: true,
      sideChatEnabled: true,
      systemNotifications: true,
      systemNotificationsStatus: "available",
    });
    expect(onStateChanged).toHaveBeenCalledWith({
      airDropName: null,
      keepAwakeWhenLidClosed: false,
      launchAtLogin: true,
      launchAtLoginStatus: "enabled",
      notchSideWidth: 156,
      notificationSound: true,
      notifyRouterMessages: true,
      revision: 1,
      showInAirDrop: true,
      showInDock: true,
      showInMenuBar: true,
      showInNotch: true,
      sideChatEnabled: true,
      systemNotifications: true,
      systemNotificationsStatus: "available",
    });
  });

  it("merges unrelated updates onto current external login-item truth", async () => {
    const filePath = await temporaryPreferencesPath();
    const platform = createPlatform();
    const onStateChanged = vi.fn();
    const service = await AppPreferencesService.open({
      filePath,
      onStateChanged,
      platform,
    });
    platform.getLaunchAtLogin.mockReturnValue({
      enabled: true,
      status: "enabled",
    });

    await expect(service.update({ showInDock: false })).resolves.toEqual({
      airDropName: null,
      keepAwakeWhenLidClosed: false,
      launchAtLogin: true,
      launchAtLoginStatus: "enabled",
      notchSideWidth: 156,
      notificationSound: true,
      notifyRouterMessages: true,
      revision: 2,
      showInAirDrop: true,
      showInDock: false,
      showInMenuBar: true,
      showInNotch: true,
      sideChatEnabled: true,
      systemNotifications: true,
      systemNotificationsStatus: "available",
    });
    expect(JSON.parse(await readFile(filePath, "utf8"))).toEqual({
      airDropName: null,
      defaultsRevision: 1,
      keepAwakeWhenLidClosed: false,
      launchAtLogin: true,
      notchSideWidth: 156,
      notificationSound: true,
      notifyRouterMessages: true,
      showInAirDrop: true,
      showInDock: false,
      showInMenuBar: true,
      showInNotch: true,
      sideChatEnabled: true,
      systemNotifications: true,
    });
    expect(onStateChanged).toHaveBeenLastCalledWith({
      airDropName: null,
      keepAwakeWhenLidClosed: false,
      launchAtLogin: true,
      launchAtLoginStatus: "enabled",
      notchSideWidth: 156,
      notificationSound: true,
      notifyRouterMessages: true,
      revision: 2,
      showInAirDrop: true,
      showInDock: false,
      showInMenuBar: true,
      showInNotch: true,
      sideChatEnabled: true,
      systemNotifications: true,
      systemNotificationsStatus: "available",
    });
  });

  it("restores a pending registration intent when a later native step fails", async () => {
    const filePath = await temporaryPreferencesPath();
    const platform = createPlatform();
    let nativeReadback: LaunchAtLoginReadback = {
      enabled: false,
      status: "requires-approval",
    };
    platform.getLaunchAtLogin.mockImplementation(() => nativeReadback);
    platform.setLaunchAtLogin.mockImplementation((enabled: boolean) => {
      nativeReadback = enabled
        ? { enabled: false, status: "requires-approval" }
        : { enabled: false, status: "not-registered" };
      return nativeReadback;
    });
    const service = await AppPreferencesService.open({ filePath, platform });
    platform.setShowInDock.mockRejectedValueOnce(new Error("Dock unavailable"));

    await expect(
      service.update({ launchAtLogin: false, showInDock: false })
    ).rejects.toThrow("Dock unavailable");
    expect(platform.setLaunchAtLogin.mock.calls.map(([enabled]) => enabled)).toEqual([
      false,
      true,
    ]);
    expect(service.state()).toEqual({
      airDropName: null,
      keepAwakeWhenLidClosed: false,
      launchAtLogin: false,
      launchAtLoginStatus: "requires-approval",
      notchSideWidth: 156,
      notificationSound: true,
      notifyRouterMessages: true,
      revision: 0,
      showInAirDrop: true,
      showInDock: true,
      showInMenuBar: true,
      showInNotch: true,
      sideChatEnabled: true,
      systemNotifications: true,
      systemNotificationsStatus: "available",
    });
  });

  it("reconciles native truth when a later failure cannot roll back login state", async () => {
    const filePath = await temporaryPreferencesPath();
    const platform = createPlatform();
    let nativeReadback: LaunchAtLoginReadback = {
      enabled: false,
      status: "not-registered",
    };
    platform.getLaunchAtLogin.mockImplementation(() => nativeReadback);
    platform.setLaunchAtLogin.mockImplementation((enabled: boolean) => {
      if (enabled) {
        nativeReadback = { enabled: true, status: "enabled" };
      }
      // Model an OS refusal to disable during rollback: the second call keeps
      // returning the still-enabled native service.
      return nativeReadback;
    });
    const onStateChanged = vi.fn();
    const service = await AppPreferencesService.open({
      filePath,
      onStateChanged,
      platform,
    });
    platform.setShowInDock.mockRejectedValueOnce(new Error("Dock unavailable"));

    await expect(
      service.update({ launchAtLogin: true, showInDock: false })
    ).rejects.toThrow(
      "App preference update failed (Dock unavailable) and native rollback did not fully restore"
    );
    expect(platform.setLaunchAtLogin).toHaveBeenCalledTimes(2);
    expect(service.state()).toEqual({
      airDropName: null,
      keepAwakeWhenLidClosed: false,
      launchAtLogin: true,
      launchAtLoginStatus: "enabled",
      notchSideWidth: 156,
      notificationSound: true,
      notifyRouterMessages: true,
      revision: 1,
      showInAirDrop: true,
      showInDock: true,
      showInMenuBar: true,
      showInNotch: true,
      sideChatEnabled: true,
      systemNotifications: true,
      systemNotificationsStatus: "available",
    });
    expect(onStateChanged).toHaveBeenLastCalledWith({
      airDropName: null,
      keepAwakeWhenLidClosed: false,
      launchAtLogin: true,
      launchAtLoginStatus: "enabled",
      notchSideWidth: 156,
      notificationSound: true,
      notifyRouterMessages: true,
      revision: 1,
      showInAirDrop: true,
      showInDock: true,
      showInMenuBar: true,
      showInNotch: true,
      sideChatEnabled: true,
      systemNotifications: true,
      systemNotificationsStatus: "available",
    });
  });

  it("serializes concurrent patches against the latest committed snapshot", async () => {
    const filePath = await temporaryPreferencesPath();
    const platform = createPlatform();
    const service = await AppPreferencesService.open({ filePath, platform });
    const dockSetterStarted = deferred<void>();
    const releaseDockSetter = deferred<void>();
    platform.setShowInDock.mockClear();
    platform.setShowInMenuBar.mockClear();
    platform.setShowInDock.mockImplementationOnce(async () => {
      dockSetterStarted.resolve();
      await releaseDockSetter.promise;
    });

    const dockUpdate = service.update({ showInDock: false });
    await dockSetterStarted.promise;
    const menuUpdate = service.update({ showInMenuBar: false });
    await Promise.resolve();

    expect(platform.setShowInMenuBar).not.toHaveBeenCalled();
    releaseDockSetter.resolve();
    await expect(dockUpdate).resolves.toEqual({
      airDropName: null,
      keepAwakeWhenLidClosed: false,
      launchAtLogin: false,
      notchSideWidth: 156,
      notificationSound: true,
      notifyRouterMessages: true,
      revision: 1,
      showInAirDrop: true,
      showInDock: false,
      showInMenuBar: true,
      showInNotch: true,
      sideChatEnabled: true,
      systemNotifications: true,
      systemNotificationsStatus: "available",
    });
    await expect(menuUpdate).resolves.toEqual({
      airDropName: null,
      keepAwakeWhenLidClosed: false,
      launchAtLogin: false,
      notchSideWidth: 156,
      notificationSound: true,
      notifyRouterMessages: true,
      revision: 2,
      showInAirDrop: true,
      showInDock: false,
      showInMenuBar: false,
      showInNotch: true,
      sideChatEnabled: true,
      systemNotifications: true,
      systemNotificationsStatus: "available",
    });
    expect(service.state()).toEqual({
      airDropName: null,
      keepAwakeWhenLidClosed: false,
      launchAtLogin: false,
      notchSideWidth: 156,
      notificationSound: true,
      notifyRouterMessages: true,
      revision: 2,
      showInAirDrop: true,
      showInDock: false,
      showInMenuBar: false,
      showInNotch: true,
      sideChatEnabled: true,
      systemNotifications: true,
      systemNotificationsStatus: "available",
    });
    expect(JSON.parse(await readFile(filePath, "utf8"))).toEqual({
      airDropName: null,
      defaultsRevision: 1,
      keepAwakeWhenLidClosed: false,
      launchAtLogin: false,
      notchSideWidth: 156,
      notificationSound: true,
      notifyRouterMessages: true,
      showInAirDrop: true,
      showInDock: false,
      showInMenuBar: false,
      showInNotch: true,
      sideChatEnabled: true,
      systemNotifications: true,
    });
  });

  it("stops mutation admission and drains the committed queue during close", async () => {
    const filePath = await temporaryPreferencesPath();
    const platform = createPlatform();
    const service = await AppPreferencesService.open({ filePath, platform });
    const dockSetterStarted = deferred<void>();
    const releaseDockSetter = deferred<void>();
    platform.setShowInDock.mockImplementationOnce(async () => {
      dockSetterStarted.resolve();
      await releaseDockSetter.promise;
    });

    const update = service.update({ showInDock: false });
    await dockSetterStarted.promise;
    let closeFinished = false;
    const close = service.close().then(() => {
      closeFinished = true;
    });
    await Promise.resolve();

    expect(closeFinished).toBe(false);
    await expect(service.update({ showInMenuBar: false })).rejects.toThrow(
      "Application preferences are closing"
    );

    releaseDockSetter.resolve();
    await expect(update).resolves.toMatchObject({
      airDropName: null,
      keepAwakeWhenLidClosed: false,
      notificationSound: true,
      notifyRouterMessages: true,
      revision: 1,
      showInAirDrop: true,
      showInDock: false,
    });
    await close;
    expect(closeFinished).toBe(true);
    expect(JSON.parse(await readFile(filePath, "utf8"))).toMatchObject({
      showInDock: false,
      showInMenuBar: true,
    });
  });

  it("finishes a failed admitted mutation before close resolves", async () => {
    const filePath = await temporaryPreferencesPath();
    const platform = createPlatform();
    const service = await AppPreferencesService.open({ filePath, platform });
    const dockSetterStarted = deferred<void>();
    const rejectDockSetter = deferred<void>();
    platform.setShowInDock.mockImplementationOnce(async () => {
      dockSetterStarted.resolve();
      await rejectDockSetter.promise;
    });

    const update = service.update({ showInDock: false });
    const updateSettled = update.then(
      () => "resolved" as const,
      (error: unknown) => error
    );
    await dockSetterStarted.promise;
    let closeFinished = false;
    const close = service.close().then(() => {
      closeFinished = true;
    });

    rejectDockSetter.reject(new Error("Dock unavailable"));
    await expect(updateSettled).resolves.toMatchObject({
      message: "Dock unavailable",
    });
    await close;

    expect(closeFinished).toBe(true);
    expect(service.state()).toMatchObject({ revision: 0, showInDock: true });
  });

  it("applies, persists, and publishes application preference updates", async () => {
    const filePath = await temporaryPreferencesPath();
    const platform = createPlatform();
    const onStateChanged = vi.fn();
    const service = await AppPreferencesService.open({
      filePath,
      onStateChanged,
      platform,
    });

    await expect(
      service.update({
        launchAtLogin: true,
        showInDock: false,
        showInMenuBar: false,
      })
    ).resolves.toEqual({
      airDropName: null,
      keepAwakeWhenLidClosed: false,
      launchAtLogin: true,
      notchSideWidth: 156,
      notificationSound: true,
      notifyRouterMessages: true,
      revision: 1,
      showInAirDrop: true,
      showInDock: false,
      showInMenuBar: false,
      showInNotch: true,
      sideChatEnabled: true,
      systemNotifications: true,
      systemNotificationsStatus: "available",
    });

    expect(platform.setLaunchAtLogin).toHaveBeenCalledWith(true);
    expect(platform.setShowInDock).toHaveBeenLastCalledWith(false);
    expect(platform.setShowInMenuBar).toHaveBeenLastCalledWith(false);
    expect(onStateChanged).toHaveBeenCalledWith({
      airDropName: null,
      keepAwakeWhenLidClosed: false,
      launchAtLogin: true,
      notchSideWidth: 156,
      notificationSound: true,
      notifyRouterMessages: true,
      revision: 1,
      showInAirDrop: true,
      showInDock: false,
      showInMenuBar: false,
      showInNotch: true,
      sideChatEnabled: true,
      systemNotifications: true,
      systemNotificationsStatus: "available",
    });
    expect(JSON.parse(await readFile(filePath, "utf8"))).toEqual({
      airDropName: null,
      defaultsRevision: 1,
      keepAwakeWhenLidClosed: false,
      launchAtLogin: true,
      notchSideWidth: 156,
      notificationSound: true,
      notifyRouterMessages: true,
      showInAirDrop: true,
      showInDock: false,
      showInMenuBar: false,
      showInNotch: true,
      sideChatEnabled: true,
      systemNotifications: true,
    });
  });

  it("keeps a chosen AirDrop name across launches and clears it back to the default", async () => {
    const filePath = await temporaryPreferencesPath();
    const platform = createPlatform();
    const service = await AppPreferencesService.open({ filePath, platform });

    await expect(
      service.update({ airDropName: "  Studio Mac  " })
    ).resolves.toMatchObject({ airDropName: "Studio Mac", revision: 1 });
    // Nearby devices show the name on one line.
    await expect(service.update({ airDropName: "Studio\nMac" })).rejects.toThrow();

    const reopened = await AppPreferencesService.open({ filePath, platform });
    expect(reopened.state().airDropName).toBe("Studio Mac");
    await expect(reopened.update({ airDropName: null })).resolves.toMatchObject({
      airDropName: null,
      keepAwakeWhenLidClosed: false,
    });
    expect(JSON.parse(await readFile(filePath, "utf8"))).toMatchObject({
      airDropName: null,
      keepAwakeWhenLidClosed: false,
    });
  });

  it("publishes the OS notification readback without persisting it", async () => {
    const filePath = await temporaryPreferencesPath();
    const platform = createPlatform({ systemNotificationsStatus: "denied" });
    const onStateChanged = vi.fn();
    const service = await AppPreferencesService.open({
      filePath,
      onStateChanged,
      platform,
    });

    expect(service.state()).toMatchObject({
      revision: 0,
      systemNotificationsStatus: "denied",
    });

    // The same answer again is not a change: no revision, no event.
    await expect(service.refreshSystemNotificationsStatus()).resolves.toMatchObject({
      revision: 0,
      systemNotificationsStatus: "denied",
    });
    expect(onStateChanged).not.toHaveBeenCalled();

    // A preference write carries the readback along and still leaves it out
    // of the file, which stores only what Comma itself decides.
    await expect(service.update({ systemNotifications: false })).resolves.toMatchObject(
      {
        revision: 1,
        systemNotifications: false,
        systemNotificationsStatus: "denied",
      }
    );
    expect(JSON.parse(await readFile(filePath, "utf8"))).toEqual({
      airDropName: null,
      defaultsRevision: 1,
      keepAwakeWhenLidClosed: false,
      launchAtLogin: false,
      notchSideWidth: 156,
      notificationSound: true,
      notifyRouterMessages: true,
      showInAirDrop: true,
      showInDock: true,
      showInMenuBar: true,
      showInNotch: true,
      sideChatEnabled: true,
      systemNotifications: false,
    });
  });

  it("asks the OS about notifications without holding up preference writes, then publishes its answer", async () => {
    const filePath = await temporaryPreferencesPath();
    let osStatus: SystemNotificationsStatus = "undetermined";
    const prompt = deferred<void>();
    const platform = {
      ...createPlatform(),
      // macOS keeps its prompt up until the user answers it.
      authorizeSystemNotifications: vi.fn(async () => {
        await prompt.promise;
        osStatus = "available";
        return true;
      }),
      getSystemNotificationsStatus: vi.fn(() => osStatus),
    };
    const onStateChanged = vi.fn();
    const service = await AppPreferencesService.open({
      filePath,
      onStateChanged,
      platform,
    });
    expect(service.state()).toMatchObject({
      revision: 0,
      systemNotificationsStatus: "undetermined",
    });

    const request = service.requestSystemNotificationsAuthorization();
    await expect(service.update({ showInDock: false })).resolves.toMatchObject({
      revision: 1,
      showInDock: false,
      systemNotificationsStatus: "undetermined",
    });

    prompt.resolve();
    await expect(request).resolves.toBe("available");
    expect(platform.authorizeSystemNotifications).toHaveBeenCalledOnce();
    expect(onStateChanged).toHaveBeenLastCalledWith(
      expect.objectContaining({ revision: 2, systemNotificationsStatus: "available" })
    );
    expect(JSON.parse(await readFile(filePath, "utf8"))).not.toHaveProperty(
      "systemNotificationsStatus"
    );
  });

  it("rolls back native changes when persistence fails", async () => {
    const root = await mkdtemp(join(tmpdir(), "comma-app-preferences-failure-"));
    temporaryDirectories.push(root);
    const platform = createPlatform();
    const service = await AppPreferencesService.open({
      filePath: join(root, "preferences.json"),
      platform,
    });
    await rm(root, { recursive: true });
    await writeFile(root, "not-a-directory");

    await expect(service.update({ showInDock: false })).rejects.toThrow();
    expect(platform.setShowInDock.mock.calls.map(([value]) => value)).toEqual([
      true,
      false,
      true,
    ]);
    expect(service.state().showInDock).toBe(true);
  });

  it("continues queued mutations after an earlier mutation fails", async () => {
    const filePath = await temporaryPreferencesPath();
    const platform = createPlatform();
    const service = await AppPreferencesService.open({ filePath, platform });
    platform.setShowInDock.mockRejectedValueOnce(new Error("Dock unavailable"));

    const failedUpdate = service.update({ showInDock: false });
    const succeedingUpdate = service.update({ showInMenuBar: false });

    await expect(failedUpdate).rejects.toThrow("Dock unavailable");
    await expect(succeedingUpdate).resolves.toEqual({
      airDropName: null,
      keepAwakeWhenLidClosed: false,
      launchAtLogin: false,
      notchSideWidth: 156,
      notificationSound: true,
      notifyRouterMessages: true,
      revision: 1,
      showInAirDrop: true,
      showInDock: true,
      showInMenuBar: false,
      showInNotch: true,
      sideChatEnabled: true,
      systemNotifications: true,
      systemNotificationsStatus: "available",
    });
    expect(service.state()).toEqual({
      airDropName: null,
      keepAwakeWhenLidClosed: false,
      launchAtLogin: false,
      notchSideWidth: 156,
      notificationSound: true,
      notifyRouterMessages: true,
      revision: 1,
      showInAirDrop: true,
      showInDock: true,
      showInMenuBar: false,
      showInNotch: true,
      sideChatEnabled: true,
      systemNotifications: true,
      systemNotificationsStatus: "available",
    });
  });
});

// A sleep guard daemon as Login Items shows it: turning it on registers one
// that is not registered yet (never at launch), and holds only when allowed.
function createSleepGuardDaemon(initial: KeepAwakeWhenLidClosedStatus) {
  let status = initial;
  return {
    platform: {
      getKeepAwakeWhenLidClosedStatus: vi.fn(() => status),
      setKeepAwakeWhenLidClosed: vi.fn(
        async (enabled: boolean, options?: { atLaunch?: boolean }) => {
          if (enabled && status === "not-registered" && !options?.atLaunch) {
            status = "requires-approval";
          }
          return status;
        }
      ),
    },
    setStatus(next: KeepAwakeWhenLidClosedStatus) {
      status = next;
    },
  };
}

function createPlatform({
  launchAtLogin = false,
  systemNotificationsStatus = "available" as SystemNotificationsStatus,
} = {}) {
  let nativeLaunchAtLogin = launchAtLogin;
  return {
    authorizeSystemNotifications: vi.fn(
      async () => systemNotificationsStatus === "available"
    ),
    getLaunchAtLogin: vi.fn(
      (): LaunchAtLoginReadback => ({ enabled: nativeLaunchAtLogin })
    ),
    getSystemNotificationsStatus: vi.fn(
      (): SystemNotificationsStatus => systemNotificationsStatus
    ),
    setLaunchAtLogin: vi.fn((enabled: boolean): LaunchAtLoginReadback => {
      nativeLaunchAtLogin = enabled;
      return { enabled: nativeLaunchAtLogin };
    }),
    setShowInDock: vi.fn(),
    setShowInMenuBar: vi.fn(),
  };
}

function deferred<Value>() {
  let resolve!: (value: Value | PromiseLike<Value>) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<Value>((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, reject, resolve };
}

async function temporaryPreferencesPath() {
  const root = await mkdtemp(join(tmpdir(), "comma-app-preferences-"));
  temporaryDirectories.push(root);
  return join(root, "preferences.json");
}
