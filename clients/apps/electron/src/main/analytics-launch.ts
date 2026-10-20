import { randomUUID } from "node:crypto";
import { access, mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import type { NativeInfo } from "@comma/native-bridge";

/** Observes a local profile, never a verified installation or reinstallation. */
export async function observeDesktopLaunch({
  appVersion,
  filePath,
  priorProfilePaths,
}: {
  appVersion: string;
  filePath: string;
  priorProfilePaths: readonly string[];
}): Promise<NativeInfo["desktopLaunch"]> {
  try {
    let previousVersion: string | undefined;
    try {
      const stored = JSON.parse(await readFile(filePath, "utf8"));
      if (typeof stored.appVersion !== "string" || !stored.appVersion) return undefined;
      previousVersion = stored.appVersion;
    } catch (error) {
      if (!isMissing(error)) return undefined;
    }
    const priorProfile = (await Promise.all(priorProfilePaths.map(fileExists))).some(
      Boolean
    );
    const kind = previousVersion
      ? previousVersion === appVersion
        ? "returning"
        : "version_changed"
      : priorProfile
        ? "existing_profile"
        : "new_profile";
    await mkdir(dirname(filePath), { recursive: true });
    const temporaryPath = `${filePath}.tmp`;
    await writeFile(temporaryPath, JSON.stringify({ appVersion }), { mode: 0o600 });
    await rename(temporaryPath, filePath);
    // The renderer uses this ID locally to skip a launch already observed.
    return { kind, eventId: randomUUID() };
  } catch {
    // Missing evidence or failed persistence must not manufacture a new profile.
    return undefined;
  }
}

async function fileExists(path: string) {
  try {
    await access(path);
    return true;
  } catch (error) {
    if (isMissing(error)) return false;
    throw error;
  }
}

function isMissing(error: unknown) {
  return (error as NodeJS.ErrnoException | undefined)?.code === "ENOENT";
}
