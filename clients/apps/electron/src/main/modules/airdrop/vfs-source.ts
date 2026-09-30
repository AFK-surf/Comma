import { realpath } from "node:fs/promises";
import { isAbsolute, join, relative } from "node:path";
import { z } from "zod";
import { resolveLocalDriveTarget } from "../synchronicity/local-path";
import type { SynchronicityProvider } from "../synchronicity";

const drivePathSchema = z
  .string()
  .min(2)
  .max(4096)
  .refine(
    (path) =>
      path.startsWith("/drive/") &&
      !path.includes("\0") &&
      !path.includes("\\") &&
      path
        .slice(1)
        .split("/")
        .every((part) => part !== "" && part !== "." && part !== ".."),
    "Use an absolute /drive/... file path. Copy Task VFS files into Drive with fs.copy_file first."
  );

/** Resolve the existing Drive mount. No file is downloaded, copied, or modified. */
export async function resolveAirDropVfsPath(
  input: string,
  drive: Pick<SynchronicityProvider, "state">
): Promise<string> {
  drivePathSchema.parse(input);
  const target = await resolveLocalDriveTarget(drive);
  const drivePath = input.slice("/drive/".length);
  try {
    const root = await realpath(target.localRoot);
    const path = await realpath(join(root, drivePath));
    const withinRoot = relative(root, path);
    if (
      !withinRoot ||
      isAbsolute(withinRoot) ||
      withinRoot.replaceAll("\\", "/") !== drivePath
    )
      throw new Error(
        "Drive path must remain inside its mapped local folder without symbolic links."
      );
    return path;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT")
      throw new Error(
        "The Drive file is not available locally. It may still be syncing, or may have been moved or deleted.",
        { cause: error }
      );
    throw error;
  }
}
