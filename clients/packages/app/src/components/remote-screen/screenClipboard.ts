// What goes between a computer's screen a person drives and this device's clipboard (@comma/mesh screen-wire.ts,
// `clipboard`): a copy made on the screen is put on this device's clipboard (at once where the browser lets it, else
// offered with a press), and a paste here of a type the screen carries sets the screen's clipboard and pastes it there.
// Only while the view drives the screen, and only of the types its station listed (none from a station before them:
// nothing is offered or sent, and a paste is typed as text, as before).
//
// Ported from still.fail (github.com/AFK-surf/still.fail, afk/main 3d517e022e) web/src/screen/Transfer.tsx: `putClip`,
// `pasted`, and ScreenViewer.tsx's paste rule (`paste`: taken onto the screen's clipboard where it carries a PNG file
// or text of the paste, else typed). Its files sent to the machine and their panel are not ported. `putClip` writes
// through Cue's clipboard boundary, not the page's `navigator.clipboard`: the desktop app's session denies the renderer
// every permission, clipboard-write included, and Main writes the clipboard (nativePlatformActions.ts,
// imageClipboard.ts); the web keeps the browser's API.
import type { ScreenClip } from "@comma/core-client";
import { nativePlatformClipboard } from "../../nativePlatformActions";
import { copyImageBlob } from "../../runtime-files/imageClipboard";

export type ScreenClipType = "text" | "png";

/** How this device's clipboard is written: text, or a PNG picture. */
export type ClipWriter = {
  text(text: string): Promise<void>;
  png(png: Blob): Promise<void>;
};

const deviceClipboard: ClipWriter = {
  text: (text) => nativePlatformClipboard.writeText(text),
  png: (png) => copyImageBlob(png),
};

/** Puts a clip on this device's clipboard; fails where it may not be written (the web: no focus, no gesture). */
export async function putClip(
  clip: ScreenClip,
  clipboard: ClipWriter = deviceClipboard
): Promise<void> {
  if (clip.type === "text") return clipboard.text(clip.text);
  await clipboard.png(
    new Blob([clip.data as Uint8Array<ArrayBuffer>], { type: "image/png" })
  );
}

/**
 * Whether a paste here goes onto the screen's clipboard (and is pasted there): it carries a PNG file and the screen
 * takes pictures, or text and the screen takes text. Else it is typed, as a paste was before.
 */
export function takesPaste(
  data: Pick<DataTransfer, "files" | "getData">,
  types: readonly ScreenClipType[]
): boolean {
  if (types.length === 0) return false;
  const png =
    types.includes("png") && [...data.files].some((f) => f.type === "image/png");
  return png || (types.includes("text") && data.getData("text/plain") !== "");
}

/** What a paste here sets on the screen's clipboard, of the types it carries (a PNG first, else text); null: none. */
export async function pasted(
  data: Pick<DataTransfer, "files" | "getData">,
  types: readonly ScreenClipType[]
): Promise<ScreenClip | null> {
  const png = types.includes("png")
    ? [...data.files].find((f) => f.type === "image/png")
    : undefined;
  if (png) return { type: "png", data: new Uint8Array(await png.arrayBuffer()) };
  const text = data.getData("text/plain");
  return text && types.includes("text") ? { type: "text", text } : null;
}
