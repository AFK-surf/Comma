// Small copies of the images sent in chats, for the chat to show (the Rust station's thumbs.rs): a chat of screenshots would
// otherwise have pages take in megabytes to show each at a few hundred pixels. Made when an image is kept (and on first
// asking for one kept before), in <data>/thumbs, by the image's path; the image itself stays as it was, for the
// preview. And each image's ThumbHash, kept with the message: a blurred likeness of it, a few dozen bytes, shown until it
// loads. Decoding, resizing and encoding are the Rust's own code in the native addon (native/mesh/src/thumbs.rs), off
// this thread; what is here is which files, where, and what the message keeps.
import { createHash } from "node:crypto";
import { statSync } from "node:fs";
import { join } from "node:path";
import { log } from "../ops/log.ts";
import { type Mesh, loadMesh } from "../mesh/native.ts";
import type { Attachment } from "../store/rows.ts";

/// An image already this small is shown itself.
export const SMALL = 24 * 1024;

export type Thumbnail = { path: string; type: string };
export type Codecs = Pick<Mesh, "thumbnail" | "thumbhash">;

/// Where the thumbnails are kept.
export const dir = (dataDir: string) => join(dataDir, "thumbs");

/// Whether a file is an image a thumbnail is made for (a GIF would lose its motion).
export const wanted = (name: string) => [".png", ".jpg", ".jpeg", ".webp"].some((e) => name.toLowerCase().endsWith(e));

/// The thumbnail's name: the first 16 bytes of the SHA-256 of the image's path, in hex.
export const idOf = (image: string) => createHash("sha256").update(image).digest().subarray(0, 16).toString("hex");

/// The thumbnail made before, if there is one.
export function kept(thumbs: string, id: string): Thumbnail | null {
  for (const [ext, type] of [
    ["jpg", "image/jpeg"],
    ["png", "image/png"],
  ] as const) {
    const path = join(thumbs, `${id}.${ext}`);
    if (statSync(path, { throwIfNoEntry: false })?.isFile()) return { path, type };
  }
  return null;
}

/// The addon's codecs; none where it is not there (a checkout not built), and then images are shown as they are and kept
/// without a ThumbHash.
let codecs: Codecs | null | undefined;
function native(): Codecs | null {
  if (codecs === undefined) {
    try {
      codecs = loadMesh();
    } catch (e) {
      log.warn("thumbs", "no image codecs: images are shown as they are", { error: (e as Error).message });
      codecs = null;
    }
  }
  return codecs;
}

/// thumbs.rs `thumbnail`: the image's thumbnail and its type, made if it is not there yet; null when the image is shown
/// itself (small already, or not readable as an image).
export async function thumbnail(image: string, thumbs: string, using: Codecs | null = native()): Promise<Thumbnail | null> {
  if (using === null) return null;
  try {
    return await using.thumbnail(image, thumbs);
  } catch {
    return null;
  }
}

/// thumbs.rs `keep`: readies the images of a message about to be kept: each is decoded once, for its ThumbHash, given now
/// (the message carries it), and its thumbnail, made after, off this thread. Files not readable as images stay as they
/// came.
export async function keep(files: Attachment[], thumbs: string, using: Codecs | null = files.some((f) => wanted(f.name)) ? native() : null): Promise<Attachment[]> {
  if (using === null || !files.some((f) => wanted(f.name))) return files;
  const out: Attachment[] = [];
  for (const file of files) {
    if (!wanted(file.name)) {
      out.push(file);
      continue;
    }
    let hashed: Awaited<ReturnType<Codecs["thumbhash"]>> = null;
    try {
      hashed = await using.thumbhash(file.path, thumbs);
    } catch {}
    out.push(hashed === null ? file : { ...file, thumbhash: hashed.hash });
  }
  return out;
}
