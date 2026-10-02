import {
  _electron as electron,
  expect,
  test,
  type ElectronApplication,
} from "@playwright/test";
import { execSync } from "node:child_process";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import type { UpdateInfo } from "@comma/native-bridge";
import { recordElectronOnboardingCompleted } from "../../../e2e/helpers/electron-profile";
import { startChatSmokeStub } from "../../../e2e/p0/chat-stub";
import { findElectronWindowByNativeRole } from "../src/test-support/electron-native-window";

type UpdateTestState = typeof globalThis & {
  finishManualUpdate?: (outcome: "current" | "failed" | "download") => void;
  finishManualDownload?: () => void;
};

// Exercise the real native menu -> preload IPC -> renderer -> toast path.
// Only the update service is replaced: no network feed or real installation.
for (const outcome of ["current", "failed", "download"] as const) {
  test(`manual update check shows progress and ${outcome} feedback`, async () => {
    const apiStub = await startChatSmokeStub();
    const userDataDir = await mkdtemp(join(tmpdir(), "comma-update-feedback-"));
    recordElectronOnboardingCompleted(userDataDir, [apiStub.userId]);
    const appDir = resolve(process.cwd(), "apps/electron");
    const { ELECTRON_RUN_AS_NODE: _runAsNode, ...env } = process.env;
    const app = await electron.launch({
      args: [
        resolve(appDir, ".vite/build/main.js"),
        "--lang=en-US",
        `--user-data-dir=${userDataDir}`,
      ],
      cwd: appDir,
      env: {
        ...env,
        COMMA_API_BASE_URL: apiStub.baseUrl,
        COMMA_ELECTRON_STARTUP_SESSION_EMAIL: "update-feedback@comma.local",
        COMMA_ELECTRON_STARTUP_SESSION_TOKEN: "update-feedback-session",
        NODE_ENV: "test",
      },
    });
    try {
      const page = await findElectronWindowByNativeRole(app, "main-window");
      await expect(
        page.getByRole("complementary", { name: "App sidebar" })
      ).toBeVisible();
      const nativeWindow = await app.browserWindow(page);
      await nativeWindow.evaluate((window) => {
        window.show();
        window.focus();
      });
      await app.evaluate(({ app: electronApp }) => electronApp.focus({ steal: true }));
      const enabled = () =>
        app.evaluate(
          ({ Menu }) =>
            Menu.getApplicationMenu()?.getMenuItemById("check-updates")?.enabled
        );
      await expect
        .poll(enabled)
        .toBe(true)
        .catch(async (error: unknown) => {
          await describeFocus(app, userDataDir);
          throw error;
        });
      await app.evaluate(({ ipcMain }) => {
        ipcMain.removeHandler("comma:updates:status");
        ipcMain.removeHandler("comma:updates:check");
        ipcMain.removeHandler("comma:updates:download");
        ipcMain.handle("comma:updates:status", () => ({
          configured: true,
          currentVersion: "0.0.1",
          productName: "Comma",
        }));
        ipcMain.handle(
          "comma:updates:check",
          () =>
            new Promise<UpdateInfo | null>((resolveCheck, reject) => {
              (globalThis as UpdateTestState).finishManualUpdate = (result) => {
                if (result === "failed")
                  reject(new Error("Test update service unavailable"));
                else if (result === "current") resolveCheck(null);
                else
                  resolveCheck({
                    TargetFullRelease: {
                      PackageId: "comma",
                      Version: "0.0.2",
                      Type: "Full",
                      FileName: "comma.nupkg",
                      SHA1: "test",
                      SHA256: "test",
                      Size: 1,
                      NotesMarkdown: "",
                      NotesHtml: "",
                    },
                    DeltasToTarget: [],
                    IsDowngrade: false,
                  });
              };
            })
        );
        ipcMain.handle(
          "comma:updates:download",
          () =>
            new Promise<boolean>((resolveDownload) => {
              (globalThis as UpdateTestState).finishManualDownload = () =>
                resolveDownload(true);
            })
        );
      });
      const clickCheck = () =>
        app.evaluate(({ Menu, BrowserWindow }) => {
          const entry = Menu.getApplicationMenu()!.getMenuItemById("check-updates")!;
          if (!entry.enabled) throw new Error("Check for Updates is disabled");
          const window = BrowserWindow.getFocusedWindow()!;
          entry.click(
            undefined!,
            window,
            window.webContents as unknown as KeyboardEvent
          );
        });
      await clickCheck();
      await expect(
        page.getByText("Checking for updates…", { exact: true })
      ).toBeVisible();
      await expect.poll(enabled).toBe(false);
      await expect
        .poll(() =>
          app.evaluate(() =>
            Boolean((globalThis as UpdateTestState).finishManualUpdate)
          )
        )
        .toBe(true);
      await app.evaluate(
        (_, result) => (globalThis as UpdateTestState).finishManualUpdate!(result),
        outcome
      );
      if (outcome === "download") {
        await expect(
          page.getByText("Downloading update…", { exact: true })
        ).toBeVisible();
        await expect(
          page.getByText("Checking for updates…", { exact: true })
        ).toHaveCount(0);
        await expect.poll(enabled).toBe(false);
        await expect
          .poll(() =>
            app.evaluate(() =>
              Boolean((globalThis as UpdateTestState).finishManualDownload)
            )
          )
          .toBe(true);
        await app.evaluate(() =>
          (globalThis as UpdateTestState).finishManualDownload!()
        );
        await expect(page.getByText("Update ready", { exact: true })).toBeVisible();
        await expect(page.getByRole("button", { name: "Restart now" })).toBeVisible();
        await expect(
          page.getByText("Downloading update…", { exact: true })
        ).toHaveCount(0);
      } else {
        await expect(
          page.getByText(
            outcome === "current" ? "You’re up to date" : "Could not check for updates",
            { exact: true }
          )
        ).toBeVisible();
      }
      await expect(
        page.getByText("Checking for updates…", { exact: true })
      ).toHaveCount(0);
      await expect.poll(enabled).toBe(true);
      // A failure must leave the native command usable for the next attempt.
      if (outcome === "failed") {
        await app.evaluate(() => {
          delete (globalThis as UpdateTestState).finishManualUpdate;
        });
        await clickCheck();
        await expect(
          page.getByText("Checking for updates…", { exact: true })
        ).toBeVisible();
        await expect
          .poll(() =>
            app.evaluate(() =>
              Boolean((globalThis as UpdateTestState).finishManualUpdate)
            )
          )
          .toBe(true);
        await app.evaluate(() =>
          (globalThis as UpdateTestState).finishManualUpdate!("current")
        );
        await expect(
          page.getByText("You’re up to date", { exact: true })
        ).toBeVisible();
        await expect.poll(enabled).toBe(true);
      }
    } finally {
      await app.close();
      await apiStub.close();
      await rm(userDataDir, { recursive: true, force: true });
    }
  });
}

// TEMPORARY CI diagnosis for a focus failure seen only on CI runners: what
// holds focus when the main window does not get it. Remove once understood.
function run(command: string, timeout = 5_000) {
  try {
    return execSync(command, { encoding: "utf8", timeout });
  } catch (error) {
    return String(error);
  }
}

async function describeFocus(app: ElectronApplication, userDataDir: string) {
  const state = await app.evaluate(({ app: electronApp, BrowserWindow }) => ({
    focusedWindow: BrowserWindow.getFocusedWindow()?.webContents.getURL() ?? null,
    hidden: electronApp.isHidden(),
    windows: BrowserWindow.getAllWindows().map((window) => ({
      alwaysOnTop: window.isAlwaysOnTop(),
      focused: window.isFocused(),
      url: window.webContents.getURL(),
      visible: window.isVisible(),
    })),
  }));
  console.log(
    `[focus-diagnosis] front app: ${run("lsappinfo info -only name `lsappinfo front`")}`
  );
  // Runners cannot capture the screen; the unified log says which alert the
  // front app shows and who asked for it.
  console.log(
    `[focus-diagnosis] alerts:\n${run(
      'log show --last 30m --style compact --predicate \'process == "UserNotificationCenter" OR eventMessage CONTAINS[c] "CFUserNotification"\' | tail -40',
      60_000
    )}`
  );
  console.log(
    `[focus-diagnosis] alert text: ${run(
      'osascript -e \'tell application "System Events" to get value of every static text of every window of process "UserNotificationCenter"\'',
      15_000
    )}`
  );
  console.log(
    `[focus-diagnosis] Electron processes:\n${run(
      "ps -axo pid,etime,command | grep -i '[E]lectron' | cut -c1-220"
    )}`
  );
  const log = await readFile(join(userDataDir, "logs", "main.log"), "utf8").catch(
    (error: unknown) => String(error)
  );
  console.log(
    `[focus-diagnosis] ${JSON.stringify(state)}\n[focus-diagnosis] main.log tail:\n${log
      .split("\n")
      .filter((line) => !/^\s+at /.test(line))
      .slice(-40)
      .join("\n")}`
  );
}
