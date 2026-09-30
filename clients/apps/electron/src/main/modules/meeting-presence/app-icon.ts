import { execFile } from "node:child_process";
import { promisify } from "node:util";

const run = promisify(execFile);

/** OS-owned bundle icon; only catalogued meeting products are looked up, once each. */
export function createMeetingAppIconReader(helperPath: string | undefined) {
  const cache = new Map<string, Promise<string | undefined>>();
  return (bundleIdentifier: string): Promise<string | undefined> => {
    if (!helperPath) return Promise.resolve(undefined);
    const cached = cache.get(bundleIdentifier);
    if (cached) return cached;
    const icon = run(helperPath, ["--app-icon", bundleIdentifier], {
      encoding: "buffer",
      maxBuffer: 64 * 1024,
      timeout: 2_000,
      killSignal: "SIGKILL",
    })
      .then(({ stdout }) => `data:image/png;base64,${stdout.toString("base64")}`)
      .catch(() => undefined);
    cache.set(bundleIdentifier, icon);
    return icon;
  };
}
