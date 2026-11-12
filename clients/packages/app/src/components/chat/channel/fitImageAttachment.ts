import {
  isImageAttachment,
  MAX_ATTACHMENT_BYTES,
  type AttachmentUploadInput,
} from "@comma/core/chat";

/** What the server reads back as an image (`Comma.GroupFiles`). */
const MAX_IMAGE_EDGE = 4_096;
const MAX_IMAGE_PIXELS = 16_777_216;
const LOSSY_QUALITY = 0.85;
const LOSSY_SCALES = [1, 0.75, 0.5, 0.35, 0.25] as const;
const EXTENSIONS: Record<string, string> = {
  "image/jpeg": ".jpg",
  "image/png": ".png",
  "image/webp": ".webp",
};

function draw(bitmap: ImageBitmap, scale: number) {
  const width = Math.max(1, Math.floor(bitmap.width * scale));
  const height = Math.max(1, Math.floor(bitmap.height * scale));
  const canvas = new OffscreenCanvas(width, height);
  const context = canvas.getContext("2d");
  if (!context) throw new Error("No 2D canvas.");
  context.drawImage(bitmap, 0, 0, width, height);
  return { canvas, context, height, width };
}

const fits = (blob: Blob) => blob.size <= MAX_ATTACHMENT_BYTES;

/**
 * The image as small as it needs to be: a PNG stays one when that fits, as text
 * stays sharp; otherwise JPEG, or WebP to keep transparency, smaller at each step.
 */
async function encodeToFit(bitmap: ImageBitmap, fit: number, isPng: boolean) {
  const { canvas, context, height, width } = draw(bitmap, fit);
  if (isPng) {
    const png = await canvas.convertToBlob({ type: "image/png" });
    if (fits(png)) return png;
  }
  const pixels = context.getImageData(0, 0, width, height).data;
  let opaque = true;
  for (let alpha = 3; opaque && alpha < pixels.length; alpha += 4) {
    opaque = pixels[alpha] === 255;
  }
  const type = opaque ? "image/jpeg" : "image/webp";
  for (const scale of LOSSY_SCALES) {
    const blob = await draw(bitmap, fit * scale).canvas.convertToBlob({
      quality: LOSSY_QUALITY,
      type,
    });
    if (fits(blob)) return blob;
  }
  return undefined;
}

/**
 * An image the server would refuse or could not read back, made to fit; any other
 * file, and an image this window cannot decode or shrink, as it is. A GIF stays
 * as it is because a canvas keeps only its first frame.
 */
export async function fitImageAttachment(
  file: AttachmentUploadInput
): Promise<AttachmentUploadInput> {
  if (!isImageAttachment(file.name) || /\.gif$/i.test(file.name)) return file;
  try {
    const bitmap = await createImageBitmap(file.data);
    try {
      const fit = Math.min(
        1,
        MAX_IMAGE_EDGE / Math.max(bitmap.width, bitmap.height),
        Math.sqrt(MAX_IMAGE_PIXELS / (bitmap.width * bitmap.height))
      );
      if (fit === 1 && file.size <= MAX_ATTACHMENT_BYTES) return file;
      const blob = await encodeToFit(bitmap, fit, /\.png$/i.test(file.name));
      if (!blob) return file;
      const name = file.name.replace(/\.[^.]*$/, EXTENSIONS[blob.type] ?? "");
      return {
        data: new File([blob], name, { type: blob.type }),
        name,
        size: blob.size,
      };
    } finally {
      bitmap.close();
    }
  } catch {
    return file;
  }
}
