// The operator's `cache-cleanup` command: removes the known generated caches from a Cloud VM's archived home, and
// refuses to follow a symlink anywhere on the way to one.
import { lstat, rm } from "node:fs/promises";
import { isAbsolute, join, normalize, sep } from "node:path";
import { Effect } from "effect";
import { ARCHIVE_HOME_CACHE_DIRS, ARCHIVE_HOME_CACHE_FILES } from "./archive-caches.ts";

const toError = (e: unknown) => (e instanceof Error ? e : new Error(String(e)));

export function cleanupGeneratedHomeCaches(home: string): Effect.Effect<void, Error> {
  return Effect.tryPromise({
    try: async () => {
      const info = await lstat(home);
      if (!info.isDirectory() || info.isSymbolicLink()) throw new Error("VM home must be a directory");
      for (const relative of [...ARCHIVE_HOME_CACHE_DIRS, ...ARCHIVE_HOME_CACHE_FILES].sort()) await removeGeneratedCache(home, relative);
    },
    catch: toError,
  });
}

async function removeGeneratedCache(home: string, relative: string) {
  if (relative === "." || isAbsolute(relative) || relative.startsWith("..")) throw new Error(`invalid generated cache path: ${relative}`);
  let current = home;
  for (const part of normalize(relative).split(sep)) {
    current = join(current, part);
    let info;
    try {
      info = await lstat(current);
    } catch (e) {
      if ((e as NodeJS.ErrnoException).code === "ENOENT") return;
      throw e;
    }
    if (info.isSymbolicLink()) throw new Error(`generated cache path crosses symlink: ${current}`);
  }
  await rm(current, { recursive: true, force: true });
}
