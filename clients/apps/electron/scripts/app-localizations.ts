import type { HookFunction } from "@electron/packager";
import { readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

/** A strings file with no strings: it changes nothing the bundle says. */
const placeholderName = "InfoPlist.strings";
const placeholder =
  "/* Keeps this localization when an update installs the app: Velopack drops empty directories. */\n";

/**
 * The app's `Contents/Resources/<lang>.lproj` directories are empty, and they are
 * what tells macOS which languages the app has: Chromium takes its locale, and
 * with it the browser tabs' Accept-Language, from that list. A Velopack update
 * leaves empty directories out, so after one the app had only English. Each one
 * gets an empty strings file to keep it.
 */
export function appLocalizationsHook(productName: string): HookFunction {
  return (buildPath, _electronVersion, platform, _arch, callback) => {
    if (platform !== "darwin") {
      callback();
      return;
    }
    try {
      keepAppLocalizations(
        join(buildPath, `${productName}.app`, "Contents", "Resources")
      );
      callback();
    } catch (error) {
      callback(error instanceof Error ? error : new Error(String(error)));
    }
  };
}

export function keepAppLocalizations(resourcesDir: string) {
  for (const entry of readdirSync(resourcesDir, { withFileTypes: true })) {
    if (!entry.isDirectory() || !entry.name.endsWith(".lproj")) continue;
    const dir = join(resourcesDir, entry.name);
    if (readdirSync(dir).length === 0)
      writeFileSync(join(dir, placeholderName), placeholder);
  }
}
