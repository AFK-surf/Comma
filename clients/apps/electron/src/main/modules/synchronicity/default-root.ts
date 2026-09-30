import { existsSync } from "node:fs";
import { mkdir, rename } from "node:fs/promises";
import { join, win32 } from "node:path";

/** Default local folder and the previous install path. */
export function defaultLocalRoots(home: string) {
  return {
    localRoot: join(home, "Comma Drive"),
    legacyLocalRoots: [join(home, "Drive")],
  };
}

/** The filesystem source published as the install's default space. */
export interface DefaultSpaceRoot {
  id: string;
  root: string;
  /** Folder names earlier installs used for `root`; the first that exists is moved into place. */
  legacyRoots?: string[] | undefined;
}

type Log = { info(message: string): void; warn(message: string): void } | undefined;

/**
 * Returns the folder that is safe to publish. A conflicting destination or
 * failed rename must keep the legacy source, never publish unrelated/empty data.
 */
export async function prepareDefaultRoot(
  { legacyRoots = [], root }: DefaultSpaceRoot,
  log?: Log
): Promise<string> {
  for (const legacy of legacyRoots) {
    if (!existsSync(legacy)) continue;
    if (existsSync(root)) {
      log?.warn(`synchronicity kept ${legacy}: destination ${root} already exists`);
      return legacy;
    }
    try {
      await rename(legacy, root);
      log?.info(`synchronicity moved the default folder ${legacy} → ${root}`);
      return root;
    } catch (error: unknown) {
      log?.warn(
        `synchronicity could not move ${legacy} to ${root}: ${error instanceof Error ? error.message : String(error)}`
      );
      return legacy;
    }
  }
  await mkdir(root, { recursive: true });
  return root;
}

/**
 * The path `source ls` reports for a space, or nothing when the space is
 * unpublished. Rows read `<space> <kind> <path>`; the path keeps its spaces.
 */
export function publishedSourcePath(stdout: string, space: string): string | undefined {
  for (const line of stdout.split("\n")) {
    const match = /^\s*(\S+)\s+(\S+)\s*(.*?)\s*$/.exec(line);
    if (match?.[1] === space) return match[3] ?? "";
  }
  return undefined;
}

/** Rust canonicalization reports Windows paths with an extended-length prefix. */
export function sameSourcePath(
  left: string,
  right: string,
  platform: NodeJS.Platform = process.platform
): boolean {
  return platform === "win32"
    ? win32.toNamespacedPath(left) === win32.toNamespacedPath(right)
    : left === right;
}
