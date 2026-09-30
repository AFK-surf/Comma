import type { ForgeConfig } from "@electron-forge/shared-types";
import { MakerDeb } from "@electron-forge/maker-deb";
import { MakerDMG } from "@electron-forge/maker-dmg";
import { MakerRpm } from "@electron-forge/maker-rpm";
import { MakerZIP } from "@electron-forge/maker-zip";
import { AutoUnpackNativesPlugin } from "@electron-forge/plugin-auto-unpack-natives";
import { FusesPlugin } from "@electron-forge/plugin-fuses";
import { VitePlugin } from "@electron-forge/plugin-vite";
import { FuseV1Options, FuseVersion } from "@electron/fuses";
import { cpSync, existsSync, mkdirSync, readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join, resolve } from "node:path";
import {
  notificationSoundPath,
  prepareDevElectronBundle,
} from "./scripts/dev-electron-bundle";
import { ensureDevNativeAddons } from "./scripts/dev-native-addons";
import { electronDownloadCache } from "./scripts/electron-download-cache";
import { getCommaReleaseConfig } from "./src/release-config";

const require = createRequire(import.meta.url);
const releaseConfig = getCommaReleaseConfig();
const electronCacheRoot = electronDownloadCache();
if (electronCacheRoot) {
  console.info(`Electron persistent download cache: ${electronCacheRoot}`);
}
const forgeOutDir =
  process.env.COMMA_FORGE_OUT_DIR ?? resolve(import.meta.dirname, "out");
const packagedRuntimeDependencies = ["velopack", "@neon-rs/load"];
/**
 * `@recappi/sdk` resolves its prebuilt binary from a per-triple sibling
 * package, so the packaged app needs both the loader and the one binary that
 * matches the target. Platforms the SDK does not publish for ship without it
 * and degrade to an unavailable capability at runtime.
 */
const recappiPlatformPackages: Record<string, string> = {
  "darwin/arm64": "@recappi/sdk-darwin-arm64",
  "darwin/x64": "@recappi/sdk-darwin-x64",
  "linux/x64": "@recappi/sdk-linux-x64-gnu",
  "win32/arm64": "@recappi/sdk-win32-arm64-msvc",
  "win32/ia32": "@recappi/sdk-win32-ia32-msvc",
  "win32/x64": "@recappi/sdk-win32-x64-msvc",
};

function audioCaptureRuntimeDependencies(platform: string, arch: string) {
  const platformPackage = recappiPlatformPackages[`${platform}/${arch}`];
  return platformPackage ? ["@recappi/sdk", platformPackage] : [];
}

/**
 * Locates an installed package's root directory. A package with an `exports`
 * map need not expose its own package.json, so the direct lookup is only the
 * fast path; otherwise the resolved entry point is walked up to the manifest
 * that actually names the package.
 */
function packageDirectory(dependency: string) {
  try {
    return dirname(require.resolve(`${dependency}/package.json`));
  } catch {
    let current = dirname(require.resolve(dependency));
    while (true) {
      const manifest = join(current, "package.json");
      if (
        existsSync(manifest) &&
        JSON.parse(readFileSync(manifest, "utf8")).name === dependency
      ) {
        return current;
      }
      const parent = dirname(current);
      if (parent === current) {
        throw new Error(`Could not locate the ${dependency} package root.`);
      }
      current = parent;
    }
  }
}
const channelIconBasePath = resolve(
  import.meta.dirname,
  "build",
  "icons",
  releaseConfig.flavor,
  "icon"
);
const channelIconPngPath = `${channelIconBasePath}.png`;
const statusTrayIconPaths = [
  resolve(import.meta.dirname, "build/icons/tray/CommaTemplate.png"),
  resolve(import.meta.dirname, "build/icons/tray/CommaTemplate@2x.png"),
];

function toError(error: unknown) {
  return error instanceof Error ? error : new Error(String(error));
}

const config: ForgeConfig = {
  outDir: forgeOutDir,
  hooks: {
    // A from-source run must not execute as node_modules' `com.github.Electron`
    // (see scripts/dev-electron-bundle.ts). Forge reads the override when it
    // locates the executable, which comes after this hook.
    preStart: async () => {
      if (process.platform !== "darwin") return;
      process.env.ELECTRON_OVERRIDE_DIST_PATH = prepareDevElectronBundle().distDir;
      // A checkout that never ran build:native would otherwise start without
      // the Node-API addons and degrade "Open in" to "Could not load apps".
      ensureDevNativeAddons();
    },
  },
  packagerConfig: {
    ...(electronCacheRoot ? { download: { cacheRoot: electronCacheRoot } } : {}),
    name: releaseConfig.productName,
    executableName: releaseConfig.executableName,
    ...(process.env.COMMA_ELECTRON_ZIP_DIR
      ? { electronZipDir: process.env.COMMA_ELECTRON_ZIP_DIR }
      : {}),
    appBundleId: releaseConfig.appBundleId,
    extendInfo: {
      CFBundleDisplayName: releaseConfig.productName,
      // macOS 14.4+ gates Core Audio process taps on this usage string; without
      // it the tap fails closed instead of prompting.
      NSCameraUsageDescription:
        "Websites you allow can use your camera for video meetings.",
      NSMicrophoneUsageDescription:
        "Comma uses your microphone for recording and for websites you allow, including meeting calls.",
      NSAudioCaptureUsageDescription:
        "Comma records meeting audio playing on this Mac so it can transcribe and summarize it.",
      NSScreenCaptureUsageDescription:
        "Comma lists the apps playing audio so a recording can be scoped to one of them.",
    },
    icon: channelIconBasePath,
    protocols: [
      {
        name: releaseConfig.productName,
        schemes: [releaseConfig.urlScheme],
      },
    ],
    asar: {
      unpack:
        "{dist/native/**,node_modules/velopack/lib/native/**,node_modules/@recappi/**}",
    },
    extraResource: [
      "dist/native",
      channelIconPngPath,
      notificationSoundPath,
      ...statusTrayIconPaths,
    ],
    afterCopy: [
      (buildPath, _electronVersion, platform, arch, callback) => {
        try {
          const nodeModulesDir = join(buildPath, "node_modules");
          mkdirSync(nodeModulesDir, { recursive: true });

          for (const dependency of [
            ...packagedRuntimeDependencies,
            ...audioCaptureRuntimeDependencies(platform, arch),
          ]) {
            const source = packageDirectory(dependency);
            const destination = join(nodeModulesDir, ...dependency.split("/"));

            cpSync(source, destination, {
              dereference: true,
              force: true,
              recursive: true,
            });
          }

          callback();
        } catch (error) {
          callback(toError(error));
        }
      },
    ],
  },
  rebuildConfig: {},
  makers: [
    new MakerZIP({}, ["darwin"]),
    new MakerDMG({}),
    new MakerRpm({}),
    new MakerDeb({}),
  ],
  plugins: [
    new AutoUnpackNativesPlugin({}),
    new VitePlugin({
      build: [
        {
          entry: "src/main.ts",
          config: "vite.main.config.ts",
          target: "main",
        },
        {
          entry: "src/preload.ts",
          config: "vite.preload.config.ts",
          target: "main",
        },
        {
          entry: "src/utility.ts",
          config: "vite.utility.config.ts",
          target: "main",
        },
      ],
      renderer: [
        {
          name: "main_window",
          config: "vite.renderer.config.ts",
        },
      ],
    }),
    // Harden the packaged app by flipping Electron fuses at package time.
    new FusesPlugin({
      version: FuseVersion.V1,
      [FuseV1Options.RunAsNode]: false,
      [FuseV1Options.EnableCookieEncryption]: true,
      [FuseV1Options.EnableNodeOptionsEnvironmentVariable]: false,
      [FuseV1Options.EnableNodeCliInspectArguments]: false,
      [FuseV1Options.EnableEmbeddedAsarIntegrityValidation]: true,
      [FuseV1Options.OnlyLoadAppFromAsar]: true,
      // Packaged renderer is served from the privileged assets:// scheme, not file://.
      [FuseV1Options.GrantFileProtocolExtraPrivileges]: false,
    }),
  ],
};

export default config;
