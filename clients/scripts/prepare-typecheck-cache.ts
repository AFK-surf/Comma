import { readdirSync, utimesSync } from "node:fs";
import { join, resolve } from "node:path";

export function prepareTypecheckCache(workspace: string): void {
  for (const relative of ["node_modules/.tmp", "clients/node_modules/.tmp"]) {
    const directory = join(workspace, relative);
    let entries;
    try {
      entries = readdirSync(directory, { withFileTypes: true });
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") continue;
      throw error;
    }
    for (const entry of entries) {
      if (entry.isFile() && entry.name.endsWith(".tsbuildinfo")) {
        // Restored timestamps must not let the builder skip current inputs.
        // Keep the file signatures and diagnostics for incremental checking.
        utimesSync(join(directory, entry.name), 0, 0);
      }
    }
  }
}

if (import.meta.main) {
  prepareTypecheckCache(resolve(import.meta.dirname, "../.."));
}
