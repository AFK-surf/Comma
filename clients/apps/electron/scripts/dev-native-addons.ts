import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { resolve } from "node:path";
import {
  fileApplicationsAddonDistPath,
  fontFamiliesAddonDistPath,
  notificationAuthorizationAddonDistPath,
} from "./native-paths";

/**
 * The in-process Node-API addons a from-source run needs in `dist/native`.
 *
 * `pnpm dev` runs the whole native build, but a bare `electron-forge start` in
 * a checkout that never built it starts with an empty `dist/native`. Main then
 * loads no file applications addon, so `files.listOpenApplications` answers
 * `unavailable` and every "Open in" menu shows "Could not load apps"; the
 * notification authorization readback and the Appearance font list degrade the
 * same way. Each is a few seconds of node-gyp, unlike the Swift and Go hosts,
 * so the start hook builds whichever is missing instead of leaving the run
 * degraded.
 */
export interface DevNativeAddon {
  label: string;
  output: string;
  buildFlag: string;
}

export function devNativeAddons(appDir: string): DevNativeAddon[] {
  return [
    {
      label: "file applications addon",
      output: fileApplicationsAddonDistPath(appDir),
      buildFlag: "--file-applications-only",
    },
    {
      label: "notification authorization addon",
      output: notificationAuthorizationAddonDistPath(appDir),
      buildFlag: "--notification-authorization-only",
    },
    {
      label: "font families addon",
      output: fontFamiliesAddonDistPath(appDir),
      buildFlag: "--font-families-only",
    },
  ];
}

export function missingDevNativeAddons(appDir: string) {
  return devNativeAddons(appDir).filter((addon) => !existsSync(addon.output));
}

function runBuildNative(appDir: string, buildFlag: string) {
  const result = spawnSync(
    process.execPath,
    ["--import", "tsx", "scripts/build-native.ts", buildFlag],
    { cwd: appDir, stdio: "inherit", shell: false }
  );
  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error(`build-native.ts ${buildFlag} exited with ${result.status}`);
  }
}

/** Builds the missing addons; an explicit `COMMA_SKIP_NATIVE_BUILD=1` still wins. */
export function ensureDevNativeAddons({
  appDir = resolve(import.meta.dirname, ".."),
  env = process.env,
  build = runBuildNative,
}: {
  appDir?: string;
  env?: NodeJS.ProcessEnv;
  build?: (appDir: string, buildFlag: string) => void;
} = {}) {
  const missing = missingDevNativeAddons(appDir);
  if (missing.length === 0 || env.COMMA_SKIP_NATIVE_BUILD === "1") return missing;
  for (const addon of missing) {
    console.log(`Building the missing ${addon.label} for this from-source run.`);
    build(appDir, addon.buildFlag);
  }
  return missing;
}
