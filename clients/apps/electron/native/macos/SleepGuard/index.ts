import { existsSync } from "node:fs";
import { createRequire } from "node:module";
import { resolve } from "node:path";

export const sleepGuardAddonFileName = "comma-sleep-guard.node";

/** `SMAppService.Status` by name, as System Settings › Login Items sees it. */
export type SleepGuardDaemonStatus =
  | "enabled"
  | "requiresApproval"
  | "notRegistered"
  | "notFound";

export type SleepGuardAddon = {
  status(plistName: string): SleepGuardDaemonStatus;
  /** `error` is macOS's reason when it refused; judge success by `status`. */
  register(plistName: string): { status: SleepGuardDaemonStatus; error?: string };
  openLoginItemsSettings(): void;
  setSleepDisabled(
    serviceName: string,
    disabled: boolean
  ): Promise<{ ok: boolean; error?: string }>;
};

function isSleepGuardAddon(value: unknown): value is SleepGuardAddon {
  if (typeof value !== "object" || value === null) return false;
  const addon = value as Partial<SleepGuardAddon>;
  return (
    typeof addon.status === "function" &&
    typeof addon.register === "function" &&
    typeof addon.openLoginItemsSettings === "function" &&
    typeof addon.setSleepDisabled === "function"
  );
}

/**
 * Loads the addon from the packaged resources, or from a development build.
 * Returns undefined off macOS or when no build exists; callers treat that as
 * "lid-closed keep-awake is unavailable".
 */
export function loadSleepGuardAddon({
  isPackaged = false,
  logger,
  resourcesPath = (process as NodeJS.Process & { resourcesPath?: string })
    .resourcesPath,
}: {
  isPackaged?: boolean;
  logger?: Pick<Console, "warn">;
  resourcesPath?: string;
} = {}): SleepGuardAddon | undefined {
  if (process.platform !== "darwin") return undefined;
  const packaged = resourcesPath
    ? resolve(resourcesPath, "native/macos", sleepGuardAddonFileName)
    : undefined;
  const candidates = isPackaged
    ? [packaged]
    : [
        packaged,
        resolve(process.cwd(), "dist/native/macos", sleepGuardAddonFileName),
        resolve(
          process.cwd(),
          "apps/electron/dist/native/macos",
          sleepGuardAddonFileName
        ),
      ];
  // See NotificationAuthorization: Vite empties `import.meta` in bundled Main.
  const require = createRequire(resolve(process.cwd(), "comma-sleep-guard-loader.cjs"));
  for (const path of candidates) {
    if (!path || !existsSync(path)) continue;
    try {
      const addon: unknown = require(path);
      if (isSleepGuardAddon(addon)) return addon;
      logger?.warn(`[sleep-guard] addon at ${path} has an invalid API`);
    } catch (error) {
      logger?.warn(`[sleep-guard] addon at ${path} failed to load`, error);
    }
  }
  return undefined;
}

/** The guard's launchd label and Mach service; one per app flavor. */
export function sleepGuardServiceName(appBundleId: string) {
  return `${appBundleId}.sleep-guard`;
}

export function sleepGuardPlistName(appBundleId: string) {
  return `${sleepGuardServiceName(appBundleId)}.plist`;
}
