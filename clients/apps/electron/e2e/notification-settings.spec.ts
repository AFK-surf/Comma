import {
  _electron as electron,
  expect,
  test,
  type Locator,
  type Page,
} from "@playwright/test";
import type { AppPreferences } from "@comma/native-bridge";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { findElectronWindowByNativeRole } from "../src/test-support/electron-native-window";
import { startSessionProjectionStub } from "../../../e2e/helpers/session-fixture";

const electronAppDir = resolve(process.cwd(), "apps/electron");
const electronMain = resolve(electronAppDir, ".vite/build/main.js");
const NOTIFICATIONS_E2E_EMAIL = "notification-settings-e2e@example.com";
const NOTIFICATIONS_E2E_TOKEN = "comma_sess_notification_settings_e2e";
let sessionStub: Awaited<ReturnType<typeof startSessionProjectionStub>>;

test.describe("notification settings", () => {
  let testDirectory: string;

  test.beforeAll(async () => {
    sessionStub = await startSessionProjectionStub({ email: NOTIFICATIONS_E2E_EMAIL });
  });

  test.afterAll(async () => {
    await sessionStub.close();
  });

  test.beforeEach(async () => {
    testDirectory = await mkdtemp(join(tmpdir(), "comma-notification-settings-e2e-"));
  });

  test.afterEach(async () => {
    await rm(testDirectory, { force: true, recursive: true });
  });

  test("gates Router notifications on the system switch and persists it", async () => {
    const userDataPath = join(testDirectory, "user-data");
    const preferencesFilePath = join(userDataPath, "app-preferences.json");
    const app = await electron.launch({
      args: electronLaunchArgs(userDataPath),
      cwd: electronAppDir,
      env: electronEnv(userDataPath, {
        COMMA_ELECTRON_E2E_LAUNCH_AT_LOGIN_STATUS: "not-registered",
        COMMA_ELECTRON_E2E_OPERATING_SYSTEM: "macos",
        COMMA_ELECTRON_E2E_SYSTEM_NOTIFICATIONS_STATUS: "available",
      }),
    });

    try {
      const mainWindow = await openNotificationSettings(app);
      const system = mainWindow.getByRole("switch", { name: "System notifications" });
      const routerMessages = mainWindow.getByRole("switch", {
        name: "Router message notifications",
      });
      const sound = mainWindow.getByRole("switch", { name: "Notification sound" });

      // Main reads the OS answer as it opens the preferences, so the very
      // first snapshot already carries it; the page must see "available"
      // before the switches are trusted.
      await expect
        .poll(() => readNotificationReadback(mainWindow))
        .toEqual({
          revision: expect.any(Number),
          systemNotifications: true,
          systemNotificationsStatus: "available",
        });
      await expect(system).toBeEnabled();
      await expect(system).toBeChecked();
      await expect(routerMessages).toBeEnabled();
      await expect(sound).toBeEnabled();
      await expect(
        mainWindow.getByText("Comma sends system notifications to remind you.")
      ).toBeVisible();

      await activateSwitch(system);
      await expect(system).not.toBeChecked();
      // The Router rows keep their stored values but cannot be changed while
      // the master switch is off.
      await expect(routerMessages).toBeDisabled();
      await expect(routerMessages).toBeChecked();
      await expect(sound).toBeDisabled();
      await expect
        .poll(() => readRendererPreferences(mainWindow))
        .toMatchObject({ notifyRouterMessages: true, systemNotifications: false });
      expect(JSON.parse(await readFile(preferencesFilePath, "utf8"))).toMatchObject({
        notifyRouterMessages: true,
        systemNotifications: false,
      });
      // The readback is platform truth, not a stored choice.
      expect(
        JSON.parse(await readFile(preferencesFilePath, "utf8"))
      ).not.toHaveProperty("systemNotificationsStatus");
    } catch (error) {
      await attachMainLog(userDataPath);
      throw error;
    } finally {
      await app.close();
    }
  });

  test("lets the user turn the system switch on while the OS denies Comma notifications", async () => {
    const userDataPath = join(testDirectory, "denied-user-data");
    const app = await electron.launch({
      args: electronLaunchArgs(userDataPath),
      cwd: electronAppDir,
      env: electronEnv(userDataPath, {
        COMMA_ELECTRON_E2E_LAUNCH_AT_LOGIN_STATUS: "not-registered",
        COMMA_ELECTRON_E2E_OPERATING_SYSTEM: "macos",
        COMMA_ELECTRON_E2E_SYSTEM_NOTIFICATIONS_STATUS: "denied",
      }),
    });

    try {
      const mainWindow = await openNotificationSettings(app);
      await expect
        .poll(() => readNotificationReadback(mainWindow))
        .toEqual({
          revision: expect.any(Number),
          systemNotifications: true,
          systemNotificationsStatus: "denied",
        });

      const system = mainWindow.getByRole("switch", { name: "System notifications" });
      await expect(system).toBeEnabled();
      await expect(system).not.toBeChecked();
      await expect(
        mainWindow.getByText(
          "Notifications for Comma are turned off in System Settings. Allow them there to turn this on."
        )
      ).toBeVisible();
      await expect(
        mainWindow.getByRole("switch", { name: "Router message notifications" })
      ).toBeDisabled();
      await expect(
        mainWindow.getByRole("switch", { name: "Notification sound" })
      ).toBeDisabled();

      await activateSwitch(system);
      const dialog = mainWindow.getByRole("dialog", {
        name: "Allow notifications in System Settings",
      });
      await expect(dialog).toBeVisible();
      await expect(system).toBeChecked();
      await mainWindow.getByRole("button", { name: "Cancel" }).click();
      await expect(dialog).toBeHidden();
      await expect(system).not.toBeChecked();
    } catch (error) {
      await attachMainLog(userDataPath);
      throw error;
    } finally {
      await app.close();
    }
  });
});

function electronEnv(userDataPath: string, overrides: Record<string, string>) {
  const {
    COMMA_ELECTRON_STARTUP_SESSION_TOKEN: _sessionToken,
    ELECTRON_RUN_AS_NODE: _electronRunAsNode,
    ...env
  } = process.env;
  return {
    ...env,
    COMMA_API_BASE_URL: sessionStub.baseUrl,
    COMMA_ELECTRON_STARTUP_SESSION_EMAIL: NOTIFICATIONS_E2E_EMAIL,
    COMMA_ELECTRON_STARTUP_SESSION_TOKEN: NOTIFICATIONS_E2E_TOKEN,
    NODE_ENV: "test",
    ...overrides,
  };
}

function electronLaunchArgs(userDataPath: string) {
  // Chromium resolves its profile before Main can apply the matching E2E
  // app.setPath hook, so the isolated profile is fixed on the command line.
  return [electronMain, "--lang=en-US", `--user-data-dir=${userDataPath}`];
}

async function openNotificationSettings(
  app: Parameters<typeof findElectronWindowByNativeRole>[0]
) {
  const mainWindow = await findElectronWindowByNativeRole(app, "main-window");
  await mainWindow.waitForLoadState("domcontentloaded");
  await mainWindow.evaluate(() => {
    window.location.hash = "#/settings?category=notifications";
  });
  await expect(
    mainWindow.getByRole("heading", { level: 1, name: "Notifications" })
  ).toBeVisible();
  return mainWindow;
}

// The readback and the revision it rode in on: a failure then says whether
// Main never published it or published it without the field.
async function readNotificationReadback(page: Page) {
  const { revision, systemNotifications, systemNotificationsStatus } =
    await readRendererPreferences(page);
  return { revision, systemNotifications, systemNotificationsStatus };
}

// Main's own log is the only view of the readback path once the window is
// gone, so a failed run keeps it beside the screenshots.
async function attachMainLog(userDataPath: string) {
  const info = test.info();
  const mainLog = await readFile(join(userDataPath, "logs", "main.log"), "utf8").catch(
    () => undefined
  );
  if (mainLog === undefined) return;
  await info.attach("main.log", { body: mainLog, contentType: "text/plain" });
}

function readRendererPreferences(page: Page) {
  return page.evaluate(() =>
    (
      window as unknown as {
        commaNative: { appPreferences: { state: { get(): Promise<AppPreferences> } } };
      }
    ).commaNative.appPreferences.state.get()
  );
}

async function activateSwitch(toggle: Locator) {
  await expect(toggle).toBeEnabled();
  // React Aria renders the semantic switch input behind its label/track; the
  // keyboard contract is the reliable way to flip it under automation.
  await toggle.press("Space", { timeout: 8_000 });
}
