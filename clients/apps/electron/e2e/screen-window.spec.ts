import { watch } from "node:fs";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import type { ElectronApplication, Page } from "@playwright/test";
import { findElectronWindowByNativeRole } from "../src/test-support/electron-native-window";
import { closeElectronTestApp } from "./close-electron-test-app";
import {
  closeElectronWindow,
  minimizeElectronWindow,
  setElectronWindowBounds,
} from "./electron-operations";
import { electron, expect, test } from "./electron-test";

const electronAppDir = resolve(process.cwd(), "apps/electron");
const electronMain = resolve(electronAppDir, ".vite/build/main.js");

/** Opens a screen window from the main window's page: the page keeps it as `screenWindow`. */
async function openScreenWindow(
  app: ElectronApplication,
  mainWindow: Page,
  name: string
) {
  const opened = app.waitForEvent("window");
  await mainWindow.evaluate((frame) => {
    const child = window.open("about:blank", frame, "popup,width=640,height=420");
    (window as unknown as { screenWindow: Window | null }).screenWindow = child;
    child!.document.body.innerHTML = "<p>screen</p>";
  }, name);
  return opened;
}

function screenWindowState(app: ElectronApplication) {
  return app.evaluate(({ BrowserWindow }) => {
    const window = BrowserWindow.getAllWindows().find(
      (each) => each.webContents.getURL() === "about:blank"
    );
    return window
      ? { minimized: window.isMinimized(), visible: window.isVisible() }
      : undefined;
  });
}

// A remote screen in a window of its own (packages/app remote-screen/screenWindows.ts): the main window's page opens a
// blank `comma-screen:` window and renders the screen into it. Main lets it open, keeps it from navigating or opening
// windows, lets it fill the screen and take Escape, raises it by name, keeps the page unthrottled while it is open, and
// keeps its place when the page closes it. Mutations that turn it red: allow any blank window, drop the child's
// navigation or window-open guard, refuse the child's full screen, leave background throttling off after the last
// window closes, keep a window's place only on its "close" event, drop keepFullScreenInStep (@mac, on a desktop that
// gives the window a native full screen).
test(
  "a screen window opens from the main window's page and stays the page's",
  { tag: "@shared-app" },
  async ({ sharedElectron: { app, mainWindow } }) => {
    const throttled = () =>
      app.evaluate(({ BrowserWindow }) =>
        BrowserWindow.getAllWindows()
          .find((window) => window.webContents.getURL().startsWith("assets:"))
          ?.webContents.getBackgroundThrottling()
      );
    expect(await throttled()).toBe(true);

    // Any other window the page asks for is refused.
    expect(
      await mainWindow.evaluate(() => window.open("about:blank", "other") === null)
    ).toBe(true);

    const child = await openScreenWindow(app, mainWindow, "comma-screen:e2e-window:k1");
    expect(await child.textContent("p")).toBe("screen");
    expect(await throttled()).toBe(false);

    // It goes nowhere and opens nothing of its own.
    await child.evaluate(() => {
      window.location.href = "http://127.0.0.1:9/";
    });
    expect(
      await mainWindow.evaluate(() => {
        const view = (window as unknown as { screenWindow: Window }).screenWindow;
        return [view.location.href, view.open("about:blank", "nested") === null];
      })
    ).toEqual(["about:blank", true]);

    // It may take Escape for the computer it controls (full screen is the @mac test's: it needs a desktop).
    expect(
      await child.evaluate(() =>
        (navigator as { keyboard?: { lock(keys: string[]): Promise<void> } })
          .keyboard!.lock(["Escape"])
          .then(
            () => true,
            () => false
          )
      )
    ).toBe(true);

    // Closed (on a turn of Main's own, once it is gone), the page is throttled again as it hides.
    expect(await closeElectronWindow(app, child)).toBe("closed");
    expect(await throttled()).toBe(true);

    // Closed by the page (moved back to the side panel), its place is kept for that screen's next window.
    const moved = await openScreenWindow(app, mainWindow, "comma-screen:e2e-window:k2");
    const place = await setElectronWindowBounds(app, moved, {
      x: 120,
      y: 140,
      width: 700,
      height: 460,
    });
    // (Main writes its file as the window goes: each change to the directory is looked at, no clock)
    const userData = await app.evaluate(({ app: electronApp }) =>
      electronApp.getPath("userData")
    );
    const kept = new Promise<unknown>((found) => {
      const watcher = watch(userData, () => {
        void readFile(join(userData, "screen-windows.json"), "utf8")
          .then(
            (text) =>
              (JSON.parse(text) as { screens: Record<string, unknown> }).screens.k2
          )
          .then((k2) => {
            if (!k2) return;
            watcher.close();
            found(k2);
          })
          .catch(() => undefined);
      });
    });
    await mainWindow.evaluate(() =>
      (window as unknown as { screenWindow: Window }).screenWindow.close()
    );
    expect(await kept).toEqual(place.bounds);
  }
);

// @mac: it needs a desktop with a Dock, where a window minimizes and comes back, and fills the screen.
test(
  "a minimized screen window comes back by its name, and fills the screen",
  { tag: "@mac" },
  async () => {
    const userDataDir = await mkdtemp(join(tmpdir(), "comma-screen-window-e2e-"));
    const { ELECTRON_RUN_AS_NODE: _electronRunAsNode, ...env } = process.env;
    const app = await electron.launch({
      args: [electronMain, "--lang=en-US", `--user-data-dir=${userDataDir}`],
      cwd: electronAppDir,
      env: { ...env, NODE_ENV: "test" },
    });
    try {
      const mainWindow = await findElectronWindowByNativeRole(app, "main-window");
      await mainWindow.waitForLoadState("domcontentloaded");
      const name = "comma-screen:e2e-window:k1";
      const child = await openScreenWindow(app, mainWindow, name);
      await minimizeElectronWindow(app, child);
      expect(await screenWindowState(app)).toEqual({ minimized: true, visible: false });
      await app.evaluate(({ BrowserWindow }) => {
        const window = BrowserWindow.getAllWindows().find(
          (each) => each.webContents.getURL() === "about:blank"
        )!;
        (globalThis as { restored?: Promise<void> }).restored = new Promise<void>(
          (done) => window.once("restore", () => done())
        );
      });
      expect(
        await mainWindow.evaluate(
          (frame) =>
            (
              window as unknown as {
                commaNative: {
                  windows: {
                    focusScreen(input: { name: string }): Promise<{ focused: boolean }>;
                  };
                };
              }
            ).commaNative.windows.focusScreen({ name: frame }),
          name
        )
      ).toEqual({ focused: true });
      await app.evaluate(() => (globalThis as { restored?: Promise<void> }).restored);
      expect(await screenWindowState(app)).toEqual({ minimized: false, visible: true });

      // It fills the screen, and leaves it: each once Main has seen the change.
      const expectFullScreen = (entering: boolean) =>
        app.evaluate(({ BrowserWindow }, enter) => {
          const window = BrowserWindow.getAllWindows().find(
            (each) => each.webContents.getURL() === "about:blank"
          )!;
          (globalThis as { changed?: Promise<void> }).changed = new Promise<void>(
            (done) => {
              if (enter) window.once("enter-html-full-screen", () => done());
              else window.once("leave-html-full-screen", () => done());
            }
          );
        }, entering);
      const changed = () =>
        app.evaluate(async () => {
          const main = globalThis as { changed?: Promise<void> };
          await main.changed;
          delete main.changed;
        });
      await expectFullScreen(true);
      await child.evaluate(() => document.body.requestFullscreen());
      await changed();
      expect(
        await child.evaluate(() => document.fullscreenElement === document.body)
      ).toBe(true);
      // Left at once, while the window is still on its way into the native full screen (where macOS gives it one): the
      // page is out once the window is (full-screen-in-step.ts keepFullScreenInStep; without it this never settles).
      await expectFullScreen(false);
      await child.evaluate(() => document.exitFullscreen());
      await changed();
      expect(await child.evaluate(() => document.fullscreenElement)).toBeNull();
      expect(
        await app.evaluate(({ BrowserWindow }) =>
          BrowserWindow.getAllWindows()
            .find((each) => each.webContents.getURL() === "about:blank")!
            .isFullScreen()
        )
      ).toBe(false);
    } finally {
      await closeElectronTestApp(app);
      await rm(userDataDir, { recursive: true, force: true });
    }
  }
);

// @mac: the main window's page fills the screen (the side panel's remote screen stage) and leaves as soon as Main sees
// it in, while the window is still on its way into the native full screen. The page and the window end windowed, and
// the page fills the screen again. Turns red without keepFullScreenInStep on the main window (full-screen-in-step.ts):
// `exitFullscreen()` never settles and `document.fullscreenElement` stays set.
test(
  "the main window's page leaves full screen during the window's way in, and fills it again",
  { tag: "@mac" },
  async () => {
    const userDataDir = await mkdtemp(join(tmpdir(), "comma-main-full-screen-e2e-"));
    const { ELECTRON_RUN_AS_NODE: _electronRunAsNode, ...env } = process.env;
    const app = await electron.launch({
      args: [electronMain, "--lang=en-US", `--user-data-dir=${userDataDir}`],
      cwd: electronAppDir,
      env: { ...env, NODE_ENV: "test" },
    });
    try {
      const mainWindow = await findElectronWindowByNativeRole(app, "main-window");
      await mainWindow.waitForLoadState("domcontentloaded");
      const state = async () => ({
        page: await mainWindow.evaluate(() => document.fullscreenElement !== null),
        window: await app.evaluate(({ BrowserWindow }) =>
          BrowserWindow.getAllWindows()
            .find(
              (each) =>
                each.isVisible() && each.webContents.getURL().startsWith("assets:")
            )!
            .isFullScreen()
        ),
      });
      // In, out at once (Main has seen the page in, the window's transition has just begun), and windowed again once
      // the page's `exitFullscreen()` settles.
      const inAndOut = async () => {
        await mainWindow.evaluate(() => document.documentElement.requestFullscreen());
        expect(
          await mainWindow.evaluate(
            () => document.fullscreenElement === document.documentElement
          )
        ).toBe(true);
        await mainWindow.evaluate(() => document.exitFullscreen());
        expect(await state()).toEqual({ page: false, window: false });
      };
      await inAndOut();
      await inAndOut();
    } finally {
      await closeElectronTestApp(app);
      await rm(userDataDir, { recursive: true, force: true });
    }
  }
);
