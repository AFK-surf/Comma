import { mkdir, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

const exists = (path: string) =>
  stat(path).then(
    () => true,
    () => false
  );

/**
 * Runs a fixture build once per Playwright run and hands its directory to
 * every worker. Workers are children of the one runner process, so its pid
 * names the run. The first worker to claim the key builds; the others wait
 * for its marker, then serve the same output themselves.
 */
export async function sharedBuildDir(
  key: string,
  buildInto: (directory: string) => Promise<void>
): Promise<string> {
  const runRoot = join(tmpdir(), `comma-e2e-builds-${process.ppid}`);
  const directory = join(runRoot, key);
  await mkdir(runRoot, { recursive: true });
  let owner = true;
  try {
    await mkdir(directory);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
    owner = false;
  }
  if (owner) {
    try {
      await buildInto(directory);
    } catch (error) {
      await writeFile(join(directory, ".failed"), String(error));
      throw error;
    }
    await writeFile(join(directory, ".done"), "");
    return directory;
  }
  for (;;) {
    if (await exists(join(directory, ".done"))) return directory;
    if (await exists(join(directory, ".failed"))) {
      throw new Error(`The shared ${key} fixture build failed in another worker.`);
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
}
