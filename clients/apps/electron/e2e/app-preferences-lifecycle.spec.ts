import { _electron as electron, expect, test, type Locator } from "@playwright/test";
import type { AppPreferences, AppPreferencesPatch } from "@comma/native-bridge";
import { spawn } from "node:child_process";
import { access, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import {
  findElectronWindowByNativeId,
  findElectronWindowByNativeRole,
} from "../src/test-support/electron-native-window";
import { recordElectronOnboardingCompleted } from "../../../e2e/helpers/electron-profile";
import { startSessionProjectionStub } from "../../../e2e/helpers/session-fixture";

const electronAppDir = resolve(process.cwd(), "apps/electron");
const electronMain = resolve(electronAppDir, ".vite/build/main.js");
const PREFERENCES_E2E_EMAIL = "app-preferences-e2e@example.com";
const PREFERENCES_E2E_TOKEN = "comma_sess_app_preferences_e2e";
let sessionStub: Awaited<ReturnType<typeof startSessionProjectionStub>>;

test.describe("app preferences lifecycle", () => {
  let testDirectory: string;

  test.beforeAll(async () => {
    sessionStub = await startSessionProjectionStub({
      email: PREFERENCES_E2E_EMAIL,
    });
  });

  test.afterAll(async () => {
    await sessionStub.close();
  });

  test.beforeEach(async () => {
    testDirectory = await mkdtemp(join(tmpdir(), "comma-preferences-lifecycle-e2e-"));
  });

  test.afterEach(async () => {
    await rm(testDirectory, { force: true, recursive: true });
  });

  test("preserves notification choices when later bridge patches omit them", async () => {
    const userDataPath = join(testDirectory, "notification-patch-user-data");
    const preferencesFilePath = join(userDataPath, "app-preferences.json");
    const envOverrides = {
      COMMA_ELECTRON_E2E_LAUNCH_AT_LOGIN_STATUS: "not-registered",
      COMMA_ELECTRON_E2E_OPERATING_SYSTEM: "macos",
    };
    const app = await electron.launch({
      args: electronLaunchArgs(userDataPath),
      cwd: electronAppDir,
      env: signedInElectronEnv(userDataPath, envOverrides),
    });

    try {
      const mainWindow = await openAppSettings(app);

      // Startup reconciles the login-item readback, which legitimately
      // advances the revision before any preference is touched here. What
      // this test owns is how the revision moves per patch, so it counts from
      // whatever that settled on rather than from a fixed number.
      const { revision: baseRevision } = await readRendererPreferences(mainWindow);

      await updateRendererPreferences(mainWindow, { notificationSound: false });
      await expect
        .poll(() => readRendererPreferences(mainWindow))
        .toMatchObject({
          notificationSound: false,
          notifyRouterMessages: true,
          revision: baseRevision + 1,
        });

      await updateRendererPreferences(mainWindow, { notifyRouterMessages: false });
      await expect
        .poll(() => readRendererPreferences(mainWindow))
        .toMatchObject({
          notificationSound: false,
          notifyRouterMessages: false,
          revision: baseRevision + 2,
        });

      // This valid no-op patch names neither notification field. It must not
      // synthesize defaults, change the stored choices, or advance the revision.
      await updateRendererPreferences(mainWindow, { launchAtLogin: false });
      await expect
        .poll(() => readRendererPreferences(mainWindow))
        .toMatchObject({
          launchAtLogin: false,
          notificationSound: false,
          notifyRouterMessages: false,
          revision: baseRevision + 2,
        });
      expect(JSON.parse(await readFile(preferencesFilePath, "utf8"))).toMatchObject({
        notificationSound: false,
        notifyRouterMessages: false,
      });
      await mainWindow.getByRole("button", { name: "Debug", exact: true }).click();
      const sessionToggle = mainWindow.getByRole("switch", {
        name: "Show Session history",
      });
      await expect(sessionToggle).not.toBeChecked();
      await activateSwitch(sessionToggle);
      await expect
        .poll(() => readRendererPreferences(mainWindow))
        .toMatchObject({
          clientSettings: { sessionHistoryEnabled: true },
          notificationSound: false,
          notifyRouterMessages: false,
        });
    } finally {
      await app.close();
    }

    const restarted = await electron.launch({
      args: electronLaunchArgs(userDataPath),
      cwd: electronAppDir,
      env: persistedSessionElectronEnv(userDataPath, envOverrides),
    });
    try {
      const mainWindow = await openAppSettings(restarted);
      // Revision is an in-memory counter that restarts with Main, and the
      // login-item reconciliation moves it again here; what has to survive the
      // restart is the pair of stored choices.
      await expect
        .poll(() => readRendererPreferences(mainWindow))
        .toMatchObject({
          notificationSound: false,
          notifyRouterMessages: false,
        });
      await mainWindow.getByRole("button", { name: "Debug", exact: true }).click();
      const sessionToggle = mainWindow.getByRole("switch", {
        name: "Show Session history",
      });
      await expect(sessionToggle).toBeChecked();
      await activateSwitch(sessionToggle);
      await expect
        .poll(() => readRendererPreferences(mainWindow))
        .toMatchObject({
          clientSettings: { sessionHistoryEnabled: false },
        });
    } finally {
      await restarted.close();
    }
  });

  // Main owns the Notch settings and applies them to every scene writer: a
  // turned-off Notch answers the writer itself instead of starting NotchHost,
  // and both choices survive a restart without the renderer repeating them.
  test("keeps the Notch settings in Main, where a turned-off Notch starts no helper", async () => {
    const userDataPath = join(testDirectory, "notch-user-data");
    const preferencesFilePath = join(userDataPath, "app-preferences.json");
    const envOverrides = { COMMA_ELECTRON_E2E_OPERATING_SYSTEM: "macos" };
    const app = await electron.launch({
      args: electronLaunchArgs(userDataPath),
      cwd: electronAppDir,
      env: signedInElectronEnv(userDataPath, envOverrides),
    });

    try {
      const mainWindow = await openAppSettings(app);
      const showInNotch = mainWindow.getByRole("switch", { name: "Show in notch" });
      await expect(showInNotch).toBeChecked();
      const width = mainWindow.getByRole("slider", { name: "Notch width" });
      await expect(width).toHaveAttribute("aria-valuenow", "156");

      await width.focus();
      await width.press("End");
      await expect
        .poll(() => readRendererPreferences(mainWindow))
        .toMatchObject({ notchSideWidth: 240, showInNotch: true });

      await activateSwitch(showInNotch);
      await expect(showInNotch).not.toBeChecked();
      await expect(width).toBeHidden();
      await expect(writeNotchScene(mainWindow)).resolves.toEqual({
        payload: { hasActivity: false, method: "update", running: false },
        type: "ack",
      });
      expect(JSON.parse(await readFile(preferencesFilePath, "utf8"))).toMatchObject({
        notchSideWidth: 240,
        showInNotch: false,
      });
    } finally {
      await app.close();
    }

    const restarted = await electron.launch({
      args: electronLaunchArgs(userDataPath),
      cwd: electronAppDir,
      env: persistedSessionElectronEnv(userDataPath, envOverrides),
    });
    try {
      const mainWindow = await openAppSettings(restarted);
      const showInNotch = mainWindow.getByRole("switch", { name: "Show in notch" });
      await expect(showInNotch).not.toBeChecked();
      await expect(writeNotchScene(mainWindow)).resolves.toMatchObject({
        payload: { running: false },
        type: "ack",
      });

      await activateSwitch(showInNotch);
      await expect(
        mainWindow.getByRole("slider", { name: "Notch width" })
      ).toHaveAttribute("aria-valuenow", "240");
    } finally {
      await restarted.close();
    }
  });

  // Main owns the General Side Chat switch: turned off, the Window menu hides
  // Open Side Chat and the shortcut row takes no chord, and the choice survives
  // a restart, where Main applies it before the helper starts.
  test("turns Side Chat off from General and keeps it off after a restart", async () => {
    const userDataPath = join(testDirectory, "side-chat-user-data");
    const preferencesFilePath = join(userDataPath, "app-preferences.json");
    const envOverrides = { COMMA_ELECTRON_E2E_OPERATING_SYSTEM: "macos" };
    const app = await electron.launch({
      args: electronLaunchArgs(userDataPath),
      cwd: electronAppDir,
      env: signedInElectronEnv(userDataPath, envOverrides),
    });

    try {
      const mainWindow = await openAppSettings(app);
      const sideChat = mainWindow.getByRole("switch", {
        name: "Side Chat",
        exact: true,
      });
      await expect(sideChat).toBeChecked();
      await expect.poll(() => sideChatMenuItemVisible(app)).toBe(true);

      await activateSwitch(sideChat);
      await expect(sideChat).not.toBeChecked();
      await expect
        .poll(() => readRendererPreferences(mainWindow))
        .toMatchObject({ sideChatEnabled: false });
      await expect.poll(() => sideChatMenuItemVisible(app)).toBe(false);
      expect(JSON.parse(await readFile(preferencesFilePath, "utf8"))).toMatchObject({
        sideChatEnabled: false,
      });

      await mainWindow.getByRole("button", { name: "Keyboard shortcuts" }).click();
      await expect(
        mainWindow.getByRole("button", { name: /^Open Side Chat:/ })
      ).toBeDisabled();
    } finally {
      await app.close();
    }

    const restarted = await electron.launch({
      args: electronLaunchArgs(userDataPath),
      cwd: electronAppDir,
      env: persistedSessionElectronEnv(userDataPath, envOverrides),
    });
    try {
      const mainWindow = await openAppSettings(restarted);
      const sideChat = mainWindow.getByRole("switch", {
        name: "Side Chat",
        exact: true,
      });
      await expect(sideChat).not.toBeChecked();
      await expect.poll(() => sideChatMenuItemVisible(restarted)).toBe(false);

      await activateSwitch(sideChat);
      await expect(sideChat).toBeChecked();
      await expect.poll(() => sideChatMenuItemVisible(restarted)).toBe(true);
    } finally {
      await restarted.close();
    }
  });

  // The status tray preference is loaded while Main's services are composing,
  // but its Settings action must not become interactive until every initial
  // window and handler is ready. The test-only release gate pauses that exact
  // boundary; activating the real tray Settings callback on installation
  // proves it is published only after the gate has opened.
  test("publishes status tray Settings only after Main startup is ready", async () => {
    const blockedMarkerFilePath = join(testDirectory, "main-ready-blocked");
    const releaseFilePath = join(testDirectory, "main-ready-release");
    const userDataPath = join(testDirectory, "user-data");
    const app = await electron.launch({
      args: electronLaunchArgs(userDataPath),
      cwd: electronAppDir,
      env: {
        ...signedInElectronEnv(userDataPath),
        COMMA_ELECTRON_E2E_ACTIVATE_STATUS_TRAY_SETTINGS: "1",
        COMMA_ELECTRON_E2E_MAIN_READY_BLOCKED_MARKER_FILE_PATH: blockedMarkerFilePath,
        COMMA_ELECTRON_E2E_MAIN_READY_RELEASE_FILE_PATH: releaseFilePath,
        NODE_ENV: "test",
      },
    });

    try {
      await expect
        .poll(() => fileExists(blockedMarkerFilePath), { timeout: 15_000 })
        .toBe(true);
      expect(
        await app.evaluate(({ BrowserWindow }) =>
          BrowserWindow.getAllWindows().map((window) => window.webContents.getURL())
        )
      ).toEqual([]);

      await writeFile(releaseFilePath, "release\n", "utf8");

      const mainWindow = await findElectronWindowByNativeRole(app, "main-window");
      await expect(mainWindow).toHaveURL(/#\/settings$/);
      await expect(
        mainWindow.getByRole("heading", { level: 1, name: "General" })
      ).toBeVisible();

      await mainWindow.keyboard.press("Escape");
      await expect(
        mainWindow.getByRole("heading", { level: 1, name: "General" })
      ).toBeHidden();
      await app.evaluate(({ BrowserWindow }) => {
        BrowserWindow.getAllWindows()
          .find((window) => !window.webContents.getURL().includes("#/side-chat"))
          ?.hide();
      });
      await mainWindow.evaluate(() => window.commaNative!.sideChat.openSettings());
      await expect(
        mainWindow.getByRole("heading", { level: 1, name: "General" })
      ).toBeVisible();
      await expect
        .poll(() =>
          app.evaluate(({ BrowserWindow }) => {
            const windows = BrowserWindow.getAllWindows().filter((window) =>
              window.webContents.getURL().includes("#/settings")
            );
            return { count: windows.length, visible: windows[0]?.isVisible() };
          })
        )
        .toEqual({ count: 1, visible: true });
    } finally {
      // Never strand Main behind the deterministic gate if an assertion above
      // fails before the explicit release.
      await writeFile(releaseFilePath, "release\n", "utf8").catch(() => {});
      await app.close();
    }
  });

  // Windows and Linux need the installed tray to outlive their last window;
  // otherwise the enabled preference disappears together with Main and cannot
  // reopen Comma. A later operating-system launch must also reach the retained
  // single-instance owner and restore its primary window. The OS fixture drives
  // the production quit decision while the macOS CI runner still executes the
  // real Electron/Tray lifecycle.
  test("keeps non-macOS Main alive only while the system tray is installed", async () => {
    test.setTimeout(120_000);
    const enabledUserDataPath = join(testDirectory, "tray-enabled-user-data");
    const openMainBlockedMarkerFilePath = join(testDirectory, "tray-open-main-blocked");
    const openMainReleaseFilePath = join(testDirectory, "tray-open-main-release");
    let secondInstanceProcess: ReturnType<typeof spawn> | undefined;
    let secondInstanceCompletion: Promise<number> | undefined;
    let secondInstanceOutput = "";
    const enabledApp = await electron.launch({
      args: electronLaunchArgs(enabledUserDataPath),
      cwd: electronAppDir,
      env: signedInElectronEnv(enabledUserDataPath, {
        COMMA_ELECTRON_E2E_OPERATING_SYSTEM: "linux",
        COMMA_ELECTRON_E2E_STATUS_TRAY_OPEN_MAIN_BLOCKED_MARKER_FILE_PATH:
          openMainBlockedMarkerFilePath,
        COMMA_ELECTRON_E2E_STATUS_TRAY_OPEN_MAIN_RELEASE_FILE_PATH:
          openMainReleaseFilePath,
      }),
    });

    try {
      const mainWindow = await openAppSettings(enabledApp);
      await expect
        .poll(() => readRendererPreferences(mainWindow))
        .toMatchObject({ showInMenuBar: true });
      await expect.poll(() => fileExists(openMainBlockedMarkerFilePath)).toBe(true);

      await enabledApp.evaluate(({ BrowserWindow }) => {
        const windows = BrowserWindow.getAllWindows();
        if (windows.length !== 1) {
          throw new Error(
            `Expected one Linux-fixture window, found ${windows.length}.`
          );
        }
        windows[0]!.close();
      });
      await expect
        .poll(() =>
          enabledApp.evaluate(
            ({ BrowserWindow }) => BrowserWindow.getAllWindows().length
          )
        )
        .toBe(0);
      await expect(enabledApp.evaluate(() => "alive")).resolves.toBe("alive");

      await writeFile(openMainReleaseFilePath, "open\n", "utf8");
      const replacement = await openAppSettings(enabledApp);
      await expect
        .poll(() => readRendererPreferences(replacement))
        .toMatchObject({ showInMenuBar: true });

      await enabledApp.evaluate(({ BrowserWindow }) => {
        const windows = BrowserWindow.getAllWindows();
        if (windows.length !== 1) {
          throw new Error(
            `Expected one replacement Linux-fixture window, found ${windows.length}.`
          );
        }
        windows[0]!.close();
      });
      await expect
        .poll(() =>
          enabledApp.evaluate(
            ({ BrowserWindow }) => BrowserWindow.getAllWindows().length
          )
        )
        .toBe(0);

      const residentProcessId = enabledApp.process().pid;
      expect(residentProcessId).toBeDefined();
      expect(
        await enabledApp.evaluate(({ app }) => app.listenerCount("activate"))
      ).toBe(0);
      expect(
        await enabledApp.evaluate(({ app }) => app.listenerCount("second-instance"))
      ).toBeGreaterThan(0);
      const electronExecutable = await enabledApp.evaluate(() => process.execPath);
      const relaunchedWindow = findElectronWindowByNativeRole(
        enabledApp,
        "main-window",
        30_000
      );
      secondInstanceProcess = spawn(
        electronExecutable,
        electronLaunchArgs(enabledUserDataPath),
        {
          cwd: electronAppDir,
          env: persistedSessionElectronEnv(enabledUserDataPath, {
            COMMA_ELECTRON_E2E_OPERATING_SYSTEM: "linux",
          }),
          stdio: ["ignore", "pipe", "pipe"],
        }
      );
      secondInstanceProcess.stdout?.on("data", (chunk) => {
        secondInstanceOutput += chunk.toString();
      });
      secondInstanceProcess.stderr?.on("data", (chunk) => {
        secondInstanceOutput += chunk.toString();
      });
      secondInstanceCompletion = waitForChildClose(
        secondInstanceProcess,
        () => secondInstanceOutput
      );

      const [secondInstanceExitCode, relaunched] = await Promise.all([
        withTimeout(
          secondInstanceCompletion,
          30_000,
          () =>
            `Timed out waiting for the second Electron instance to exit.\n${secondInstanceOutput}`
        ),
        relaunchedWindow,
      ]);
      expect(secondInstanceExitCode).toBe(0);
      expect(enabledApp.process().pid).toBe(residentProcessId);
      await relaunched.waitForLoadState("domcontentloaded");
      await relaunched.evaluate(() => {
        window.location.hash = "#/settings";
      });
      await expect(
        relaunched.getByRole("heading", { level: 1, name: "General" })
      ).toBeVisible();
      await expect
        .poll(() => readRendererPreferences(relaunched))
        .toMatchObject({ showInMenuBar: true });
    } finally {
      try {
        if (secondInstanceProcess && secondInstanceCompletion) {
          await stopChildProcess(
            secondInstanceProcess,
            secondInstanceCompletion,
            () => secondInstanceOutput
          );
        }
      } finally {
        await writeFile(openMainReleaseFilePath, "open\n", "utf8").catch(() => {});
        await enabledApp.close().catch(() => {});
      }
    }

    const disabledUserDataPath = join(testDirectory, "tray-disabled-user-data");
    await mkdir(disabledUserDataPath, { recursive: true });
    await writeFile(
      join(disabledUserDataPath, "app-preferences.json"),
      `${JSON.stringify(
        {
          launchAtLogin: false,
          showInDock: true,
          showInMenuBar: false,
        },
        null,
        2
      )}\n`,
      "utf8"
    );
    const disabledApp = await electron.launch({
      args: electronLaunchArgs(disabledUserDataPath),
      cwd: electronAppDir,
      env: signedInElectronEnv(disabledUserDataPath, {
        COMMA_ELECTRON_E2E_OPERATING_SYSTEM: "linux",
      }),
    });
    let disabledAppClosed = false;

    try {
      await findElectronWindowByNativeRole(disabledApp, "main-window");
      const closed = disabledApp.waitForEvent("close");
      await disabledApp.evaluate(({ BrowserWindow }) => {
        const windows = BrowserWindow.getAllWindows();
        if (windows.length !== 1) {
          throw new Error(
            `Expected one Linux-fixture window, found ${windows.length}.`
          );
        }
        windows[0]!.close();
      });
      await closed;
      disabledAppClosed = true;
    } finally {
      if (!disabledAppClosed) await disabledApp.close().catch(() => {});
    }
  });

  // A state subscription installs its event listener before requesting the
  // initial snapshot. If that snapshot is captured before a later mutation but
  // delivered afterward, it must not roll the renderer back behind the event.
  test("rejects a delayed initial replay after a newer preference event", async () => {
    const userDataPath = join(testDirectory, "replay-user-data");
    const stateBlockedMarkerFilePath = join(testDirectory, "state-blocked");
    const stateReleaseFilePath = join(testDirectory, "state-release");
    // Let the app's normal StrictMode subscriptions initialize first. The test
    // then rearms the same Main gate around one explicitly owned subscription,
    // so the captured revision and listener lifetime are both unambiguous.
    await writeFile(stateReleaseFilePath, "release\n", "utf8");
    const env = signedInElectronEnv(userDataPath, {
      COMMA_ELECTRON_E2E_APP_PREFERENCES_STATE_BLOCKED_MARKER_FILE_PATH:
        stateBlockedMarkerFilePath,
      COMMA_ELECTRON_E2E_APP_PREFERENCES_STATE_RELEASE_FILE_PATH: stateReleaseFilePath,
      COMMA_ELECTRON_E2E_OPERATING_SYSTEM: "macos",
    });
    const app = await electron.launch({
      args: electronLaunchArgs(userDataPath),
      cwd: electronAppDir,
      env,
    });

    try {
      const mainWindow = await openAppSettings(app);
      await expect
        .poll(() => readRendererPreferences(mainWindow))
        .toMatchObject({ clientSettings: expect.any(Object), showInMenuBar: true });
      const initialRevision = (await readRendererPreferences(mainWindow)).revision;
      await rm(stateBlockedMarkerFilePath, { force: true });
      await rm(stateReleaseFilePath, { force: true });

      await mainWindow.evaluate(() => {
        const target = window as unknown as {
          commaNative: {
            appPreferences: {
              state: {
                subscribe(listener: (snapshot: AppPreferences) => void): () => void;
              };
            };
          };
          preferenceReplaySnapshots?: AppPreferences[];
          unsubscribePreferenceReplay?: () => void;
        };
        target.preferenceReplaySnapshots = [];
        target.unsubscribePreferenceReplay =
          target.commaNative.appPreferences.state.subscribe((snapshot) => {
            target.preferenceReplaySnapshots?.push(snapshot);
          });
      });
      await expect.poll(() => fileExists(stateBlockedMarkerFilePath)).toBe(true);

      await mainWindow.evaluate(() =>
        (
          window as unknown as {
            commaNative: {
              appPreferences: {
                update(input: { showInMenuBar: boolean }): Promise<unknown>;
              };
            };
          }
        ).commaNative.appPreferences.update({ showInMenuBar: false })
      );
      await expect(
        mainWindow.getByRole("switch", { name: "Show in menu bar" })
      ).not.toBeChecked();
      await expect(
        mainWindow.getByRole("switch", { name: "Show in menu bar" })
      ).toBeEnabled();
      await expect
        .poll(() => readReplaySnapshots(mainWindow))
        .toEqual([{ revision: initialRevision + 1, showInMenuBar: false }]);

      const replaySuperseded = mainWindow.waitForEvent(
        "console",
        (message) =>
          message.text() ===
          "[native-bridge] comma:app-preferences:state replay superseded by a live event"
      );
      await writeFile(stateReleaseFilePath, "release\n", "utf8");
      await replaySuperseded;

      expect(await readReplaySnapshots(mainWindow)).toEqual([
        { revision: initialRevision + 1, showInMenuBar: false },
      ]);
      await expect(
        mainWindow.getByRole("switch", { name: "Show in menu bar" })
      ).not.toBeChecked();
      await expect
        .poll(() => readRendererPreferences(mainWindow))
        .toMatchObject({ revision: initialRevision + 1, showInMenuBar: false });
    } finally {
      await writeFile(stateReleaseFilePath, "release\n", "utf8").catch(() => {});
      await app.close();
    }
  });

  // macOS can accept the registration request while SMAppService still reports
  // requires-approval. The UI must render the read-back truth, preserve the
  // pending native registration for System Settings approval, and keep that
  // actionable state across restart.
  test("retains and surfaces a macOS login item awaiting approval", async () => {
    const userDataPath = join(testDirectory, "login-item-user-data");
    const approvedMarkerFilePath = join(testDirectory, "login-item-approved");
    const disabledMarkerFilePath = join(testDirectory, "login-item-disabled");
    const registeredMarkerFilePath = join(testDirectory, "login-item-registered");
    await mkdir(userDataPath, { recursive: true });
    await writeFile(
      join(userDataPath, "app-preferences.json"),
      `${JSON.stringify(
        {
          launchAtLogin: false,
          showInDock: true,
          showInMenuBar: true,
        },
        null,
        2
      )}\n`,
      "utf8"
    );
    const envOverrides = {
      COMMA_ELECTRON_E2E_LAUNCH_AT_LOGIN_APPROVED_MARKER_FILE_PATH:
        approvedMarkerFilePath,
      COMMA_ELECTRON_E2E_LAUNCH_AT_LOGIN_DISABLED_MARKER_FILE_PATH:
        disabledMarkerFilePath,
      COMMA_ELECTRON_E2E_LAUNCH_AT_LOGIN_REGISTERED_MARKER_FILE_PATH:
        registeredMarkerFilePath,
      COMMA_ELECTRON_E2E_LAUNCH_AT_LOGIN_STATUS: "requires-approval",
      COMMA_ELECTRON_E2E_OPERATING_SYSTEM: "macos",
    };
    const env = signedInElectronEnv(userDataPath, envOverrides);

    const app = await electron.launch({
      args: electronLaunchArgs(userDataPath),
      cwd: electronAppDir,
      env,
    });
    try {
      const mainWindow = await openAppSettings(app);
      const launchAtLogin = mainWindow.getByRole("switch", {
        name: "Launch Comma at login",
      });
      await expect(launchAtLogin).toBeEnabled();
      await expect(launchAtLogin).not.toBeChecked();

      await activateSwitch(launchAtLogin);
      await expect.poll(() => fileExists(registeredMarkerFilePath)).toBe(true);
      await mainWindow.waitForTimeout(150);

      await expect(launchAtLogin).toBeDisabled();
      await expect(launchAtLogin).not.toBeChecked();
      await expect(
        mainWindow.getByText(
          "Approval is required in System Settings > General > Login Items."
        )
      ).toBeVisible();
      expect(await fileExists(disabledMarkerFilePath)).toBe(false);
      await expect
        .poll(() => readRendererPreferences(mainWindow))
        .toMatchObject({
          launchAtLogin: false,
          launchAtLoginStatus: "requires-approval",
        });
      expect(
        JSON.parse(await readFile(join(userDataPath, "app-preferences.json"), "utf8"))
      ).toMatchObject({ launchAtLogin: false });
    } finally {
      await app.close();
    }

    const restarted = await electron.launch({
      args: electronLaunchArgs(userDataPath),
      cwd: electronAppDir,
      env: persistedSessionElectronEnv(userDataPath, envOverrides),
    });
    try {
      const mainWindow = await openAppSettings(restarted);
      const launchAtLogin = mainWindow.getByRole("switch", {
        name: "Launch Comma at login",
      });
      await expect(launchAtLogin).toBeDisabled();
      await expect(launchAtLogin).not.toBeChecked();
      await expect(
        mainWindow.getByText(
          "Approval is required in System Settings > General > Login Items."
        )
      ).toBeVisible();
      await expect
        .poll(() => readRendererPreferences(mainWindow))
        .toMatchObject({
          launchAtLogin: false,
          launchAtLoginStatus: "requires-approval",
        });
      expect(await fileExists(registeredMarkerFilePath)).toBe(true);
      expect(await fileExists(disabledMarkerFilePath)).toBe(false);

      // Model approval in System Settings, then the user returning to Comma. The
      // focus refresh must replace the pending snapshot without a remount.
      await writeFile(approvedMarkerFilePath, "approved\n", "utf8");
      await mainWindow.evaluate(() => window.dispatchEvent(new Event("focus")));
      await expect(launchAtLogin).toBeEnabled();
      await expect(launchAtLogin).toBeChecked();
      await expect(
        mainWindow.getByText(
          "Approval is required in System Settings > General > Login Items."
        )
      ).toHaveCount(0);
      await expect
        .poll(() => readRendererPreferences(mainWindow))
        .toMatchObject({
          launchAtLogin: true,
          launchAtLoginStatus: "enabled",
        });
    } finally {
      await restarted.close();
    }
  });

  test("waits for Login Items approval before keeping the Mac awake with the lid closed", async () => {
    const userDataPath = join(testDirectory, "keep-awake-user-data");
    const sleepGuardDirectory = join(testDirectory, "sleep-guard");
    await mkdir(sleepGuardDirectory, { recursive: true });
    const envOverrides = {
      COMMA_ELECTRON_E2E_OPERATING_SYSTEM: "macos",
      COMMA_ELECTRON_E2E_SLEEP_GUARD_DIRECTORY: sleepGuardDirectory,
    };
    const held = () => fileExists(join(sleepGuardDirectory, "held"));

    const app = await electron.launch({
      args: electronLaunchArgs(userDataPath),
      cwd: electronAppDir,
      env: signedInElectronEnv(userDataPath, envOverrides),
    });
    try {
      const mainWindow = await openAppSettings(app);
      const keepAwake = mainWindow.getByRole("switch", {
        name: "Keep awake with lid closed",
      });
      await expect(keepAwake).toBeEnabled();
      await expect(keepAwake).not.toBeChecked();

      // Turning it on registers the daemon; macOS then waits for the user.
      await activateSwitch(keepAwake);
      const dialog = mainWindow.getByRole("dialog", {
        name: "Allow Comma in Login Items",
      });
      await expect(dialog).toBeVisible();
      expect(await fileExists(join(sleepGuardDirectory, "registered"))).toBe(true);
      await dialog.getByRole("button", { name: "Open System Settings" }).click();
      await expect
        .poll(() => fileExists(join(sleepGuardDirectory, "login-items-opened")))
        .toBe(true);
      await expect(keepAwake).not.toBeChecked();
      await expect(
        mainWindow.getByText("Waiting for your approval.", { exact: false })
      ).toBeVisible();
      expect(await held()).toBe(false);

      // Model approval in Login Items, then the user returning to Comma.
      await writeFile(join(sleepGuardDirectory, "approved"), "approved\n", "utf8");
      await mainWindow.evaluate(() => window.dispatchEvent(new Event("focus")));
      await expect(keepAwake).toBeChecked();
      await expect.poll(held).toBe(true);
      await expect
        .poll(() => readRendererPreferences(mainWindow))
        .toMatchObject({
          keepAwakeWhenLidClosed: true,
          keepAwakeWhenLidClosedStatus: "available",
        });
    } finally {
      await app.close();
    }

    // The fake stands in for the daemon, so model the hold ending with Comma.
    await rm(join(sleepGuardDirectory, "held"), { force: true });
    const restarted = await electron.launch({
      args: electronLaunchArgs(userDataPath),
      cwd: electronAppDir,
      env: persistedSessionElectronEnv(userDataPath, envOverrides),
    });
    try {
      const mainWindow = await openAppSettings(restarted);
      const keepAwake = mainWindow.getByRole("switch", {
        name: "Keep awake with lid closed",
      });
      // An approved choice resumes at launch.
      await expect(keepAwake).toBeChecked();
      await expect.poll(held).toBe(true);

      await activateSwitch(keepAwake);
      await expect(keepAwake).not.toBeChecked();
      await expect.poll(held).toBe(false);
    } finally {
      await restarted.close();
    }
  });

  // Each Main window owns an independent renderer hook, while Main owns one
  // serialized preference transaction stream. Concurrent patches must merge
  // against the latest commit, publish to both windows, and survive restart.
  test("serializes preference updates from two Main windows", async () => {
    // This scenario owns two full Electron lifecycles. Keep each locator and
    // gate assertion bounded while allowing both launches to finish on mac CI.
    test.setTimeout(120_000);
    const userDataPath = join(testDirectory, "concurrent-user-data");
    const dockBlockedMarkerFilePath = join(testDirectory, "dock-update-blocked");
    const dockReleaseFilePath = join(testDirectory, "dock-update-release");
    const menuHiddenMarkerFilePath = join(testDirectory, "menu-bar-hidden");
    const updateAckBlockedMarkerFilePath = join(testDirectory, "update-ack-blocked");
    const updateAckReleaseFilePath = join(testDirectory, "update-ack-release");
    const envOverrides = {
      COMMA_ELECTRON_E2E_APP_PREFERENCES_UPDATE_ACK_BLOCKED_MARKER_FILE_PATH:
        updateAckBlockedMarkerFilePath,
      COMMA_ELECTRON_E2E_APP_PREFERENCES_UPDATE_ACK_RELEASE_FILE_PATH:
        updateAckReleaseFilePath,
      COMMA_ELECTRON_E2E_DOCK_UPDATE_BLOCKED_MARKER_FILE_PATH:
        dockBlockedMarkerFilePath,
      COMMA_ELECTRON_E2E_DOCK_UPDATE_RELEASE_FILE_PATH: dockReleaseFilePath,
      COMMA_ELECTRON_E2E_MENU_BAR_HIDDEN_MARKER_FILE_PATH: menuHiddenMarkerFilePath,
      COMMA_ELECTRON_E2E_OPERATING_SYSTEM: "macos",
    };
    const env = signedInElectronEnv(userDataPath, envOverrides);
    const app = await electron.launch({
      args: electronLaunchArgs(userDataPath),
      cwd: electronAppDir,
      env,
    });

    try {
      const mainWindow = await openAppSettings(app);
      await mainWindow.evaluate(() =>
        (
          window as unknown as {
            commaNative: {
              windows: { create(input: { route: string }): Promise<unknown> };
            };
          }
        ).commaNative.windows.create({ route: "/settings" })
      );
      // Side Chat and its child surfaces can appear concurrently. Select the
      // requested product window by its frozen identity instead of racing the
      // first generic Playwright `window` event.
      const secondWindow = await findElectronWindowByNativeId(app, /^win_dynamic_/);
      await expect(
        secondWindow.getByRole("heading", { level: 1, name: "General" })
      ).toBeVisible();
      const initialRevision = (await readRendererPreferences(mainWindow)).revision;

      await activateSwitch(mainWindow.getByRole("switch", { name: "Show in dock" }));
      await expect.poll(() => fileExists(dockBlockedMarkerFilePath)).toBe(true);

      await activateSwitch(
        secondWindow.getByRole("switch", { name: "Show in menu bar" })
      );
      await expect(
        secondWindow.getByRole("switch", { name: "Show in menu bar" })
      ).toBeDisabled();
      expect(await fileExists(menuHiddenMarkerFilePath)).toBe(false);
      await expect
        .poll(() => readRendererPreferences(secondWindow))
        .toMatchObject({ showInDock: true, showInMenuBar: true });

      await writeFile(dockReleaseFilePath, "release\n", "utf8");
      await expect.poll(() => fileExists(menuHiddenMarkerFilePath)).toBe(true);
      await expect.poll(() => fileExists(updateAckBlockedMarkerFilePath)).toBe(true);

      for (const window of [mainWindow, secondWindow]) {
        await expect
          .poll(() => readRendererPreferences(window))
          .toMatchObject({
            revision: initialRevision + 2,
            showInDock: false,
            showInMenuBar: false,
          });
      }

      // Only the older Dock acknowledgement is delayed. The newer Menu Bar
      // caller must settle while both renderers retain revision 2.
      await expect(
        secondWindow.getByRole("switch", { name: "Show in menu bar" })
      ).toBeEnabled();
      await expect(
        mainWindow.getByRole("switch", { name: "Show in dock" })
      ).toBeDisabled();

      await writeFile(updateAckReleaseFilePath, "release\n", "utf8");
      await expect(
        mainWindow.getByRole("switch", { name: "Show in dock" })
      ).toBeEnabled();
      await expect(
        secondWindow.getByRole("switch", { name: "Show in menu bar" })
      ).toBeEnabled();

      for (const window of [mainWindow, secondWindow]) {
        await expect(
          window.getByRole("switch", { name: "Show in dock" })
        ).not.toBeChecked();
        await expect(
          window.getByRole("switch", { name: "Show in menu bar" })
        ).not.toBeChecked();
        await expect
          .poll(() => readRendererPreferences(window))
          .toMatchObject({
            revision: initialRevision + 2,
            showInDock: false,
            showInMenuBar: false,
          });
      }

      expect(
        JSON.parse(await readFile(join(userDataPath, "app-preferences.json"), "utf8"))
      ).toMatchObject({
        showInDock: false,
        showInMenuBar: false,
      });

      const secondWindowId = await secondWindow.evaluate(
        () =>
          (
            window as unknown as {
              commaNative?: { self?: { windowId: string } };
            }
          ).commaNative?.self?.windowId
      );
      expect(secondWindowId).toMatch(/^win_dynamic_/);
      await mainWindow.evaluate(
        (windowId) =>
          (
            window as unknown as {
              commaNative: {
                windows: {
                  close(input: { windowId: string }): Promise<unknown>;
                };
              };
            }
          ).commaNative.windows.close({ windowId }),
        secondWindowId!
      );
      await expect.poll(() => secondWindow.isClosed()).toBe(true);
    } finally {
      await writeFile(dockReleaseFilePath, "release\n", "utf8").catch(() => {});
      await writeFile(updateAckReleaseFilePath, "release\n", "utf8").catch(() => {});
      await app.close();
    }

    const restarted = await electron.launch({
      args: electronLaunchArgs(userDataPath),
      cwd: electronAppDir,
      env: persistedSessionElectronEnv(userDataPath, envOverrides),
    });
    try {
      const mainWindow = await openAppSettings(restarted);
      await expect(
        mainWindow.getByRole("switch", { name: "Show in dock" })
      ).not.toBeChecked();
      await expect(
        mainWindow.getByRole("switch", { name: "Show in menu bar" })
      ).not.toBeChecked();
      await expect
        .poll(() => readRendererPreferences(mainWindow))
        .toMatchObject({
          revision: 0,
          showInDock: false,
          showInMenuBar: false,
        });
    } finally {
      await restarted.close();
    }
  });

  // Quit seals preference admission and waits for every already accepted
  // mutation to commit or roll back. A blocked native setter therefore keeps
  // Main alive until persistence finishes, and restart must observe that commit.
  test("drains an accepted preference update before graceful quit", async () => {
    // This scenario deliberately performs two complete Electron launches and a
    // blocked graceful-quit drain. Loaded CI shards can exceed the default 45s.
    test.slow();
    const userDataPath = join(testDirectory, "drain-user-data");
    const dockBlockedMarkerFilePath = join(testDirectory, "drain-dock-blocked");
    const dockReleaseFilePath = join(testDirectory, "drain-dock-release");
    const drainStartedMarkerFilePath = join(testDirectory, "drain-started");
    const preferencesFilePath = join(userDataPath, "app-preferences.json");
    await mkdir(userDataPath, { recursive: true });
    await writeFile(
      preferencesFilePath,
      `${JSON.stringify(
        {
          launchAtLogin: false,
          showInDock: true,
          showInMenuBar: true,
        },
        null,
        2
      )}\n`,
      "utf8"
    );
    const env = signedInElectronEnv(userDataPath, {
      COMMA_ELECTRON_E2E_APP_PREFERENCES_DRAIN_STARTED_MARKER_FILE_PATH:
        drainStartedMarkerFilePath,
      COMMA_ELECTRON_E2E_DOCK_UPDATE_BLOCKED_MARKER_FILE_PATH:
        dockBlockedMarkerFilePath,
      COMMA_ELECTRON_E2E_DOCK_UPDATE_RELEASE_FILE_PATH: dockReleaseFilePath,
      COMMA_ELECTRON_E2E_OPERATING_SYSTEM: "macos",
    });
    const app = await electron.launch({
      args: electronLaunchArgs(userDataPath),
      cwd: electronAppDir,
      env,
    });
    let appClosed = false;

    try {
      const mainWindow = await openAppSettings(app);
      const dockToggle = mainWindow.getByRole("switch", { name: "Show in dock" });
      await expect(dockToggle).toBeChecked();
      await activateSwitch(dockToggle);
      await expect.poll(() => fileExists(dockBlockedMarkerFilePath)).toBe(true);

      const closed = app.waitForEvent("close");
      await app.evaluate(({ app: electronApp }) => electronApp.quit());
      await expect.poll(() => fileExists(drainStartedMarkerFilePath)).toBe(true);

      expect(app.process().exitCode).toBeNull();
      expect(JSON.parse(await readFile(preferencesFilePath, "utf8"))).toMatchObject({
        showInDock: true,
      });

      await writeFile(dockReleaseFilePath, "release\n", "utf8");
      await closed;
      appClosed = true;
      expect(JSON.parse(await readFile(preferencesFilePath, "utf8"))).toMatchObject({
        showInDock: false,
      });

      const restarted = await electron.launch({
        args: electronLaunchArgs(userDataPath),
        cwd: electronAppDir,
        env: persistedSessionElectronEnv(userDataPath, {
          COMMA_ELECTRON_E2E_OPERATING_SYSTEM: "macos",
        }),
      });
      try {
        const restartedWindow = await openAppSettings(restarted);
        await expect(
          restartedWindow.getByRole("switch", { name: "Show in dock" })
        ).not.toBeChecked();
        await expect
          .poll(() => readRendererPreferences(restartedWindow))
          .toMatchObject({ revision: 0, showInDock: false });
      } finally {
        await restarted.close();
      }
    } finally {
      await writeFile(dockReleaseFilePath, "release\n", "utf8").catch(() => {});
      if (!appClosed) await app.close().catch(() => {});
    }
  });
});

function signedInElectronEnv(
  userDataPath: string,
  overrides: Record<string, string> = {}
) {
  recordElectronOnboardingCompleted(userDataPath, [sessionStub.userId]);
  return electronEnv(userDataPath, {
    COMMA_ELECTRON_STARTUP_SESSION_TOKEN: PREFERENCES_E2E_TOKEN,
    ...overrides,
  });
}

function persistedSessionElectronEnv(
  userDataPath: string,
  overrides: Record<string, string> = {}
) {
  return electronEnv(userDataPath, overrides);
}

function electronEnv(userDataPath: string, overrides: Record<string, string>) {
  const {
    COMMA_ELECTRON_STARTUP_SESSION_TOKEN: _sessionToken,
    ELECTRON_RUN_AS_NODE: _electronRunAsNode,
    ...env
  } = process.env;
  return {
    ...env,
    COMMA_API_BASE_URL: sessionStub.baseUrl,
    COMMA_ELECTRON_STARTUP_SESSION_EMAIL: PREFERENCES_E2E_EMAIL,
    NODE_ENV: "test",
    ...overrides,
  };
}

function electronLaunchArgs(userDataPath: string) {
  // Chromium resolves its profile before Main can apply the matching E2E
  // app.setPath hook. Passing it on the command line keeps every launch and
  // immediate relaunch inside the same isolated profile from process startup.
  return [electronMain, "--lang=en-US", `--user-data-dir=${userDataPath}`];
}

async function openAppSettings(
  app: Parameters<typeof findElectronWindowByNativeRole>[0]
) {
  const mainWindow = await findElectronWindowByNativeRole(app, "main-window");
  await mainWindow.waitForLoadState("domcontentloaded");
  await mainWindow.evaluate(() => {
    window.location.hash = "#/settings";
  });
  await expect(
    mainWindow.getByRole("heading", { level: 1, name: "General" })
  ).toBeVisible();
  return mainWindow;
}

function readRendererPreferences(page: Awaited<ReturnType<typeof openAppSettings>>) {
  return page.evaluate(() =>
    (
      window as unknown as {
        commaNative: {
          appPreferences: {
            state: { get(): Promise<AppPreferences> };
          };
        };
      }
    ).commaNative.appPreferences.state.get()
  );
}

function updateRendererPreferences(
  page: Awaited<ReturnType<typeof openAppSettings>>,
  patch: AppPreferencesPatch
) {
  return page.evaluate(
    (input) =>
      (
        window as unknown as {
          commaNative: {
            appPreferences: {
              update(input: AppPreferencesPatch): Promise<AppPreferences>;
            };
          };
        }
      ).commaNative.appPreferences.update(input),
    patch
  );
}

function waitForChildClose(child: ReturnType<typeof spawn>, output: () => string) {
  return new Promise<number>((resolveExit, rejectExit) => {
    child.once("error", (error) => {
      rejectExit(error);
    });
    child.once("close", (code, signal) => {
      if (code === null) {
        rejectExit(
          new Error(
            `The second Electron instance exited via ${signal ?? "unknown signal"}.\n${output()}`
          )
        );
        return;
      }
      if (code !== 0) {
        rejectExit(
          new Error(
            `The second Electron instance exited with code ${code}.\n${output()}`
          )
        );
        return;
      }
      resolveExit(code);
    });
  });
}

function withTimeout<Result>(
  promise: Promise<Result>,
  timeoutMs: number,
  timeoutMessage: () => string
) {
  return new Promise<Result>((resolveResult, rejectResult) => {
    const timeout = setTimeout(() => {
      rejectResult(new Error(timeoutMessage()));
    }, timeoutMs);
    promise.then(
      (result) => {
        clearTimeout(timeout);
        resolveResult(result);
      },
      (error: unknown) => {
        clearTimeout(timeout);
        rejectResult(error);
      }
    );
  });
}

async function stopChildProcess(
  child: ReturnType<typeof spawn>,
  completion: Promise<number>,
  output: () => string
) {
  const settled = completion.then(
    () => undefined,
    () => undefined
  );
  if (child.pid === undefined) {
    await settlesWithin(settled, 100);
    return;
  }

  if (!childHasStopped(child)) {
    child.kill("SIGTERM");
    if (!(await waitForChildStop(child, 2_000))) {
      child.kill("SIGKILL");
      if (!(await waitForChildStop(child, 5_000))) {
        child.stdout?.destroy();
        child.stderr?.destroy();
        throw new Error(
          `Unable to terminate the second Electron instance.\n${output()}`
        );
      }
    }
  }

  if (await settlesWithin(settled, 1_000)) return;

  child.stdout?.destroy();
  child.stderr?.destroy();
  await settlesWithin(settled, 1_000);
}

function childHasStopped(child: ReturnType<typeof spawn>) {
  return child.exitCode !== null || child.signalCode !== null;
}

async function waitForChildStop(child: ReturnType<typeof spawn>, timeoutMs: number) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (childHasStopped(child)) return true;
    await delay(50);
  }
  return childHasStopped(child);
}

function settlesWithin(promise: Promise<unknown>, timeoutMs: number) {
  return Promise.race([promise.then(() => true), delay(timeoutMs).then(() => false)]);
}

function readReplaySnapshots(page: Awaited<ReturnType<typeof openAppSettings>>) {
  return page.evaluate(() =>
    (
      window as unknown as {
        preferenceReplaySnapshots?: AppPreferences[];
      }
    ).preferenceReplaySnapshots?.map(({ revision, showInMenuBar }) => ({
      revision,
      showInMenuBar,
    }))
  );
}

/** Whether Window > Open Side Chat is shown in the application menu. */
function sideChatMenuItemVisible(
  app: Parameters<typeof findElectronWindowByNativeRole>[0]
) {
  return app.evaluate(
    ({ Menu }) =>
      Menu.getApplicationMenu()?.getMenuItemById("open-side-chat")?.visible ?? null
  );
}

async function activateSwitch(toggle: Locator) {
  await expect(toggle).toBeEnabled();
  // React Aria renders the semantic switch input behind its label/track. A
  // pointer click on the input is correctly hit-tested as intercepted on macOS
  // CI, so exercise the same accessible control through its keyboard contract.
  await toggle.press("Space", { timeout: 8_000 });
}

/** Writes an empty Task scene through the renderer's Notch bridge. */
function writeNotchScene(page: Awaited<ReturnType<typeof openAppSettings>>) {
  return page.evaluate(() =>
    (
      window as unknown as {
        commaNative: {
          notch: {
            update(input: { hasActivity: boolean; tasks: [] }): Promise<{
              payload?: { running?: boolean };
            }>;
          };
        };
      }
    ).commaNative.notch.update({ hasActivity: false, tasks: [] })
  );
}

async function fileExists(filePath: string) {
  try {
    await access(filePath);
    return true;
  } catch {
    return false;
  }
}
