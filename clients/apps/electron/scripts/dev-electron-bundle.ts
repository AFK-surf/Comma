import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { createRequire } from "node:module";
import { basename, dirname, resolve } from "node:path";
import { getCommaReleaseConfig } from "../src/release-config";

/**
 * The bundle a from-source run of Comma executes as.
 *
 * `electron-forge start` would run `node_modules/electron/dist/Electron.app`,
 * whose bundle id `com.github.Electron` is shared with every other checkout on
 * the machine and every other Electron project run from source. macOS keys
 * per-app state on the bundle — notification authorization first of all — and
 * refuses a bundle it cannot pin down: the authorization request comes back
 * undecided without a prompt and every banner is refused. So each checkout
 * gets its own: an APFS clone of that Electron.app carrying a checkout-specific
 * bundle id, Comma's name, icon and notification sound, re-sealed ad hoc and
 * registered with LaunchServices. Forge's preStart hook points
 * `ELECTRON_OVERRIDE_DIST_PATH` at it, which `electron/index.js` honours when
 * Forge locates the executable.
 */
export interface DevElectronBundle {
  appPath: string;
  bundleId: string;
  displayName: string;
  /** What `ELECTRON_OVERRIDE_DIST_PATH` takes: the directory holding Electron.app. */
  distDir: string;
  executablePath: string;
}

const require = createRequire(import.meta.url);
const appRoot = resolve(import.meta.dirname, "..");
// macOS plays a banner's sound by file name from the app bundle's Resources, so
// the Router notification sound ships there beside the icons, in the packaged
// app and in this bundle alike. Without it the banner falls back to the system
// default sound.
export const notificationSoundPath = resolve(
  appRoot,
  "../../packages/app/src/components/notifications/assets/notification.wav"
);
const launchServices =
  "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister";

function run(command: string, args: string[]) {
  const result = spawnSync(command, args, { stdio: "inherit", shell: false });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error(`${command} ${args.join(" ")} exited with ${result.status}`);
  }
}

function plistString(plistPath: string, key: string) {
  const result = spawnSync("plutil", ["-extract", key, "raw", "-o", "-", plistPath], {
    encoding: "utf8",
    shell: false,
  });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error(`plutil could not read ${key} from ${plistPath}`);
  }
  return result.stdout.trim();
}

export function prepareDevElectronBundle(): DevElectronBundle {
  const releaseConfig = getCommaReleaseConfig();
  const electronPackageDir = dirname(require.resolve("electron/package.json"));
  const electronVersion = (
    JSON.parse(readFileSync(resolve(electronPackageDir, "package.json"), "utf8")) as {
      version: string;
    }
  ).version;
  const sourceApp = resolve(electronPackageDir, "dist/Electron.app");
  // Not under .vite: the Vite plugin empties that directory on every start.
  const distDir = resolve(appRoot, ".dev-electron", releaseConfig.flavor);
  const appPath = resolve(distDir, "Electron.app");
  const stampPath = resolve(distDir, "bundle.json");

  // The checkout path is the identity: two worktrees sharing a bundle id would
  // hand the OS the same unpinnable bundle it already refuses.
  const checkout = createHash("sha256").update(appRoot).digest("hex").slice(0, 8);
  const bundleId = `${releaseConfig.appBundleId}.source-${checkout}`;
  const displayName = `${releaseConfig.productName} (source)`;
  const notificationSound = createHash("sha256")
    .update(readFileSync(notificationSoundPath))
    .digest("hex");
  const stamp = JSON.stringify({
    bundleId,
    displayName,
    electronVersion,
    notificationSound,
    sourceApp,
  });
  const bundle: DevElectronBundle = {
    appPath,
    bundleId,
    displayName,
    distDir,
    executablePath: resolve(appPath, "Contents/MacOS/Electron"),
  };

  if (
    existsSync(bundle.executablePath) &&
    existsSync(stampPath) &&
    readFileSync(stampPath, "utf8") === stamp
  ) {
    return bundle;
  }

  // A LaunchServices record that outlives its bundle leaves the id pointing
  // at two paths, one of them gone, and the OS answers for that with `denied`.
  if (existsSync(appPath)) run(launchServices, ["-u", appPath]);
  rmSync(distDir, { force: true, recursive: true });
  mkdirSync(distDir, { recursive: true });
  // clonefile(2): the 270 MB bundle costs neither time nor disk on APFS.
  run("cp", ["-Rc", sourceApp, appPath]);

  const infoPlist = resolve(appPath, "Contents/Info.plist");
  for (const [key, value] of [
    ["CFBundleIdentifier", bundleId],
    ["CFBundleName", displayName],
    ["CFBundleDisplayName", displayName],
  ] as const) {
    run("plutil", ["-replace", key, "-string", value, infoPlist]);
  }
  copyFileSync(
    resolve(appRoot, "build/icons", releaseConfig.flavor, "icon.icns"),
    resolve(appPath, "Contents/Resources", plistString(infoPlist, "CFBundleIconFile"))
  );
  copyFileSync(
    notificationSoundPath,
    resolve(appPath, "Contents/Resources", basename(notificationSoundPath))
  );

  // Editing Info.plist breaks the prebuilt seal, and an unsealed bundle no
  // longer launches; re-seal the whole tree ad hoc, as the Side Chat host is.
  run("codesign", ["--force", "--deep", "--sign", "-", appPath]);
  run(launchServices, ["-f", appPath]);
  writeFileSync(stampPath, stamp);

  console.log(`Prepared ${displayName} for development at ${appPath} (${bundleId}).`);
  return bundle;
}
