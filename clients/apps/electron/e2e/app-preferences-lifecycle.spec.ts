import { type ElectronApplication, type Locator } from "@playwright/test";
import { electron, expect, test } from "./electron-test";
import { closeElectronWindow, quitElectronApp } from "./electron-operations";
import { closeElectronTestApp } from "./close-electron-test-app";
import type { AppPreferences } from "@comma/native-bridge";
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

/** The app's one window; an app with any other number fails the test. */
const onlyWindow = (app: ElectronApplication) =>
  app.evaluateHandle(({ BrowserWindow }) => {
    const windows = BrowserWindow.getAllWindows();
    if (windows.length !== 1)
      throw new Error(`Expected one Linux-fixture window, found ${windows.length}.`);
    return windows[0]!;
  });

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

  // The status tray preference is loaded while Main's services are composing,
  // but its Settings action must not become interactive until every initial
  // window and handler is ready. The test-only release gate pauses that exact
  // boundary; activating the real tray Settings callback on installation
  // proves it is published only after the gate has opened.
  // @mac only: on Linux under Xvfb, about 1 run in 16 the main window's renderer
  // stops answering after BrowserWindow.hide() (its main thread blocks in a
  // native wait), so the test does not run on Linux until that is understood.
  test(
    "publishes status tray Settings only after Main startup is ready",
    { tag: "@mac" },
    async () => {
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
        await expect.poll(() => fileExists(blockedMarkerFilePath)).toBe(true);
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
      } finally {
        // Never strand Main behind the deterministic gate if an assertion above
        // fails before the explicit release.
        await writeFile(releaseFilePath, "release\n", "utf8").catch(() => {});
        await closeElectronTestApp(app);
      }
    }
  );

  // Windows and Linux need the installed tray to outlive their last window;
  // otherwise the enabled preference disappears together with Main and cannot
  // reopen Comma. A later operating-system launch must also reach the retained
  // single-instance owner and restore its primary window. The OS fixture drives
  // the production quit decision while the macOS CI runner still executes the
  // real Electron/Tray lifecycle.
  test("keeps non-macOS Main alive only while the system tray is installed", async () => {
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

      expect(await closeElectronWindow(enabledApp, await onlyWindow(enabledApp))).toBe(
        "closed"
      );
      expect(
        await enabledApp.evaluate(
          ({ BrowserWindow }) => BrowserWindow.getAllWindows().length
        )
      ).toBe(0);
      await expect(enabledApp.evaluate(() => "alive")).resolves.toBe("alive");

      await writeFile(openMainReleaseFilePath, "open\n", "utf8");
      const replacement = await openAppSettings(enabledApp);
      await expect
        .poll(() => readRendererPreferences(replacement))
        .toMatchObject({ showInMenuBar: true });

      expect(await closeElectronWindow(enabledApp, await onlyWindow(enabledApp))).toBe(
        "closed"
      );
      expect(
        await enabledApp.evaluate(
          ({ BrowserWindow }) => BrowserWindow.getAllWindows().length
        )
      ).toBe(0);

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
        await closeElectronTestApp(enabledApp).catch(() => {});
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
      await closeElectronWindow(disabledApp, await onlyWindow(disabledApp));
      await closed;
      disabledAppClosed = true;
    } finally {
      if (!disabledAppClosed) await closeElectronTestApp(disabledApp).catch(() => {});
    }
  });

  // Each Main window owns an independent renderer hook, while Main owns one
  // serialized preference transaction stream. Concurrent patches must merge
  // against the latest commit, publish to both windows, and survive restart.
  test(
    "serializes preference updates from two Main windows",
    { tag: "@mac" },
    async () => {
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
        // Select the requested product window by its frozen identity instead
        // of racing the first generic Playwright `window` event.
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
        await closeElectronTestApp(app);
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
        await closeElectronTestApp(restarted);
      }
    }
  );

  // Quit seals preference admission and waits for every already accepted
  // mutation to commit or roll back. A blocked native setter therefore keeps
  // Main alive until persistence finishes, and restart must observe that commit.
  test(
    "drains an accepted preference update before graceful quit",
    { tag: "@mac" },
    async () => {
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
        await quitElectronApp(app);
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
          await closeElectronTestApp(restarted);
        }
      } finally {
        await writeFile(dockReleaseFilePath, "release\n", "utf8").catch(() => {});
        if (!appClosed) await closeElectronTestApp(app).catch(() => {});
      }
    }
  );
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

async function activateSwitch(toggle: Locator) {
  await expect(toggle).toBeEnabled();
  // React Aria renders the semantic switch input behind its label/track. A
  // pointer click on the input is correctly hit-tested as intercepted on macOS
  // CI, so exercise the same accessible control through its keyboard contract.
  await toggle.press("Space");
}

async function fileExists(filePath: string) {
  try {
    await access(filePath);
    return true;
  } catch {
    return false;
  }
}
