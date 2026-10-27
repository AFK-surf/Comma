import { expect, test } from "./electron-test";

/** A 4×4 red PNG: small enough to inline, real enough for nativeImage to decode. */
const redSquarePng =
  "iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAIAAAAmkwkpAAAAEElEQVR4nGO4o6YGRwzEcQDsoxKBT+rXhgAAAABJRU5ErkJggg==";

test(
  "copied images reach the clipboard through Main, not the renderer",
  { tag: "@shared-app" },
  async ({ sharedElectron: { app, mainWindow } }) => {
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

    const copied = await app.evaluate(async ({ clipboard, nativeImage }) => {
      const [item] = await clipboard.read();
      const png = await item?.getType("image/png");
      if (!png) return null;
      return nativeImage
        .createFromBuffer(Buffer.from(await png.arrayBuffer()))
        .getSize();
    });
    expect(copied).toEqual({ height: 4, width: 4 });
  }
);
