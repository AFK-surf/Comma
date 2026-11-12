import { animatedWebPOf, type WebPFrame } from "./webpAnimation";

/** What the picker takes. A GIF goes up as WebP: the server keeps JPEG, PNG and WebP. */
export const avatarTypes = ["image/jpeg", "image/png", "image/webp", "image/gif"];
/** Largest image the picker accepts; it is cropped and re-encoded before upload. */
export const maxAvatarSourceBytes = 10 * 1024 * 1024;
/** Largest upload the server accepts. */
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
  avatarTypes.includes(file.type) && file.size > 0 && file.size <= maxAvatarSourceBytes;

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
  file: Pick<File, "size" | "type">,
  source: AvatarSource,
  crop: AvatarCrop
) =>
  file.type !== "image/gif" &&
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
 * for engines that cannot encode WebP. A GIF or WebP that moves stays moving,
 * as an animated WebP (encodeAnimatedAvatar); where it cannot, its first frame
 * goes up still.
 */
export const encodeAvatar = async (
  file: File,
  image: CanvasImageSource,
  source: AvatarSource,
  crop: AvatarCrop
): Promise<File> => {
  if (file.type === "image/gif" || file.type === "image/webp") {
    const animated = await encodeAnimatedAvatar(file, source, crop);
    if (animated) return animated;
  }
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

/** Sides an animated avatar is drawn at, largest first, until it fits. */
const animatedSides = [256, 192, 128, 96];
const animatedQualities = [0.8, 0.6];
/** Frames decoded at most; longer animations keep their first ones. */
const maxAnimatedFrames = 300;

/**
 * A GIF or WebP that moves, cropped and kept moving as an animated WebP: the
 * original when it is already a whole square WebP small enough; otherwise
 * each frame is cropped, drawn and encoded again, smaller, at lower quality
 * and then with fewer frames, until it fits the server's limit. Undefined
 * when it has one frame, or where the browser cannot read its frames
 * (no ImageDecoder) or encode WebP: then it goes up as a still picture.
 */
export const encodeAnimatedAvatar = async (
  file: File,
  source: AvatarSource,
  crop: AvatarCrop
): Promise<File | undefined> => {
  if (typeof ImageDecoder === "undefined") return undefined;
  const decoder = new ImageDecoder({
    data: new Uint8Array(await file.arrayBuffer()),
    type: file.type,
  });
  try {
    await Promise.all([decoder.tracks.ready, decoder.completed]);
    const count = Math.min(
      decoder.tracks.selectedTrack?.frameCount ?? 1,
      maxAnimatedFrames
    );
    if (count <= 1) return undefined;
    const whole = source.width === source.height && crop.size >= source.width - 0.5;
    if (whole && file.type === "image/webp" && file.size <= maxAvatarBytes) return file;
    for (const side of animatedSides.filter(
      (candidate, index) => index === animatedSides.length - 1 || candidate <= crop.size
    )) {
      for (const quality of animatedQualities) {
        const frames = await croppedFrames(decoder, count, crop, side, quality);
        if (!frames) return undefined;
        for (const step of [1, 2, 3]) {
          const webp = animatedWebPOf(everyNth(frames, step), side);
          if (webp.byteLength <= maxAvatarBytes) return toAnimatedFile(webp, file.name);
        }
      }
    }
    throw new Error("Avatar could not be compressed");
  } finally {
    decoder.close();
  }
};

/** Every frame cropped to a `side` px still WebP; undefined when the browser cannot encode WebP. */
const croppedFrames = async (
  decoder: ImageDecoder,
  count: number,
  crop: AvatarCrop,
  side: number,
  quality: number
) => {
  const canvas = document.createElement("canvas");
  canvas.width = side;
  canvas.height = side;
  const context = canvas.getContext("2d");
  if (!context) throw new Error("Canvas 2D context is unavailable");
  context.imageSmoothingEnabled = true;
  context.imageSmoothingQuality = "high";
  const frames: WebPFrame[] = [];
  for (let frameIndex = 0; frameIndex < count; frameIndex++) {
    const { image } = await decoder.decode({ frameIndex });
    context.clearRect(0, 0, side, side);
    context.drawImage(image, crop.x, crop.y, crop.size, crop.size, 0, 0, side, side);
    // VideoFrame durations are in microseconds.
    const duration = (image.duration ?? 0) / 1000;
    image.close();
    const blob = await canvasToBlob(canvas, "image/webp", quality);
    if (blob?.type !== "image/webp") return undefined;
    frames.push({
      webp: new Uint8Array(await blob.arrayBuffer()),
      // Under 20 ms shows as 100 ms, as browsers show a GIF.
      duration: duration < 20 ? 100 : duration,
    });
  }
  return frames;
};

/** Every `step`th frame, each shown as long as the frames it stands for. */
const everyNth = (frames: WebPFrame[], step: number) => {
  const out: WebPFrame[] = [];
  frames.forEach((frame, index) => {
    const last = out.at(-1);
    if (index % step === 0 || !last) out.push({ ...frame });
    else last.duration += frame.duration;
  });
  return out;
};

const toAnimatedFile = (webp: Uint8Array<ArrayBuffer>, originalName: string) => {
  const base = originalName.replace(/\.[^.]*$/, "") || "avatar";
  return new File([webp], `${base}.webp`, { type: "image/webp" });
};
