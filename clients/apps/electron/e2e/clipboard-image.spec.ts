import { _electron as electron, expect, test } from "@playwright/test";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { findElectronWindowByNativeRole } from "../src/test-support/electron-native-window";

const electronAppDir = resolve(process.cwd(), "apps/electron");
const electronMain = resolve(electronAppDir, ".vite/build/main.js");

/** A 4×4 red PNG: small enough to inline, real enough for nativeImage to decode. */
const redSquarePng =
  "iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAIAAAAmkwkpAAAAEElEQVR4nGO4o6YGRwzEcQDsoxKBT+rXhgAAAABJRU5ErkJggg==";

test("copied images reach the clipboard through Main, not the renderer", async () => {
  const userDataDir = await mkdtemp(join(tmpdir(), "comma-clipboard-image-e2e-"));
  const { ELECTRON_RUN_AS_NODE: _electronRunAsNode, ...hostEnv } = process.env;
  const app = await electron.launch({
    args: [electronMain, `--user-data-dir=${userDataDir}`],
    cwd: electronAppDir,
    env: { ...hostEnv, NODE_ENV: "test" },
  });

  try {
    const mainWindow = await findElectronWindowByNativeRole(app, "main-window");
    await mainWindow.waitForLoadState("domcontentloaded");
    await app.evaluate(({ clipboard }) => clipboard.clear());

    const outcome = await mainWindow.evaluate(async (base64: string) => {
      const pngImage = Uint8Array.from(atob(base64), (character) =>
        character.charCodeAt(0)
      );
      const scope = window as unknown as {
        commaNative?: {
          clipboard?: {
            writeImage?: (input: {
              pngImage: Uint8Array;
            }) => Promise<{ status: string }>;
          };
        };
      };

      // The session denies every renderer permission, so the web clipboard API
      // is not an option here; the failure it answers with is what the Drive
      // preview's copy used to swallow.
      let webClipboardError = "wrote";
      try {
        await navigator.clipboard.write([
          new ClipboardItem({
            "image/png": new Blob([pngImage], { type: "image/png" }),
          }),
        ]);
      } catch (error) {
        webClipboardError = (error as Error).name;
      }

      return {
        bridge: await scope.commaNative?.clipboard?.writeImage?.({ pngImage }),
        webClipboardError,
      };
    }, redSquarePng);

    expect(outcome.webClipboardError).toBe("NotAllowedError");
    expect(outcome.bridge).toEqual({ status: "copied" });

    const copied = await app.evaluate(({ clipboard }) => {
      const image = clipboard.readImage();
      return { empty: image.isEmpty(), size: image.getSize() };
    });
    expect(copied).toEqual({ empty: false, size: { height: 4, width: 4 } });
  } finally {
    await app.close();
    await rm(userDataDir, { force: true, recursive: true });
  }
});
