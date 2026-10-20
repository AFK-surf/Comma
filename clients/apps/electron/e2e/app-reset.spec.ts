import type { ElectronApplication } from "@playwright/test";
import { mkdtemp, readdir, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { startChatSmokeStub } from "../../../e2e/p0/chat-stub";
import { closeElectronTestApp } from "./close-electron-test-app";
import { electron, expect, loadedMainWindow, test } from "./electron-test";

const electronAppDir = resolve(process.cwd(), "apps/electron");
const electronMain = resolve(electronAppDir, ".vite/build/main.js");

/**
 * What a running app holds that a test can count from Main: its windows and web contents, its processes, the IPC
 * handlers and listeners registered on Electron's process-wide objects, and Node's live handles (timers, child
 * processes, sockets, servers).
 */
function mainState(app: ElectronApplication) {
  return app.evaluate(
    ({
      app: electronApp,
      BrowserWindow,
      ipcMain,
      nativeTheme,
      powerMonitor,
      screen,
      session,
      webContents,
    }) => {
      // This function runs in Main: what it calls is declared inside it.
      // oxlint-disable-next-line unicorn/consistent-function-scoping
      const count = (values: string[]) =>
        Object.fromEntries(
          [...new Set(values)]
            .toSorted()
            .map((value) => [value, values.filter((other) => other === value).length])
        );
      // oxlint-disable-next-line unicorn/consistent-function-scoping
      const listeners = (emitter: NodeJS.EventEmitter) =>
        Object.fromEntries(
          emitter
            .eventNames()
            .map(String)
            .toSorted()
            .map((name) => [name, emitter.listenerCount(name)])
        );
      // oxlint-disable-next-line unicorn/consistent-function-scoping
      const route = (url: string) => {
        try {
          return `${new URL(url).protocol}${new URL(url).hash || "#/"}`;
        } catch {
          return url;
        }
      };
      return {
        windows: BrowserWindow.getAllWindows()
          .map(
            (window) => `${route(window.webContents.getURL())} ${window.isVisible()}`
          )
          .toSorted(),
        webContents: count(
          webContents.getAllWebContents().map((contents) => contents.getType())
        ),
        processes: count(
          electronApp
            .getAppMetrics()
            .map((metric) => `${metric.type} ${metric.serviceName ?? ""}`.trim())
        ),
        // Electron keeps `ipcMain.handle`'s handlers in `_invokeHandlers`; it has no public list of them.
        ipcHandlers: [
          ...(Reflect.get(ipcMain, "_invokeHandlers") as Map<string, unknown>).keys(),
        ].toSorted(),
        listeners: {
          app: listeners(electronApp),
          ipcMain: listeners(ipcMain),
          nativeTheme: listeners(nativeTheme),
          powerMonitor: listeners(powerMonitor),
          screen: listeners(screen),
          defaultSession: listeners(session.defaultSession),
        },
        // What Node holds open; requests under way (`*Req*`: a file read, a close) are operations, not holdings.
        handles: count(
          process.getActiveResourcesInfo().filter((kind) => !kind.includes("Req"))
        ),
      };
    }
  );
}

/** The app's open main window (a reset keeps it), once it shows no one signed in. */
async function signedOutMainWindow(app: ElectronApplication) {
  const page = await loadedMainWindow(app);
  await expect(page.getByRole("heading", { name: "Welcome to Comma" })).toBeVisible();
  return page;
}

const started = (app: ElectronApplication) =>
  app.evaluate(() =>
    (
      globalThis as unknown as { commaE2eCore: { started(): Promise<void> } }
    ).commaE2eCore.started()
  );

// A reset must leave nothing of what ran before it: what Main holds after a reset is what it holds after a launch.
test("a reset leaves Main holding what a fresh launch holds", async () => {
  const stub = await startChatSmokeStub();
  const directory = await mkdtemp(join(tmpdir(), "comma-app-reset-e2e-"));
  const { ELECTRON_RUN_AS_NODE: _electronRunAsNode, ...env } = process.env;
  const app = await electron.launch({
    args: [
      electronMain,
      "--lang=en-US",
      `--user-data-dir=${join(directory, "profile")}`,
    ],
    cwd: electronAppDir,
    env: { ...env, COMMA_API_BASE_URL: stub.baseUrl, NODE_ENV: "test" },
  });
  try {
    let mainWindow = await signedOutMainWindow(app);
    await started(app);
    const launched = await mainState(app);
    const launchedFiles = await productFiles(join(directory, "profile"));

    for (let round = 0; round < 2; round += 1) {
      // Use the app: sign in, open a second window, open Settings.
      await mainWindow.evaluate(
        (userId) =>
          window.commaNative!.appPreferences.update({
            clientSettings: { onboardingCompletedUserIds: [userId] },
            notificationSound: false,
          }),
        stub.userId
      );
      await mainWindow
        .getByRole("textbox", { name: "Email", exact: true })
        .fill("smoke@comma.local");
      await mainWindow.getByRole("button", { name: "Continue with email" }).click();
      await mainWindow
        .getByRole("textbox", { name: /verification code/i })
        .fill("654321");
      await expect(
        mainWindow.getByRole("complementary", { name: "App sidebar" })
      ).toBeVisible();
      await mainWindow.evaluate(() =>
        (
          window as unknown as {
            commaNative: {
              windows: { create(input: { route: string }): Promise<unknown> };
            };
          }
        ).commaNative.windows.create({ route: "/" })
      );

      await app.evaluate(() =>
        (
          globalThis as unknown as { commaE2eCore: { reset(): Promise<void> } }
        ).commaE2eCore.reset()
      );
      await started(app);
      mainWindow = await signedOutMainWindow(app);
      expect(await mainState(app)).toEqual(launched);
      expect(await productFiles(join(directory, "profile"))).toEqual(launchedFiles);
    }
  } finally {
    await closeElectronTestApp(app);
    await stub.close();
    await rm(directory, { force: true, recursive: true });
  }
});

/**
 * The files the app keeps for the product in its profile, with the preferences file's contents: Chromium's own files
 * (capitalized, `blob_storage`, the singleton and DevTools markers) and the logs are not the product's state.
 */
async function productFiles(profile: string) {
  const notProduct = new Set([
    "blob_storage",
    "electron-log-preload.js",
    "logs",
    "agent-observability",
  ]);
  const paths = (await readdir(profile, { recursive: true }))
    .filter((path) => {
      const top = path.split("/")[0]!;
      return top[0] === top[0]!.toLowerCase() && !notProduct.has(top);
    })
    .toSorted();
  return {
    paths,
    preferences: JSON.parse(
      await readFile(join(profile, "app-preferences.json"), "utf8")
    ),
  };
}
