export const avatarTypes = ["image/jpeg", "image/png", "image/webp"];
/** Largest file the picker accepts; the server enforces the same bound. */
export const maxAvatarBytes = 2 * 1024 * 1024;
/** Avatars render at 40px or less, so 512px covers dense displays. */
export const avatarOutputSide = 512;
/** Uploads above this size are re-encoded at lower quality. */
export const avatarTargetBytes = 200 * 1024;

const encodeQualities = [0.92, 0.85, 0.75, 0.65, 0.5];
const minOutputSide = 128;

export interface AvatarSource {
  width: number;
  height: number;
}

/** A square region of the source image, in source pixels. */
export interface AvatarCrop {
  x: number;
  y: number;
  size: number;
}

export const isAcceptedAvatarFile = (file: File) =>
  avatarTypes.includes(file.type) && file.size > 0 && file.size <= maxAvatarBytes;

/** Largest centered square: the crop the dialog opens with. */
export const initialAvatarCrop = ({ width, height }: AvatarSource): AvatarCrop => {
  const size = Math.min(width, height);
  return { x: (width - size) / 2, y: (height - size) / 2, size };
};

/**
 * Crop for a zoom level (1 = the shortest side fills the frame) centered as
 * close to `center` as the image bounds allow.
 */
export const avatarCropAt = (
  source: AvatarSource,
  zoom: number,
  center: { x: number; y: number }
): AvatarCrop => {
  const size = Math.min(source.width, source.height) / Math.max(zoom, 1);
  const clamp = (value: number, limit: number) =>
    Math.min(Math.max(value - size / 2, 0), limit - size);
  return {
    x: clamp(center.x, source.width),
    y: clamp(center.y, source.height),
    size,
  };
};

/**
 * An already square, small, full-frame upload needs neither a crop nor a
 * re-encode, so it keeps its original bytes and quality.
 */
export const canUploadOriginal = (
  file: Pick<File, "size">,
  source: AvatarSource,
  crop: AvatarCrop
) =>
  source.width === source.height &&
  source.width <= avatarOutputSide &&
  crop.size >= source.width - 0.5 &&
  file.size <= avatarTargetBytes;

export const avatarOutputSideFor = (crop: AvatarCrop) =>
  Math.max(1, Math.min(avatarOutputSide, Math.round(crop.size)));

const canvasToBlob = (canvas: HTMLCanvasElement, type: string, quality: number) =>
  new Promise<Blob | null>((resolve) => canvas.toBlob(resolve, type, quality));

const renderCrop = (
  image: CanvasImageSource,
  crop: AvatarCrop,
  side: number,
  opaque: boolean
) => {
  const canvas = document.createElement("canvas");
  canvas.width = side;
  canvas.height = side;
  const context = canvas.getContext("2d");
  if (!context) throw new Error("Canvas 2D context is unavailable");
  if (opaque) {
    // JPEG has no alpha; transparent pixels would otherwise encode as black.
    context.fillStyle = "#fff";
    context.fillRect(0, 0, side, side);
  }
  context.imageSmoothingEnabled = true;
  context.imageSmoothingQuality = "high";
  context.drawImage(image, crop.x, crop.y, crop.size, crop.size, 0, 0, side, side);
  return canvas;
};

/**
 * Crops to a square and encodes WebP, stepping quality down and then
 * resolution until the result reaches the target size. JPEG is the fallback
 * for engines that cannot encode WebP.
 */
export const encodeAvatar = async (
  file: File,
  image: CanvasImageSource,
  source: AvatarSource,
  crop: AvatarCrop
): Promise<File> => {
  if (canUploadOriginal(file, source, crop)) return file;

  let side = avatarOutputSideFor(crop);
  let smallest: Blob | undefined;
  for (;;) {
    const canvas = renderCrop(image, crop, side, false);
    let jpegCanvas: HTMLCanvasElement | undefined;
    for (const quality of encodeQualities) {
      let blob = await canvasToBlob(canvas, "image/webp", quality);
      if (blob?.type !== "image/webp") {
        jpegCanvas ??= renderCrop(image, crop, side, true);
        blob = await canvasToBlob(jpegCanvas, "image/jpeg", quality);
      }
      if (!blob) continue;
      if (!smallest || blob.size < smallest.size) smallest = blob;
      if (blob.size <= avatarTargetBytes) return toAvatarFile(blob, file.name);
    }
    if (side <= minOutputSide) break;
    side = Math.max(minOutputSide, Math.round(side * 0.75));
  }
  if (smallest && smallest.size <= maxAvatarBytes) {
    return toAvatarFile(smallest, file.name);
  }
  throw new Error("Avatar could not be compressed");
};

const toAvatarFile = (blob: Blob, originalName: string) => {
  const extension = blob.type === "image/webp" ? "webp" : "jpg";
  const base = originalName.replace(/\.[^.]*$/, "") || "avatar";
  return new File([blob], `${base}.${extension}`, { type: blob.type });
};
