import { expect, test } from "./electron-test";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const electronAppDir = resolve(process.cwd(), "apps/electron");
const packageVersion = (
  JSON.parse(readFileSync(resolve(electronAppDir, "package.json"), "utf8")) as {
    version: string;
  }
).version;

test(
  "the built Electron flavor reaches the renderer through native info",
  { tag: "@shared-app" },
  async ({ sharedElectron: { mainWindow } }) => {
    const expectedVersion =
      process.env.COMMA_ELECTRON_E2E_EXPECTED_APP_VERSION ?? `${packageVersion}-dev`;
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
  }
);
