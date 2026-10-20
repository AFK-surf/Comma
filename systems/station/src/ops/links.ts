// Symbolic links where the machine may refuse them (Windows without the privilege: Developer Mode gives it, an
// administrator has it; platform.linkRefused). What stands in for a refused link is not the same thing (a junction
// holds an absolute target, so it breaks when its directory moves; a copy does not follow its target), so it is the
// caller's to allow, and what was made is said: a caller that cannot have a stand-in yet (archive.ts, before the
// restored tree is at its final path) is told `refused` and makes it later, where it stays.
import { copyFileSync, statSync, symlinkSync } from "node:fs";
import { copyFile, stat, symlink } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { platform } from "../platform/index.ts";

/// What stands in for a refused link, when allowed: a junction for a directory (no privilege needed), a copy of a file.
export type StandIns = { junction?: boolean; copy?: boolean };
/// What was made: the link; a junction or a copy in its place; nothing, as its target is not there to stand in for
/// (yet), or as no stand-in was allowed.
export type Made = "link" | "junction" | "copy" | "missing" | "refused";

type MakeSync = (target: string, path: string, type?: "dir" | "file" | "junction") => void;
type Make = (target: string, path: string, type?: "dir" | "file" | "junction") => Promise<void>;

/// `path` linked to `target` (relative to `path`'s directory, as a link's is), or, refused, what `allow` lets stand in.
export function linkSync(target: string, path: string, allow: StandIns, make: MakeSync = symlinkSync): Made {
  try {
    make(target, path);
    return "link";
  } catch (error) {
    if (!platform.linkRefused(error)) throw error;
  }
  if (!allow.junction && !allow.copy) return "refused";
  const absolute = resolve(dirname(path), target);
  const st = statSync(absolute, { throwIfNoEntry: false });
  if (st === undefined) return "missing";
  if (st.isDirectory()) {
    if (!allow.junction) return "refused";
    make(absolute, path, "junction");
    return "junction";
  }
  if (!allow.copy) return "refused";
  copyFileSync(absolute, path);
  return "copy";
}

export async function link(target: string, path: string, allow: StandIns, make: Make = symlink): Promise<Made> {
  try {
    await make(target, path);
    return "link";
  } catch (error) {
    if (!platform.linkRefused(error)) throw error;
  }
  if (!allow.junction && !allow.copy) return "refused";
  const absolute = resolve(dirname(path), target);
  const st = await stat(absolute).catch(() => undefined);
  if (st === undefined) return "missing";
  if (st.isDirectory()) {
    if (!allow.junction) return "refused";
    await make(absolute, path, "junction");
    return "junction";
  }
  if (!allow.copy) return "refused";
  await copyFile(absolute, path);
  return "copy";
}
