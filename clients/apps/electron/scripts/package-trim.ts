import type { HookFunction } from "@electron/packager";
import { execFileSync } from "node:child_process";
import { existsSync, lstatSync, readdirSync, rmSync, symlinkSync } from "node:fs";
import { join } from "node:path";

/**
 * The Chromium locales the app keeps whole: the languages Comma itself speaks
 * (packages/i18n supportedLocales) and their regional siblings.
 */
export const keptChromiumLocales = ["en", "en_GB", "zh_CN", "zh_TW"];

/**
 * The velopack Node-API binary each target loads (velopack/lib/load.js). The
 * package carries all six; a target needs only its own.
 */
const velopackNativeByTarget: Record<string, string> = {
  "darwin/arm64": "velopack_nodeffi_osx.node",
  "darwin/x64": "velopack_nodeffi_osx.node",
  "linux/arm64": "velopack_nodeffi_linux_arm64_gnu.node",
  "linux/x64": "velopack_nodeffi_linux_x64_gnu.node",
  "win32/arm64": "velopack_nodeffi_win_arm64_msvc.node",
  "win32/ia32": "velopack_nodeffi_win_x86_msvc.node",
  "win32/x64": "velopack_nodeffi_win_x64_msvc.node",
};

/**
 * Leaves only the target's binary in a copied velopack package, and on macOS
 * only the target's slice of the universal one: the others are dead weight in
 * the app (17 MB of the 20 MB the package was).
 */
export function trimVelopackNatives(
  packageDir: string,
  platform: string,
  arch: string
) {
  const kept = velopackNativeByTarget[`${platform}/${arch}`];
  if (!kept) return;
  const nativeDir = join(packageDir, "lib", "native");
  for (const file of readdirSync(nativeDir)) {
    if (file !== kept) rmSync(join(nativeDir, file), { force: true });
  }
  if (platform === "darwin" && process.platform === "darwin") {
    const binary = join(nativeDir, kept);
    const slice = arch === "x64" ? "x86_64" : arch;
    execFileSync("lipo", [binary, "-thin", slice, "-output", binary]);
  }
}

/**
 * Electron Framework carries Chromium's strings in 55 languages (46 MB). The
 * ones Comma does not speak point at the English strings instead of going: a
 * missing `<lang>.lproj` would turn the app's locale, and with it the browser
 * tabs' Accept-Language, into en-US, and a missing `locale.pak` alone leaves
 * Chromium's own strings (form validation, the PDF viewer) empty. The gendered
 * variants (`de_FEMININE` …) are a few bytes each and stay.
 */
export function chromiumLocalesHook(productName: string): HookFunction {
  return (buildPath, _electronVersion, platform, _arch, callback) => {
    if (platform !== "darwin") {
      callback();
      return;
    }
    try {
      linkUnspokenChromiumLocales(
        join(
          buildPath,
          `${productName}.app`,
          "Contents",
          "Frameworks",
          "Electron Framework.framework",
          "Versions",
          "A",
          "Resources"
        )
      );
      callback();
    } catch (error) {
      callback(error instanceof Error ? error : new Error(String(error)));
    }
  };
}

export function linkUnspokenChromiumLocales(resourcesDir: string) {
  if (!existsSync(join(resourcesDir, "en.lproj", "locale.pak"))) {
    throw new Error(`No English Chromium locale in ${resourcesDir}.`);
  }
  for (const entry of readdirSync(resourcesDir)) {
    if (!entry.endsWith(".lproj")) continue;
    const locale = entry.slice(0, -".lproj".length);
    if (keptChromiumLocales.includes(locale)) continue;
    if (/_(FEMININE|MASCULINE|NEUTER)$/.test(locale)) continue;
    const pak = join(resourcesDir, entry, "locale.pak");
    if (!existsSync(pak) || lstatSync(pak).isSymbolicLink()) continue;
    rmSync(pak);
    symlinkSync(join("..", "en.lproj", "locale.pak"), pak);
  }
}
