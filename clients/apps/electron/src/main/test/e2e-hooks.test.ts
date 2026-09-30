import { access, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { defaultAppPreferences } from "@comma/native-bridge";
import { describe, expect, it, vi } from "vitest";
import {
  activateElectronE2eStatusTraySettings,
  activateElectronE2eStatusTrayOpenMainAfterRelease,
  applyElectronE2eHooks,
  awaitElectronE2eMainReadyRelease,
  decorateElectronE2eAppPreferencesProvider,
  resolveElectronE2eHooks,
} from "../e2e-hooks";

describe("Electron e2e hooks", () => {
  it("stays disabled outside Playwright test launches", () => {
    expect(
      resolveElectronE2eHooks({
        env: {
          COMMA_API_BASE_URL: "http://127.0.0.1:7899",
          COMMA_ELECTRON_E2E_ACTIVATE_STATUS_TRAY_SETTINGS: "1",
          COMMA_ELECTRON_E2E_DOCK_UPDATE_BLOCKED_MARKER_FILE_PATH:
            "/tmp/evil-dock-blocked",
          COMMA_ELECTRON_E2E_DOCK_UPDATE_RELEASE_FILE_PATH: "/tmp/evil-dock-release",
          COMMA_ELECTRON_E2E_DEV_RENDERER_URL: "https://evil-dev.example",
          COMMA_ELECTRON_E2E_GOOGLE_ID_TOKEN: "provider-id-token",
          COMMA_ELECTRON_E2E_LAUNCH_AT_LOGIN_DISABLED_MARKER_FILE_PATH:
            "/tmp/evil-login-disabled",
          COMMA_ELECTRON_E2E_LAUNCH_AT_LOGIN_STATUS: "requires-approval",
          COMMA_ELECTRON_E2E_MAIN_READY_BLOCKED_MARKER_FILE_PATH:
            "/tmp/evil-main-ready-blocked",
          COMMA_ELECTRON_E2E_MAIN_READY_RELEASE_FILE_PATH:
            "/tmp/evil-main-ready-release",
          COMMA_ELECTRON_E2E_OPERATING_SYSTEM: "macos",
          COMMA_ELECTRON_E2E_MENU_BAR_HIDDEN_MARKER_FILE_PATH: "/tmp/evil-menu-hidden",
          COMMA_ELECTRON_E2E_STATUS_TRAY_OPEN_MAIN_BLOCKED_MARKER_FILE_PATH:
            "/tmp/evil-tray-open-blocked",
          COMMA_ELECTRON_E2E_STATUS_TRAY_OPEN_MAIN_RELEASE_FILE_PATH:
            "/tmp/evil-tray-open-release",
          COMMA_ELECTRON_RENDERER_URL: "https://evil.example",
          COMMA_ELECTRON_E2E_CONNECTOR_MODE: "static",
          COMMA_ELECTRON_E2E_SIDE_CHAT_HOST_PATH: "/tmp/evil-helper",
          NODE_ENV: "development",
        },
        isPackaged: false,
      })
    ).toEqual({});
    expect(
      resolveElectronE2eHooks({
        env: {
          COMMA_API_BASE_URL: "http://127.0.0.1:7899",
          COMMA_ELECTRON_E2E_ACTIVATE_STATUS_TRAY_SETTINGS: "1",
          COMMA_ELECTRON_E2E_DOCK_UPDATE_BLOCKED_MARKER_FILE_PATH:
            "/tmp/evil-dock-blocked",
          COMMA_ELECTRON_E2E_DOCK_UPDATE_RELEASE_FILE_PATH: "/tmp/evil-dock-release",
          COMMA_ELECTRON_E2E_DEV_RENDERER_URL: "https://evil-dev.example",
          COMMA_ELECTRON_E2E_GOOGLE_ID_TOKEN: "provider-id-token",
          COMMA_ELECTRON_E2E_LAUNCH_AT_LOGIN_DISABLED_MARKER_FILE_PATH:
            "/tmp/evil-login-disabled",
          COMMA_ELECTRON_E2E_LAUNCH_AT_LOGIN_STATUS: "requires-approval",
          COMMA_ELECTRON_E2E_MAIN_READY_BLOCKED_MARKER_FILE_PATH:
            "/tmp/evil-main-ready-blocked",
          COMMA_ELECTRON_E2E_MAIN_READY_RELEASE_FILE_PATH:
            "/tmp/evil-main-ready-release",
          COMMA_ELECTRON_E2E_OPERATING_SYSTEM: "macos",
          COMMA_ELECTRON_E2E_MENU_BAR_HIDDEN_MARKER_FILE_PATH: "/tmp/evil-menu-hidden",
          COMMA_ELECTRON_E2E_STATUS_TRAY_OPEN_MAIN_BLOCKED_MARKER_FILE_PATH:
            "/tmp/evil-tray-open-blocked",
          COMMA_ELECTRON_E2E_STATUS_TRAY_OPEN_MAIN_RELEASE_FILE_PATH:
            "/tmp/evil-tray-open-release",
          COMMA_ELECTRON_RENDERER_URL: "https://evil.example",
          COMMA_ELECTRON_E2E_CONNECTOR_MODE: "static",
          NODE_ENV: "test",
        },
        isPackaged: true,
      })
    ).toEqual({});
  });

  it("resolves renderer and app-preference lifecycle hooks only in e2e", () => {
    expect(
      resolveElectronE2eHooks({
        createUserDataPath: () => "/tmp/comma-e2e-user-data",
        env: {
          COMMA_ELECTRON_E2E_APP_PREFERENCES_DRAIN_STARTED_MARKER_FILE_PATH:
            " /tmp/comma-preferences-drain ",
          COMMA_ELECTRON_E2E_APP_PREFERENCES_STATE_BLOCKED_MARKER_FILE_PATH:
            " /tmp/comma-preferences-state-blocked ",
          COMMA_ELECTRON_E2E_APP_PREFERENCES_STATE_RELEASE_FILE_PATH:
            " /tmp/comma-preferences-state-release ",
          COMMA_ELECTRON_E2E_APP_PREFERENCES_UPDATE_ACK_BLOCKED_MARKER_FILE_PATH:
            " /tmp/comma-preferences-ack-blocked ",
          COMMA_ELECTRON_E2E_APP_PREFERENCES_UPDATE_ACK_RELEASE_FILE_PATH:
            " /tmp/comma-preferences-ack-release ",
          COMMA_ELECTRON_E2E_DEV_RENDERER_URL: " http://127.0.0.1:5174/e2e ",
          COMMA_ELECTRON_RENDERER_URL: " http://127.0.0.1:5173/e2e ",
          NODE_ENV: "test",
        },
        isPackaged: false,
      })
    ).toEqual({
      appPreferencesDrainStartedMarkerFilePath: "/tmp/comma-preferences-drain",
      appPreferencesStateBlockedMarkerFilePath: "/tmp/comma-preferences-state-blocked",
      appPreferencesStateReleaseFilePath: "/tmp/comma-preferences-state-release",
      appPreferencesUpdateAckBlockedMarkerFilePath:
        "/tmp/comma-preferences-ack-blocked",
      appPreferencesUpdateAckReleaseFilePath: "/tmp/comma-preferences-ack-release",
      devRendererUrl: "http://127.0.0.1:5174/e2e",
      rendererUrl: "http://127.0.0.1:5173/e2e",
      fallbackUserDataPath: "/tmp/comma-e2e-user-data",
    });
  });

  it("rejects incomplete app-preference response gates", () => {
    expect(() =>
      resolveElectronE2eHooks({
        env: {
          COMMA_ELECTRON_E2E_APP_PREFERENCES_STATE_BLOCKED_MARKER_FILE_PATH:
            "/tmp/comma-preferences-state-blocked",
          NODE_ENV: "test",
        },
        isPackaged: false,
      })
    ).toThrow(
      "The app-preferences state response e2e gate requires both blocked-marker and release file paths."
    );
  });

  it("enables the explicit side-chat visibility hook only in unpackaged tests", () => {
    expect(
      resolveElectronE2eHooks({
        createUserDataPath: () => "/tmp/comma-e2e-user-data",
        env: {
          COMMA_ELECTRON_E2E_OPEN_SIDE_CHAT: "1",
          NODE_ENV: "test",
        },
        isPackaged: false,
      })
    ).toEqual({
      openSideChat: true,
      fallbackUserDataPath: "/tmp/comma-e2e-user-data",
    });
    expect(
      resolveElectronE2eHooks({
        env: {
          COMMA_ELECTRON_E2E_OPEN_SIDE_CHAT: "1",
          NODE_ENV: "test",
        },
        isPackaged: true,
      })
    ).toEqual({});
  });

  it("keeps explicitly backgrounded unpackaged and packaged test windows inactive", () => {
    const env = {
      COMMA_ELECTRON_E2E_BACKGROUND_WINDOWS: "1",
      NODE_ENV: "test",
    } as const;

    expect(
      resolveElectronE2eHooks({
        createUserDataPath: () => "/tmp/comma-background-e2e",
        env,
        isPackaged: false,
      })
    ).toEqual({
      backgroundWindows: true,
    });
    expect(resolveElectronE2eHooks({ env, isPackaged: true })).toEqual({
      backgroundWindows: true,
    });
  });

  it("resolves a Side Chat helper fixture only for unpackaged e2e launches", () => {
    expect(
      resolveElectronE2eHooks({
        createUserDataPath: () => "/tmp/comma-e2e-user-data",
        env: {
          COMMA_ELECTRON_E2E_SIDE_CHAT_HOST_PATH:
            " /tmp/comma-side-chat-helper-fixture ",
          NODE_ENV: "test",
        },
        isPackaged: false,
      })
    ).toEqual({
      sideChatHostPath: "/tmp/comma-side-chat-helper-fixture",
      fallbackUserDataPath: "/tmp/comma-e2e-user-data",
    });
    expect(
      resolveElectronE2eHooks({
        env: {
          COMMA_ELECTRON_E2E_SIDE_CHAT_HOST_PATH: "/tmp/comma-side-chat-helper-fixture",
          NODE_ENV: "test",
        },
        isPackaged: true,
      })
    ).toEqual({});
  });

  it("resolves the explicit Main readiness gate and tray Settings activation hook", () => {
    expect(
      resolveElectronE2eHooks({
        createUserDataPath: () => "/tmp/comma-e2e-user-data",
        env: {
          COMMA_ELECTRON_E2E_ACTIVATE_STATUS_TRAY_SETTINGS: "1",
          COMMA_ELECTRON_E2E_MAIN_READY_BLOCKED_MARKER_FILE_PATH:
            " /tmp/comma-main-ready-blocked ",
          COMMA_ELECTRON_E2E_MAIN_READY_RELEASE_FILE_PATH:
            " /tmp/comma-main-ready-release ",
          NODE_ENV: "test",
        },
        isPackaged: false,
      })
    ).toEqual({
      activateStatusTraySettings: true,
      mainReadyBlockedMarkerFilePath: "/tmp/comma-main-ready-blocked",
      mainReadyReleaseFilePath: "/tmp/comma-main-ready-release",
      fallbackUserDataPath: "/tmp/comma-e2e-user-data",
    });
  });

  it("resolves the explicit tray Open Comma gate", () => {
    expect(
      resolveElectronE2eHooks({
        createUserDataPath: () => "/tmp/comma-e2e-user-data",
        env: {
          COMMA_ELECTRON_E2E_STATUS_TRAY_OPEN_MAIN_BLOCKED_MARKER_FILE_PATH:
            " /tmp/comma-tray-open-blocked ",
          COMMA_ELECTRON_E2E_STATUS_TRAY_OPEN_MAIN_RELEASE_FILE_PATH:
            " /tmp/comma-tray-open-release ",
          NODE_ENV: "test",
        },
        isPackaged: false,
      })
    ).toEqual({
      statusTrayOpenMainBlockedMarkerFilePath: "/tmp/comma-tray-open-blocked",
      statusTrayOpenMainReleaseFilePath: "/tmp/comma-tray-open-release",
      fallbackUserDataPath: "/tmp/comma-e2e-user-data",
    });
  });

  it("rejects an incomplete tray Open Comma gate", () => {
    expect(() =>
      resolveElectronE2eHooks({
        env: {
          COMMA_ELECTRON_E2E_STATUS_TRAY_OPEN_MAIN_RELEASE_FILE_PATH:
            "/tmp/comma-tray-open-release",
          NODE_ENV: "test",
        },
        isPackaged: false,
      })
    ).toThrow(
      "The status tray Open Comma e2e gate requires both blocked-marker and release file paths."
    );
  });

  it("resolves explicit OS and login-item read-back fixtures", () => {
    expect(
      resolveElectronE2eHooks({
        createUserDataPath: () => "/tmp/comma-e2e-user-data",
        env: {
          COMMA_ELECTRON_E2E_DOCK_UPDATE_BLOCKED_MARKER_FILE_PATH:
            " /tmp/comma-dock-blocked ",
          COMMA_ELECTRON_E2E_DOCK_UPDATE_RELEASE_FILE_PATH: " /tmp/comma-dock-release ",
          COMMA_ELECTRON_E2E_LAUNCH_AT_LOGIN_DISABLED_MARKER_FILE_PATH:
            " /tmp/comma-login-disabled ",
          COMMA_ELECTRON_E2E_LAUNCH_AT_LOGIN_APPROVED_MARKER_FILE_PATH:
            " /tmp/comma-login-approved ",
          COMMA_ELECTRON_E2E_LAUNCH_AT_LOGIN_REGISTERED_MARKER_FILE_PATH:
            " /tmp/comma-login-registered ",
          COMMA_ELECTRON_E2E_LAUNCH_AT_LOGIN_STATUS: "requires-approval",
          COMMA_ELECTRON_E2E_MENU_BAR_HIDDEN_MARKER_FILE_PATH:
            " /tmp/comma-menu-hidden ",
          COMMA_ELECTRON_E2E_OPERATING_SYSTEM: "macos",
          COMMA_ELECTRON_E2E_SYSTEM_NOTIFICATIONS_STATUS: " denied ",
          NODE_ENV: "test",
        },
        isPackaged: false,
      })
    ).toEqual({
      dockUpdateBlockedMarkerFilePath: "/tmp/comma-dock-blocked",
      dockUpdateReleaseFilePath: "/tmp/comma-dock-release",
      launchAtLoginDisabledMarkerFilePath: "/tmp/comma-login-disabled",
      launchAtLoginApprovedMarkerFilePath: "/tmp/comma-login-approved",
      launchAtLoginRegisteredMarkerFilePath: "/tmp/comma-login-registered",
      launchAtLoginStatus: "requires-approval",
      menuBarHiddenMarkerFilePath: "/tmp/comma-menu-hidden",
      operatingSystem: "macos",
      systemNotificationsStatus: "denied",
      fallbackUserDataPath: "/tmp/comma-e2e-user-data",
    });
  });

  it("blocks Main readiness until the e2e releases its file gate", async () => {
    const directory = await mkdtemp(join(tmpdir(), "comma-main-ready-gate-test-"));
    const blockedMarkerFilePath = join(directory, "blocked");
    const releaseFilePath = join(directory, "release");
    let released = false;
    let waiting: Promise<void> | undefined;

    try {
      waiting = awaitElectronE2eMainReadyRelease({
        mainReadyBlockedMarkerFilePath: blockedMarkerFilePath,
        mainReadyReleaseFilePath: releaseFilePath,
      }).then(() => {
        released = true;
      });

      await waitForFile(blockedMarkerFilePath);
      expect(released).toBe(false);

      await writeFile(releaseFilePath, "release\n", "utf8");
      await waiting;
      expect(released).toBe(true);
    } finally {
      await writeFile(releaseFilePath, "release\n", "utf8").catch(() => {});
      await waiting?.catch(() => {});
      await rm(directory, { force: true, recursive: true });
    }
  });

  it("delays only the first app-preference acknowledgement", async () => {
    const directory = await mkdtemp(join(tmpdir(), "comma-preferences-ack-gate-test-"));
    const blockedMarkerFilePath = join(directory, "blocked");
    const releaseFilePath = join(directory, "release");
    const snapshots = [
      { ...defaultAppPreferences, revision: 1, showInDock: false },
      {
        ...defaultAppPreferences,
        revision: 2,
        showInDock: false,
        showInMenuBar: false,
      },
    ];
    let updateIndex = 0;
    const provider = {
      close: vi.fn(async () => {}),
      initializeClientSettings: vi.fn(async () => defaultAppPreferences),
      openNotificationSettings: vi.fn(async () => ({ opened: false })),
      state: vi.fn(() => defaultAppPreferences),
      update: vi.fn(async () => snapshots[updateIndex++]!),
    };
    const decorated = decorateElectronE2eAppPreferencesProvider(
      {
        appPreferencesUpdateAckBlockedMarkerFilePath: blockedMarkerFilePath,
        appPreferencesUpdateAckReleaseFilePath: releaseFilePath,
      },
      provider
    );
    let firstSettled = false;
    let firstUpdate: Promise<unknown> | undefined;

    try {
      firstUpdate = Promise.resolve(decorated.update({ showInDock: false })).then(
        (snapshot) => {
          firstSettled = true;
          return snapshot;
        }
      );
      await waitForFile(blockedMarkerFilePath);

      await expect(decorated.update({ showInMenuBar: false })).resolves.toMatchObject({
        revision: 2,
        showInMenuBar: false,
      });
      expect(firstSettled).toBe(false);

      await writeFile(releaseFilePath, "release\n", "utf8");
      await expect(firstUpdate).resolves.toMatchObject({
        revision: 1,
        showInDock: false,
      });
    } finally {
      await writeFile(releaseFilePath, "release\n", "utf8").catch(() => {});
      await firstUpdate?.catch(() => {});
      await rm(directory, { force: true, recursive: true });
    }
  });

  it("activates tray Settings only when the unpackaged e2e hook requests it", () => {
    const activate = vi.fn();

    activateElectronE2eStatusTraySettings({}, activate);
    expect(activate).not.toHaveBeenCalled();

    activateElectronE2eStatusTraySettings(
      { activateStatusTraySettings: true },
      activate
    );
    expect(activate).toHaveBeenCalledOnce();
  });

  it("activates tray Open Comma only after the e2e releases its gate", async () => {
    const directory = await mkdtemp(join(tmpdir(), "comma-tray-open-gate-test-"));
    const blockedMarkerFilePath = join(directory, "blocked");
    const releaseFilePath = join(directory, "release");
    const activate = vi.fn();
    let waiting: Promise<void> | undefined;

    try {
      waiting = activateElectronE2eStatusTrayOpenMainAfterRelease(
        {
          statusTrayOpenMainBlockedMarkerFilePath: blockedMarkerFilePath,
          statusTrayOpenMainReleaseFilePath: releaseFilePath,
        },
        activate
      );
      await waitForFile(blockedMarkerFilePath);
      expect(activate).not.toHaveBeenCalled();

      await writeFile(releaseFilePath, "open\n", "utf8");
      await waiting;
      expect(activate).toHaveBeenCalledOnce();
    } finally {
      await writeFile(releaseFilePath, "open\n", "utf8").catch(() => {});
      await waiting?.catch(() => {});
      await rm(directory, { force: true, recursive: true });
    }
  });

  it("can isolate the secure session file from the Chromium profile", () => {
    expect(
      resolveElectronE2eHooks({
        createUserDataPath: () => "/tmp/comma-e2e-user-data",
        env: {
          COMMA_ELECTRON_E2E_SECURE_SESSION_FILE_PATH:
            " /tmp/comma-session-fixture/secure-session.bin ",
          NODE_ENV: "test",
        },
        isPackaged: false,
      })
    ).toEqual({
      secureSessionFilePath: "/tmp/comma-session-fixture/secure-session.bin",
      fallbackUserDataPath: "/tmp/comma-e2e-user-data",
    });
  });

  it.each(["real", "static"] as const)(
    "resolves the explicit %s Connector mode independently of Session setup",
    (connectorMode) => {
      expect(
        resolveElectronE2eHooks({
          createUserDataPath: () => "/tmp/comma-e2e-user-data",
          env: {
            COMMA_ELECTRON_E2E_CONNECTOR_MODE: connectorMode,
            NODE_ENV: "test",
          },
          isPackaged: false,
        })
      ).toEqual({
        connectorMode,
        fallbackUserDataPath: "/tmp/comma-e2e-user-data",
      });
    }
  );

  it("keeps API base URL override separate from startup Session setup", () => {
    expect(
      resolveElectronE2eHooks({
        createUserDataPath: () => "/tmp/comma-e2e-user-data",
        env: {
          COMMA_API_BASE_URL: " http://127.0.0.1:7899 ",
          NODE_ENV: "test",
        },
        isPackaged: false,
      })
    ).toEqual({
      apiBaseUrl: "http://127.0.0.1:7899",
      fallbackUserDataPath: "/tmp/comma-e2e-user-data",
    });
  });

  it("resolves a Main-only Google credential for unpackaged e2e launches", () => {
    expect(
      resolveElectronE2eHooks({
        createUserDataPath: () => "/tmp/comma-e2e-user-data",
        env: {
          COMMA_ELECTRON_E2E_GOOGLE_ID_TOKEN: " provider-id-token ",
          NODE_ENV: "test",
        },
        isPackaged: false,
      })
    ).toEqual({
      googleIdToken: "provider-id-token",
      fallbackUserDataPath: "/tmp/comma-e2e-user-data",
    });
  });

  it("writes the e2e session through SecureSessionStore and reconciles Main", async () => {
    const setSession = vi.fn(async () => {});
    const initialize = vi.fn(async () => {});

    await applyElectronE2eHooks(
      {
        apiBaseUrl: "http://127.0.0.1:7899",
        session: {
          audience: "http://127.0.0.1:7899",
          email: "e2e@example.com",
          expiresAtEpochSeconds: 4_102_444_800,
          sessionId: "e2e-session:e2e@example.com",
          token: "comma_sess_e2e",
          userId: "e2e-user:e2e@example.com",
        },
      },
      { setSession },
      { initialize }
    );

    expect(setSession).toHaveBeenCalledWith({
      audience: "http://127.0.0.1:7899",
      email: "e2e@example.com",
      expiresAtEpochSeconds: 4_102_444_800,
      sessionId: "e2e-session:e2e@example.com",
      token: "comma_sess_e2e",
      userId: "e2e-user:e2e@example.com",
    });
    expect(initialize).toHaveBeenCalledOnce();
    expect(setSession.mock.invocationCallOrder[0]).toBeLessThan(
      initialize.mock.invocationCallOrder[0]!
    );
  });
});

async function waitForFile(filePath: string) {
  const deadline = Date.now() + 2_000;
  while (Date.now() < deadline) {
    try {
      await access(filePath);
      return;
    } catch {
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
  }

  throw new Error(`Timed out waiting for ${filePath}.`);
}
