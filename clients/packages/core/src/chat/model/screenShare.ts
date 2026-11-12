// What a screen shows, put into a draft (`chatView.attachScreen`): its picture as an image, and a line that names the
// screen by its link (`comma:screen/<device>/<screen>`, the screen's card in a message) with the time it was taken. The
// agent reads the link to know which screen the person means, and can look at it again or act on it.
import { DateTime } from "effect";

/** A screen of a computer: the computer's device id, and the screen's id (`display`, `android:<serial>`, `simulator:<udid>`). */
export type SharedScreen = {
  device: string;
  screen: string;
  name?: string | undefined;
};

const two = (value: number) => String(value).padStart(2, "0");

/** The time of day `at` (ms) is, here: `14:32:05`. */
function clockTime(at: number): string {
  const time = DateTime.toParts(
    DateTime.makeZonedUnsafe(at, { timeZone: DateTime.zoneMakeLocal() })
  );
  return `${two(time.hour)}:${two(time.minute)}:${two(time.second)}`;
}

/** The screen's link: the scheme a screen card in a message has (the client's screenLinks.ts reads it). */
export function screenLinkOf({ device, screen }: SharedScreen): string {
  return `comma:screen/${encodeURIComponent(device)}/${encodeURIComponent(screen)}`;
}

/** The draft's line for a screen put into the draft at `at`: its link, labelled with its name and the time. */
export function sharedScreenLine(shared: SharedScreen, at: number): string {
  const label = [shared.name?.trim(), clockTime(at)]
    .filter(Boolean)
    .join(" · ")
    .replace(/[[\]\n]/g, " ");
  return `[${label}](${screenLinkOf(shared)})`;
}

/** The image types a screen's picture comes as (the window's fitImageAttachment may make a PNG a JPEG or a WebP). */
export const SCREEN_PICTURE_TYPES = ["image/png", "image/jpeg", "image/webp"] as const;
export type ScreenPictureType = (typeof SCREEN_PICTURE_TYPES)[number];

const EXTENSIONS: Record<ScreenPictureType, string> = {
  "image/png": "png",
  "image/jpeg": "jpg",
  "image/webp": "webp",
};

/** Whether `bytes` begin as an image of `type` does: the server reads an image back by its name's type. */
export function isPictureOf(bytes: Uint8Array, type: ScreenPictureType): boolean {
  const starts = (offset: number, ...expected: number[]) =>
    expected.every((byte, index) => bytes[offset + index] === byte);
  switch (type) {
    case "image/png":
      return starts(0, 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a);
    case "image/jpeg":
      return starts(0, 0xff, 0xd8, 0xff);
    case "image/webp":
      return starts(0, 0x52, 0x49, 0x46, 0x46) && starts(8, 0x57, 0x45, 0x42, 0x50);
  }
}

/**
 * The picture's file name: `screen-143205.jpg`, from the time it was put into the draft and its type, and
 * `screen-143205-marked.jpg` where the person drew boxes on it.
 */
export function sharedScreenFileName(
  at: number,
  type: ScreenPictureType,
  marked = false
): string {
  return `screen-${clockTime(at).replaceAll(":", "")}${marked ? "-marked" : ""}.${EXTENSIONS[type]}`;
}
