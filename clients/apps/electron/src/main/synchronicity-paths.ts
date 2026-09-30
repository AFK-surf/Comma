import { join } from "node:path";
import { app } from "electron";

/**
 * Where the bundled synchronicity daemon lives: beside salix-connect under
 * `native/<platform>/<arch>/` in a packaged app, and under `dist/native/`
 * of the app directory in development (`pnpm build:native:synch` fetches
 * it there without needing the Go or Swift toolchains).
 */
export function resolveSynchBinaryPath(
  options: { binaryPath?: string | undefined } = {}
) {
  if (options.binaryPath) {
    return options.binaryPath;
  }

  const binaryName = process.platform === "win32" ? "synch.exe" : "synch";
  if (app.isPackaged) {
    return join(
      process.resourcesPath,
      "native",
      process.platform,
      process.arch,
      binaryName
    );
  }

  return join(
    process.cwd(),
    "dist",
    "native",
    process.platform,
    process.arch,
    binaryName
  );
}
