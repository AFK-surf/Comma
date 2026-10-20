// A video's poster: a small picture of its first frame, for a chat to show in its place, so a page or a phone need not
// fetch the whole video (up to 1 GB) to show what it is. Made on first asking, by what the machine has: QuickLook on a
// Mac (`qlmanage`, then `sips` to make it a JPEG), else ffmpeg where it is installed; kept in <data>/thumbs beside the
// images' thumbnails, by the video's path. None where neither can make it: the chat then shows the video without one.
import { execFile } from "node:child_process";
import { mkdirSync, mkdtempSync, readdirSync, renameSync, rmSync, statSync } from "node:fs";
import { join } from "node:path";
import { idOf } from "./thumbs.ts";
import { platform } from "../platform/index.ts";

/// The longer side of a poster, in pixels.
const SIDE = 640;
/// How long making one may take.
const MAKING_MS = 30_000;

/// Whether a file is a video a poster is made for, by its name.
export const wanted = (name: string) => [".mp4", ".m4v", ".mov", ".webm", ".ogv", ".mkv", ".avi"].some((e) => name.toLowerCase().endsWith(e));

const run = (file: string, args: string[]) =>
  new Promise<boolean>((resolve) => {
    execFile(file, args, { timeout: MAKING_MS, windowsHide: true }, (error) => resolve(error === null));
  });

/// Posters being made, by where they go: asked again meanwhile, the same one is waited on.
const making = new Map<string, Promise<string | null>>();
/// Videos none could be made for (by poster path, with the video's size and time then): not tried again until it changes.
const failed = new Map<string, string>();

/// The video's poster (a JPEG), made if it is not there yet; null when none can be made.
export async function poster(video: string, thumbs: string): Promise<string | null> {
  const path = join(thumbs, `${idOf(video)}.poster.jpg`);
  if (statSync(path, { throwIfNoEntry: false })?.isFile()) return path;
  const st = statSync(video, { throwIfNoEntry: false });
  if (!st?.isFile()) return null;
  const stamp = `${st.size}:${st.mtimeMs}`;
  if (failed.get(path) === stamp) return null;
  let made = making.get(path);
  if (made === undefined) {
    made = make(video, thumbs, path).finally(() => making.delete(path));
    making.set(path, made);
  }
  const got = await made;
  if (got === null) failed.set(path, stamp);
  return got;
}

async function make(video: string, thumbs: string, path: string): Promise<string | null> {
  mkdirSync(thumbs, { recursive: true });
  const work = mkdtempSync(join(thumbs, ".poster-"));
  try {
    const jpeg = join(work, "poster.jpg");
    let ok = false;
    if (platform.hasQuickLook && (await run("/usr/bin/qlmanage", ["-t", "-s", String(SIDE), "-o", work, video]))) {
      // QuickLook writes <name>.png into the directory it is given.
      const png = readdirSync(work).find((f) => f.endsWith(".png"));
      ok = png !== undefined && (await run("/usr/bin/sips", ["-s", "format", "jpeg", "-s", "formatOptions", "80", join(work, png), "--out", jpeg]));
    }
    if (!ok) ok = await run("ffmpeg", ["-nostdin", "-loglevel", "error", "-y", "-i", video, "-frames:v", "1", "-vf", `scale='if(gt(iw,ih),min(${SIDE},iw),-2)':'if(gt(iw,ih),-2,min(${SIDE},ih))'`, "-q:v", "4", jpeg]);
    if (!ok || !(statSync(jpeg, { throwIfNoEntry: false })?.size ?? 0)) return null;
    renameSync(jpeg, path);
    return path;
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
}
