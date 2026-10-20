import { execFileSync } from "node:child_process";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

/**
 * Electron downloads its binary on the first `require("electron")` when it
 * is missing (pnpm does not run its install script). Each Node test file runs
 * in a process of its own, so two files requiring Electron at once extracted
 * into the same `node_modules/electron/dist` and one failed with EEXIST.
 * Install it once, before any test file runs; when it is installed already,
 * Electron's installer returns at once.
 */
export default function installElectron() {
  const electronApp = fileURLToPath(
    new URL("../../../apps/electron/package.json", import.meta.url)
  );
  const installer = createRequire(electronApp).resolve("electron/install.js");
  execFileSync(process.execPath, [installer], { stdio: "inherit" });
}
