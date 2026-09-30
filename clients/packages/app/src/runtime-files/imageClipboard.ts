import { getNativeBridge } from "@comma/native-bridge";

/** The clipboard takes PNG; anything else is redrawn through a canvas first. */
export async function copyImageBlob(blob: Blob) {
  const pngBlob =
    blob.type === "image/png"
      ? blob
      : await new Promise<Blob>((resolve, reject) => {
          const bitmapUrl = URL.createObjectURL(blob);
          const image = new Image();
          image.addEventListener(
            "load",
            () => {
              URL.revokeObjectURL(bitmapUrl);
              try {
                const canvas = document.createElement("canvas");
                canvas.width = image.naturalWidth;
                canvas.height = image.naturalHeight;
                const context = canvas.getContext("2d");
                if (!context || !canvas.width || !canvas.height)
                  throw new Error("Image conversion unavailable.");
                context.drawImage(image, 0, 0);
                canvas.toBlob(
                  (result) =>
                    result ? resolve(result) : reject(new Error("PNG encode failed")),
                  "image/png"
                );
              } catch (error) {
                reject(error);
              }
            },
            { once: true }
          );
          image.addEventListener(
            "error",
            () => {
              URL.revokeObjectURL(bitmapUrl);
              reject(new Error("Image decode failed"));
            },
            { once: true }
          );
          image.src = bitmapUrl;
        });
  // The desktop session denies every renderer permission, clipboard-write
  // included, so the bytes go to Main the way copied text already does.
  const bridge = getNativeBridge();
  if (bridge.platform === "electron") {
    const written = await bridge.clipboard.writeImage({
      pngImage: new Uint8Array(await pngBlob.arrayBuffer()),
    });
    if (written.status !== "copied") throw new Error("Clipboard write was denied.");
    return;
  }

  await navigator.clipboard.write([new ClipboardItem({ "image/png": pngBlob })]);
}
