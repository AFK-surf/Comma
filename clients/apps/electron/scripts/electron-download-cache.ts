import { existsSync } from "node:fs";
import { join } from "node:path";

/** Keep downloads on the host when Tartelet replaces a runner VM. */
export function electronDownloadCache(
  env: NodeJS.ProcessEnv = process.env,
  sharedDirectory = "/Volumes/My Shared Files/cache"
): string | undefined {
  if (!env.CI || !env.RUNNER_NAME || !existsSync(sharedDirectory)) {
    return undefined;
  }

  // Each runner executes one job at a time. Separate its writes from other VMs.
  return join(sharedDirectory, "comma-electron", encodeURIComponent(env.RUNNER_NAME));
}
