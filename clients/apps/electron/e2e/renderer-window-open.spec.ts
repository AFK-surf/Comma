import { _electron as electron, expect, test } from "@playwright/test";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import {
  findElectronWindowByNativeId,
  findElectronWindowByNativeRole,
} from "../src/test-support/electron-native-window";

const electronAppDir = resolve(process.cwd(), "apps/electron");
const electronMain = resolve(electronAppDir, ".vite/build/main.js");

// S3: the windows.* capability lets a renderer open further product windows at
// runtime. Each new window reuses the main-window surface but gets a distinct
// generated id (win_dynamic_N) and — via S2 — exposes its own frozen
// commaNative.self. This proves dynamic window creation end to end: the renderer
// opens a second window whose identity is readable and distinct from the boot
// main window. Mutation that turns it red: reuse the boot main window id for
// dynamic windows so the second window's identity is not distinct.
test.describe("renderer window open", () => {
  let userDataDir: string;

  test.beforeEach(async () => {
    userDataDir = await mkdtemp(join(tmpdir(), "comma-window-open-e2e-"));
  });

  test.afterEach(async () => {
    await rm(userDataDir, { force: true, recursive: true });
  });

  test("commaNative.windows.create opens a second window with a distinct identity", async () => {
    const app = await electron.launch({
      args: [electronMain, `--user-data-dir=${userDataDir}`],
      cwd: electronAppDir,
      env: { ...process.env, NODE_ENV: "test" },
    });
    try {
      const mainWindow = await findElectronWindowByNativeRole(app, "main-window");
      await mainWindow.waitForLoadState("domcontentloaded");
      const mainIdentity = await mainWindow.evaluate(
        () =>
          (window as unknown as { commaNative?: { self?: unknown } }).commaNative?.self
      );
      expect(mainIdentity).toEqual({ role: "main-window", windowId: "win_main" });

      // The renderer opens a second product window; a new window must appear.
      await mainWindow.evaluate(() =>
        (
          window as unknown as {
            commaNative: {
              windows: { create: (input: { route: string }) => Promise<unknown> };
            };
          }
        ).commaNative.windows.create({ route: "/" })
      );
      const secondWindow = await findElectronWindowByNativeId(app, /^win_dynamic_/);
      await secondWindow.waitForLoadState("domcontentloaded");

      const secondIdentity = await secondWindow.evaluate(
        () =>
          (
            window as unknown as {
              commaNative?: { self?: { role: string; windowId: string } };
            }
          ).commaNative?.self
      );
      expect(secondIdentity?.role).toBe("main-window");
      expect(secondIdentity?.windowId).toMatch(/^win_dynamic_/);
      expect(secondIdentity?.windowId).not.toBe("win_main");
    } finally {
      await app.close();
    }
  });
});
