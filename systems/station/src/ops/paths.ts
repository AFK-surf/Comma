// Paths as the station checks them (the Rust station's Path, files.rs `clean`): absolute, worked out without following
// links, and compared component by component, as the machine has them (platform.paths: on Windows `\` and `/` both
// separate, a drive or a share starts an absolute path, and case does not tell two paths apart).
import { platform } from "../platform/index.ts";

/// A path's components (empty ones kept: callers drop what they do not want).
export const segments = (path: string): string[] => path.split(platform.paths.separator);

/// files.rs `clean` on Unix: the path absolute (a leading `/`), `.` and `..` worked out lexically. What a relative path
/// from a Unix machine is made of, whatever this one is (`/` separates; where `\` does too, it as well).
export function cleanPosix(path: string): string {
  const out: string[] = [];
  for (const part of segments(path)) {
    if (part === "" || part === ".") continue;
    if (part === "..") out.pop();
    else out.push(part);
  }
  return `/${out.join("/")}`;
}

/// A path absolute, with `.` and `..` worked out (no link followed).
export const clean = (path: string): string => platform.paths.clean(path);

/// The same path (both cleaned, or both canonical).
export const samePath = (a: string, b: string) => platform.paths.key(a) === platform.paths.key(b);

/// Path::starts_with: `path` is `dir` or under it (both cleaned, or both canonical).
export const within = (path: string, dir: string): boolean => platform.paths.within(path, dir);

/// Under `dir`, and not `dir` itself.
export const inside = (path: string, dir: string) => !samePath(path, dir) && within(path, dir);

/// Path::file_name: the last part; none for `..` or the root.
export function fileName(path: string): string | null {
  const parts = segments(path).filter((p) => p !== "" && p !== ".");
  const last = parts.at(-1);
  if (last === undefined || last === "..") return null;
  // A root alone (a drive, `C:`) is not a name.
  return parts.length === 1 && platform.paths.isRootName(last) ? null : last;
}

/// The last part of a path from any machine (another station's, Unix or Windows): what follows its last `/` or `\`.
export const anyBaseName = (path: string) => path.split(/[\\/]/).filter((p) => p !== "").at(-1) ?? "";

/// Path::join as Rust has it: an absolute `given` replaces `base`; nothing is normalised.
export const joinPath = (base: string, given: string): string => platform.paths.join(base, given);

/// A path given as relative, split into its components when it is one: not rooted (`/`, a drive, a share, a stream),
/// none of its components `..`. `.` and empty components are the caller's to judge (they are kept).
export function relativeParts(path: string): string[] | null {
  if (path === "" || platform.paths.rooted(path)) return null;
  const parts = segments(path);
  return parts.includes("..") ? null : parts;
}
