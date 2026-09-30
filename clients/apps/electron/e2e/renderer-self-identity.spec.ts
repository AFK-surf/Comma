import { _electron as electron, expect, test } from "@playwright/test";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { findElectronWindowByNativeRole } from "../src/test-support/electron-native-window";

const electronAppDir = resolve(process.cwd(), "apps/electron");
const electronMain = resolve(electronAppDir, ".vite/build/main.js");

// S2: the main process injects each managed window's identity into argv
// (--window-id / --window-role) and the preload exposes a frozen read-only
// `commaNative.self` to the renderer. This proves the main window's identity is
// actually readable end to end — the injected values, not the unknown/web
// fallback. Dynamic-window differentiation is covered by the companion S3
// renderer-window-open scenario. Mutation that turns this red: drop the argv
// injection in window-options so the preload resolves the unknown fallback.
test.describe("renderer self identity", () => {
  let userDataDir: string;

  test.beforeEach(async () => {
    userDataDir = await mkdtemp(join(tmpdir(), "comma-self-identity-e2e-"));
  });

  test.afterEach(async () => {
    await rm(userDataDir, { force: true, recursive: true });
  });

  test("main window exposes its injected identity via commaNative.self", async () => {
    const app = await electron.launch({
      args: [electronMain, `--user-data-dir=${userDataDir}`],
      cwd: electronAppDir,
      env: { ...process.env, NODE_ENV: "test" },
    });
    try {
      const mainWindow = await findElectronWindowByNativeRole(app, "main-window");
      await mainWindow.waitForLoadState("domcontentloaded");
      const identity = await mainWindow.evaluate(
        () =>
          (window as unknown as { commaNative?: { self?: unknown } }).commaNative?.self
      );
      expect(identity).toEqual({ role: "main-window", windowId: "win_main" });
    } finally {
      await app.close();
    }
  });
});
