import { expect, test } from "./electron-test";
import { findElectronWindowByNativeId } from "../src/test-support/electron-native-window";

// S3: the windows.* capability lets a renderer open further product windows at
// runtime. Each new window reuses the main-window surface but gets a distinct
// generated id (win_dynamic_N) and — via S2 — exposes its own frozen
// commaNative.self. This proves dynamic window creation end to end: the renderer
// opens a second window whose identity is readable and distinct from the boot
// main window. Mutation that turns it red: reuse the boot main window id for
// dynamic windows so the second window's identity is not distinct.
test.describe("renderer window open", () => {
  test(
    "commaNative.windows.create opens a second window with a distinct identity",
    { tag: "@shared-app" },
    async ({ sharedElectron: { app, mainWindow } }) => {
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
    }
  );
});
