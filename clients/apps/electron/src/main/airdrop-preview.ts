import { nativeImage } from "electron";
import type { AirDropPreviewImage } from "./modules/airdrop/reception";

/**
 * QuickLook thumbnail of a received file: the photo itself, a document's first
 * page, a video frame, or the file's icon when macOS has no preview for it.
 */
export async function renderAirDropPreview(
  path: string,
  size: { height: number; width: number }
): Promise<AirDropPreviewImage | undefined> {
  const image = await nativeImage.createThumbnailFromPath(path, size);
  if (image.isEmpty()) return undefined;
  // Photos stay small as JPEG; artwork with transparency, such as a file
  // icon, keeps its alpha as PNG.
  const bitmap = image.toBitmap();
  let opaque = true;
  for (let alpha = 3; alpha < bitmap.length; alpha += 4) {
    if (bitmap[alpha] !== 255) {
      opaque = false;
      break;
    }
  }
  const bytes = opaque ? image.toJPEG(82) : image.toPNG();
  const { height, width } = image.getSize();
  return {
    bytes: new Uint8Array(bytes),
    height,
    mediaType: opaque ? "image/jpeg" : "image/png",
    width,
  };
}
