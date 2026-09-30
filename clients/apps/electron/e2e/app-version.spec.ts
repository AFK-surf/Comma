import { _electron as electron, expect, test } from "@playwright/test";
import { readFileSync } from "node:fs";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { findElectronWindowByNativeRole } from "../src/test-support/electron-native-window";

const electronAppDir = resolve(process.cwd(), "apps/electron");
const electronMain = resolve(electronAppDir, ".vite/build/main.js");
const packageVersion = (
  JSON.parse(readFileSync(resolve(electronAppDir, "package.json"), "utf8")) as {
    version: string;
  }
).version;

test("the built Electron flavor reaches the renderer through native info", async () => {
  const userDataDir = await mkdtemp(join(tmpdir(), "comma-app-version-e2e-"));
  const { ELECTRON_RUN_AS_NODE: _electronRunAsNode, ...hostEnv } = process.env;
  const expectedVersion =
    process.env.COMMA_ELECTRON_E2E_EXPECTED_APP_VERSION ?? `${packageVersion}-dev`;
  const app = await electron.launch({
    args: [electronMain, `--user-data-dir=${userDataDir}`],
    cwd: electronAppDir,
    env: { ...hostEnv, NODE_ENV: "test" },
  });

  try {
    const mainWindow = await findElectronWindowByNativeRole(app, "main-window");
    await mainWindow.waitForLoadState("domcontentloaded");

    const nativeInfo = await mainWindow.evaluate(async () => {
      const scope = window as unknown as {
        commaNative?: {
          native?: {
            info?: () => Promise<unknown>;
          };
        };
      };
      return scope.commaNative?.native?.info?.();
    });

    expect(nativeInfo).toMatchObject({
      appVersion: expectedVersion,
      platform: "electron",
    });
  } finally {
    await app.close();
    await rm(userDataDir, { force: true, recursive: true });
  }
});
