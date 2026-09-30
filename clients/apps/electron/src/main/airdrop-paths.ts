import { join } from "node:path";
import { app } from "electron";

/** Comma receives and sends with the anonymous helper; see docs/clients.md. */
export function resolveAirDropBinaryPath(): string | undefined {
  if (process.platform !== "darwin") return undefined;
  return app.isPackaged
    ? join(
        process.resourcesPath,
        "native",
        process.platform,
        process.arch,
        "opendropkit"
      )
    : join(
        process.cwd(),
        "dist",
        "native",
        process.platform,
        process.arch,
        "opendropkit"
      );
}
