import { execFileSync, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  chmodSync,
  copyFileSync,
  renameSync,
  cpSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { arch, platform } from "node:process";
import { join, resolve } from "node:path";
import { getCommaReleaseConfig } from "../src/release-config";
import {
  computerUseAppName,
  computerUseDistAppPath,
  computerUseProductName,
  micCaptureBinaryName,
  micCaptureHostDistPath,
  nativeDistRoot,
  cableScannerAddonDistPath,
  fileApplicationsAddonDistPath,
  fontFamiliesAddonDistPath,
  keychainPasswordAddonDistPath,
  notchBinaryName,
  notchHostDistPath,
  notificationAuthorizationAddonDistPath,
  platformNativeDistDir,
  quickChatBinaryName,
  quickChatHostDistPath,
  stationDistDir,
  stationLauncherDistPath,
  stationMeshAddonDistPath,
  sharedMacOSNativeDistDir,
  menuBarAppName,
  menuBarHostBundleId,
  menuBarHostDistAppPath,
  sleepGuardAddonDistPath,
  sleepGuardBinaryName,
  sleepGuardDistPath,
  synchBinaryName,
  synchBinaryPath,
} from "./native-paths";
import {
  NativeInstallCache,
  copyNativeFile,
  snapshotPaths,
} from "./native-build-cache";
import { buildNativeAddon } from "./native-addon-build";
import { fetchOpenDropKit } from "./opendropkit-release";
import {
  synchControlProtocol,
  synchReleaseArchive,
  synchReleaseBaseUrl,
  synchReleaseTag,
} from "./synch-release";

const incremental =
  process.argv.includes("--incremental") && !process.argv.includes("--force");
const configuration = process.env.NODE_ENV === "production" ? "release" : "debug";
const appDir = resolve(import.meta.dirname, "..");
const repoRoot = resolve(appDir, "../../..");
const releaseConfig = getCommaReleaseConfig();
const notchPackageDir = resolve(appDir, "native/macos/NotchHost");
const micCapturePackageDir = resolve(appDir, "native/macos/MicCaptureHost");
const quickChatPackageDir = resolve(appDir, "native/macos/QuickChatHost");
const sleepGuardDir = resolve(appDir, "native/macos/SleepGuard");
const sleepGuardOutput = sleepGuardDistPath(appDir);
const sleepGuardAddonOutput = sleepGuardAddonDistPath(appDir);
const menuBarProjectDir = resolve(appDir, "native/macos/MenuBarHost");
const notificationAuthorizationAddonDir = resolve(
  appDir,
  "native/macos/NotificationAuthorization"
);
const fileApplicationsAddonDir = resolve(appDir, "native/macos/FileApplications");
const fileApplicationsOutput = fileApplicationsAddonDistPath(appDir);
const fileApplicationsOnly = process.argv.includes("--file-applications-only");
const fontFamiliesAddonDir = resolve(appDir, "native/macos/FontFamilies");
const fontFamiliesOutput = fontFamiliesAddonDistPath(appDir);
const fontFamiliesOnly = process.argv.includes("--font-families-only");
const keychainPasswordAddonDir = resolve(appDir, "native/macos/KeychainPassword");
const keychainPasswordOutput = keychainPasswordAddonDistPath(appDir);
const keychainPasswordOnly = process.argv.includes("--keychain-password-only");
const cableScannerAddonDir = resolve(appDir, "native/macos/CableScanner");
const cableScannerOutput = cableScannerAddonDistPath(appDir);
const cableScannerOnly = process.argv.includes("--cable-scanner-only");
const notificationAuthorizationOnly = process.argv.includes(
  "--notification-authorization-only"
);
const nodeGypPath = resolve(repoRoot, "node_modules/.bin/node-gyp");
/** The Computer Use helper's sources (they move beside the station once the Go connector goes). */
const computerUseSourceDir = resolve(repoRoot, "systems/connector/salix-connect");
const computerUsePackageScript = resolve(
  computerUseSourceDir,
  "scripts/package-computer-use-helper.sh"
);
const platformOutputDir = platformNativeDistDir(appDir);
const stationBundleScript = resolve(repoRoot, "systems/station/scripts/bundle.sh");
const stationNativeScript = resolve(repoRoot, "systems/station/scripts/native.ts");
const stationMeshAddon = stationMeshAddonDistPath(appDir);
const stationOutput = stationDistDir(appDir);
const stationLauncher = stationLauncherDistPath(appDir, platform);
/** The platforms the station is released for (bundle.sh). */
const stationPlatform = (
  {
    "darwin-arm64": "darwin-arm64",
    "linux-x64": "linux-x64",
    "linux-arm64": "linux-arm64",
    "win32-x64": "win32-x64",
  } as Record<string, string>
)[`${platform}-${arch}`];
const computerUseAppPath = computerUseDistAppPath(appDir);
const outputDir = sharedMacOSNativeDistDir(appDir);
const notchHostOutput = notchHostDistPath(appDir);
const micCaptureHostOutput = micCaptureHostDistPath(appDir);
const quickChatHostOutput = quickChatHostDistPath(appDir);
const menuBarHostOutput = menuBarHostDistAppPath(appDir);
const notificationAuthorizationOutput = notificationAuthorizationAddonDistPath(appDir);
const menuBarOnly = process.argv.includes("--menu-bar-only");
/** Fetch only the synchronicity daemon: no Go, Swift or Xcode needed. */
const synchOnly = process.argv.includes("--synch-only");
const airDropOnly = process.argv.includes("--airdrop-only");
async function buildAirDrop() {
  await fetchOpenDropKit({
    appDir,
    platform,
    arch,
    binaryOverride: process.env.COMMA_OPENDROPKIT_BINARY,
    token: process.env.OPENDROPKIT_RELEASE_TOKEN,
    incremental,
    // A CI host keeps pinned downloads across jobs (COMMA_TOOL_CACHE).
    downloadCache: process.env.COMMA_TOOL_CACHE
      ? join(process.env.COMMA_TOOL_CACHE, "opendropkit")
      : undefined,
  });
}

function installCache(name: string, inputs: unknown, outputs: string[]) {
  return new NativeInstallCache(
    resolve(appDir, ".native-cache/installs", `${name}.json`),
    incremental,
    { platform, arch, configuration, inputs },
    outputs
  );
}

function run(command: string, args: string[], cwd: string) {
  const result = spawnSync(command, args, {
    cwd,
    stdio: "inherit",
    shell: false,
  });

  if (result.error) {
    throw result.error;
  }

  if (result.status !== 0) {
    throw new Error(`${command} ${args.join(" ")} exited with ${result.status}`);
  }
}

function assertFile(path: string, label: string) {
  if (!existsSync(path) || !statSync(path).isFile()) {
    throw new Error(`${label} was not created at ${path}`);
  }
}

function assertDirectory(path: string, label: string) {
  if (!existsSync(path) || !statSync(path).isDirectory()) {
    throw new Error(`${label} was not created at ${path}`);
  }
}

function buildMicCaptureHost() {
  run("swift", ["build", "-c", configuration], micCapturePackageDir);
  mkdirSync(outputDir, { recursive: true });
  copyNativeFile(
    resolve(micCapturePackageDir, ".build", configuration, micCaptureBinaryName),
    micCaptureHostOutput,
    incremental
  );
  assertFile(micCaptureHostOutput, "Native MicCaptureHost");

  console.log(`Native MicCaptureHost built (${configuration}).`);
}

/** The privileged lid-sleep daemon and the addon Main talks to it through. */
function buildSleepGuard() {
  run("swift", ["build", "-c", configuration], sleepGuardDir);
  mkdirSync(outputDir, { recursive: true });
  copyNativeFile(
    resolve(sleepGuardDir, ".build", configuration, sleepGuardBinaryName),
    sleepGuardOutput,
    incremental
  );
  assertFile(sleepGuardOutput, "Native CommaSleepGuard");
  buildNodeAddon({
    addonDir: sleepGuardDir,
    label: "Native sleep guard addon",
    output: sleepGuardAddonOutput,
    targetName: "comma_sleep_guard",
  });
}

/**
 * Quick Chat. It targets macOS 26 (SpeechAnalyzer), so it needs the macOS 26
 * SDK (Xcode 26, as NotchKit's Liquid Glass already does); Main starts it only
 * on macOS 26 and later.
 */
function buildQuickChatHost() {
  run("swift", ["build", "-c", configuration], quickChatPackageDir);
  mkdirSync(outputDir, { recursive: true });
  copyNativeFile(
    resolve(quickChatPackageDir, ".build", configuration, quickChatBinaryName),
    quickChatHostOutput,
    incremental
  );
  assertFile(quickChatHostOutput, "Native QuickChatHost");

  console.log(`Native QuickChatHost built (${configuration}).`);
}

function buildNotchHost() {
  run("swift", ["build", "-c", configuration], notchPackageDir);
  mkdirSync(outputDir, { recursive: true });
  copyNativeFile(
    resolve(notchPackageDir, ".build", configuration, notchBinaryName),
    notchHostOutput,
    incremental
  );
  assertFile(notchHostOutput, "Native NotchHost");

  console.log(`Native NotchHost built (${configuration}).`);
}

function buildMenuBarHost() {
  // Builds with Side Chat left these here; an incremental build would package
  // them unsigned.
  for (const retired of ["CommaSideChatHost.app", "comma-side-chat-backdrop.node"]) {
    rmSync(resolve(outputDir, retired), { force: true, recursive: true });
  }
  const xcodeConfiguration = configuration === "release" ? "Release" : "Debug";
  const derivedDataPath = resolve(menuBarProjectDir, ".derived");
  run(
    "xcodebuild",
    [
      "-project",
      "Comma.xcodeproj",
      "-scheme",
      "Comma",
      "-configuration",
      xcodeConfiguration,
      "-derivedDataPath",
      derivedDataPath,
      "CODE_SIGNING_ALLOWED=NO",
      `PRODUCT_BUNDLE_IDENTIFIER=${menuBarHostBundleId(releaseConfig.appBundleId)}`,
      "build",
    ],
    menuBarProjectDir
  );

  const builtApp = resolve(
    derivedDataPath,
    "Build/Products",
    xcodeConfiguration,
    `${menuBarAppName}.app`
  );
  const cache = installCache(
    "menu-bar",
    {
      source: snapshotPaths([builtApp]),
      signingIdentity: process.env.COMMA_MACOS_DEV_SIGN_IDENTITY ?? "-",
    },
    [menuBarHostOutput]
  );
  if (cache.reuse()) {
    console.log("Native menu-bar helper unchanged.");
    return;
  }
  rmSync(menuBarHostOutput, { force: true, recursive: true });
  cpSync(builtApp, menuBarHostOutput, { dereference: true, recursive: true });
  assertDirectory(menuBarHostOutput, `Native ${menuBarAppName}.app`);
  assertFile(
    resolve(menuBarHostOutput, "Contents/MacOS", menuBarAppName),
    `Native ${menuBarAppName}`
  );

  // xcodebuild intentionally skips signing so CI does not require an Apple
  // identity, but a copied .app with only the linker's executable signature is
  // not a valid nested bundle (`codesign --verify --deep --strict` rejects it).
  // Seal the complete helper bundle now. Release packaging replaces this
  // development signature with the configured hardened-runtime identity.
  run(
    "codesign",
    [
      "--force",
      "--deep",
      "--sign",
      process.env.COMMA_MACOS_DEV_SIGN_IDENTITY ?? "-",
      menuBarHostOutput,
    ],
    appDir
  );
  run(
    "codesign",
    ["--verify", "--deep", "--strict", "--verbose=2", menuBarHostOutput],
    appDir
  );

  cache.save();
  console.log(`Native ${menuBarAppName}.app built (${xcodeConfiguration}).`);
}

function buildNodeAddon(options: {
  addonDir: string;
  label: string;
  output: string;
  targetName: string;
}) {
  buildNativeAddon({ ...options, nodeGypPath, configuration, incremental });
}

function buildFileApplicationsAddon() {
  buildNodeAddon({
    addonDir: fileApplicationsAddonDir,
    label: "Native file applications addon",
    output: fileApplicationsOutput,
    targetName: "comma_file_applications",
  });
}

function buildFontFamiliesAddon() {
  buildNodeAddon({
    addonDir: fontFamiliesAddonDir,
    label: "Native font families addon",
    output: fontFamiliesOutput,
    targetName: "comma_font_families",
  });
}

function buildKeychainPasswordAddon() {
  buildNodeAddon({
    addonDir: keychainPasswordAddonDir,
    label: "Native keychain password addon",
    output: keychainPasswordOutput,
    targetName: "comma_keychain_password",
  });
}

function buildCableScannerAddon() {
  buildNodeAddon({
    addonDir: cableScannerAddonDir,
    label: "Native caBLE scanner addon",
    output: cableScannerOutput,
    targetName: "comma_cable_scanner",
  });
}

function buildNotificationAuthorizationAddon() {
  buildNodeAddon({
    addonDir: notificationAuthorizationAddonDir,
    label: "Native notification authorization addon",
    output: notificationAuthorizationOutput,
    targetName: "comma_notification_authorization",
  });
}

function buildComputerUseHelper() {
  let cache: NativeInstallCache | undefined;
  if (incremental) {
    run(
      "bash",
      [
        computerUsePackageScript,
        "--configuration",
        configuration,
        "--app-path",
        computerUseAppPath,
        "--build-only",
      ],
      repoRoot
    );
    const packageDir = resolve(computerUseSourceDir, "native/macos/ComputerUseHost");
    const binDir = execFileSync(
      "swift",
      [
        "build",
        "--package-path",
        packageDir,
        "-c",
        configuration,
        "--product",
        computerUseProductName,
        "--show-bin-path",
      ],
      { encoding: "utf8" }
    ).trim();
    cache = installCache(
      "computer-use",
      {
        source: snapshotPaths([
          computerUsePackageScript,
          resolve(binDir, computerUseProductName),
          ...[
            "ComputerUseHost_CommaComputerUseDaemon.bundle",
            "ComputerUseHost_CUShared.bundle",
            "ComputerUseHost_CUForeground.bundle",
            "PermissionFlow_PermissionFlow.bundle",
          ].map((name) => resolve(binDir, name)),
          resolve(
            packageDir,
            "Sources/CommaComputerUseDaemon/Resources/panel-logo.png"
          ),
        ]),
        bundleId: releaseConfig.appBundleId,
        displayName: releaseConfig.productName,
        signingIdentity: process.env.COMMA_MACOS_DEV_SIGN_IDENTITY ?? "-",
      },
      [computerUseAppPath]
    );
    if (cache.reuse()) {
      console.log("Native Computer Use host unchanged.");
      return;
    }
  }
  run(
    "bash",
    [
      computerUsePackageScript,
      "--configuration",
      configuration,
      "--app-path",
      computerUseAppPath,
      "--bundle-id",
      `${releaseConfig.appBundleId}.computer-use`,
      "--display-name",
      `${releaseConfig.productName} Computer Use`,
      "--sign-identity",
      process.env.COMMA_MACOS_DEV_SIGN_IDENTITY ?? "-",
      "--stop-running",
      ...(incremental ? ["--package-only"] : []),
    ],
    repoRoot
  );
  assertDirectory(computerUseAppPath, `Native ${computerUseAppName}.app`);
  assertFile(
    resolve(computerUseAppPath, "Contents/MacOS", computerUseProductName),
    `Native ${computerUseProductName}`
  );

  cache?.save();
  console.log(`Native ${computerUseAppName}.app built (${configuration}).`);
}

const synchBinary = synchBinaryPath(appDir);
// A CI host keeps pinned downloads across jobs (COMMA_TOOL_CACHE); the pinned
// SHA-256 checks the archive either way.
const synchArchiveCacheDir = process.env.COMMA_TOOL_CACHE
  ? join(process.env.COMMA_TOOL_CACHE, "synchronicity")
  : resolve(appDir, ".native-cache", "synchronicity");
const synchControlProto = resolve(
  appDir,
  "src/main/modules/synchronicity/control.proto"
);

function sha256Of(path: string) {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

/**
 * The schema's hash is of its text, not of the checkout: git on Windows
 * checks text files out with CRLF, and the pin must name the same schema on
 * every platform.
 */
function sha256OfText(path: string) {
  return createHash("sha256")
    .update(readFileSync(path, "utf8").replaceAll("\r\n", "\n"))
    .digest("hex");
}

function verifySynchControlProtocol() {
  if (synchControlProtocol.releaseTag !== synchReleaseTag) {
    throw new Error(
      `Synch control schema targets ${synchControlProtocol.releaseTag}, but the bundled binary targets ${synchReleaseTag}.`
    );
  }
  const actual = sha256OfText(synchControlProto);
  if (actual !== synchControlProtocol.sha256) {
    throw new Error(
      `Vendored Synch control.proto does not match the pinned schema (expected ${synchControlProtocol.sha256}, got ${actual}).`
    );
  }
}

/**
 * Puts a binary at the bundled path by replacing the file, never by writing
 * into it: macOS remembers a signed Mach-O by its inode, and one overwritten
 * in place is killed at exec until it is replaced.
 */
function placeSynchBinary(source: string) {
  const staged = `${synchBinary}.tmp`;
  copyFileSync(source, staged);
  chmodSync(staged, 0o755);
  renameSync(staged, synchBinary);
}

/** The first `synch` binary anywhere under an extracted release archive. */
function findExtractedSynch(root: string): string | undefined {
  for (const entry of readdirSync(root, { withFileTypes: true })) {
    const path = join(root, entry.name);
    if (entry.isDirectory()) {
      const found = findExtractedSynch(path);
      if (found) return found;
    } else if (entry.name === synchBinaryName(platform)) {
      return path;
    }
  }
  return undefined;
}

/**
 * Ships the synchronicity node daemon. It is fetched, not built: the source
 * tree is not expected to be present, and a release archive is checked
 * against the SHA-256 pinned in `synch-release.ts` before anything in it is
 * trusted. The archive is cached beside the app so a rebuild is offline.
 *
 * `COMMA_SYNCH_BINARY` points at a locally built `synch` instead, for working
 * against an unreleased daemon.
 */
async function fetchSynch() {
  mkdirSync(platformOutputDir, { recursive: true });

  const override = process.env.COMMA_SYNCH_BINARY?.trim();
  const cache = installCache(
    "synch",
    override
      ? { override: snapshotPaths([override]) }
      : { tag: synchReleaseTag, ...synchReleaseArchive(platform, arch) },
    [synchBinary]
  );
  if (cache.reuse()) return;
  if (override) {
    assertFile(override, "COMMA_SYNCH_BINARY");
    placeSynchBinary(override);
    cache.save();
    console.log(`synch copied from COMMA_SYNCH_BINARY (${override}).`);
    return;
  }

  const { archive, sha256 } = synchReleaseArchive(platform, arch);
  mkdirSync(synchArchiveCacheDir, { recursive: true });
  const cachedArchive = join(synchArchiveCacheDir, archive);

  if (!existsSync(cachedArchive) || sha256Of(cachedArchive) !== sha256) {
    const url = `${synchReleaseBaseUrl}/${archive}`;
    console.log(`Fetching ${url}`);
    const response = await fetch(url, { redirect: "follow" });
    if (!response.ok) {
      throw new Error(`Fetching ${url} failed: HTTP ${response.status}`);
    }
    // Another build may read the same cache: the archive appears whole or not at all.
    const staged = `${cachedArchive}.${process.pid}.tmp`;
    writeFileSync(staged, Buffer.from(await response.arrayBuffer()));
    renameSync(staged, cachedArchive);
  }

  const actual = sha256Of(cachedArchive);
  if (actual !== sha256) {
    rmSync(cachedArchive, { force: true });
    throw new Error(
      `${archive} does not match its pinned SHA-256 (expected ${sha256}, got ${actual}).`
    );
  }

  const extractDir = mkdtempSync(join(tmpdir(), "comma-synch-"));
  try {
    // bsdtar reads both the .tar.gz and the Windows .zip. On Windows that is System32's: the tar a Git Bash puts first
    // on PATH is GNU's, which reads `C:` as a host to connect to.
    const tar =
      platform === "win32"
        ? join(process.env.SystemRoot ?? "C:\\Windows", "System32", "tar.exe")
        : "tar";
    run(tar, ["-xf", cachedArchive, "-C", extractDir], appDir);
    const extracted = findExtractedSynch(extractDir);
    if (!extracted) {
      throw new Error(`${archive} does not contain ${synchBinaryName(platform)}.`);
    }
    placeSynchBinary(extracted);
  } finally {
    rmSync(extractDir, { force: true, recursive: true });
  }

  assertFile(synchBinary, `synch ${platform}/${arch} binary`);
  cache.save();
  console.log(`synch ${synchReleaseTag} ready for ${platform}/${arch}.`);
}

function verifyNativeOutputs() {
  if (stationPlatform)
    assertFile(stationLauncher, `station ${platform}/${arch} launcher`);
  assertFile(synchBinary, `synch ${platform}/${arch} binary`);
  if (platform !== "darwin") {
    return;
  }

  assertFile(notchHostOutput, "Native NotchHost");
  assertFile(micCaptureHostOutput, "Native MicCaptureHost");
  assertFile(quickChatHostOutput, "Native QuickChatHost");
  assertFile(sleepGuardOutput, "Native CommaSleepGuard");
  assertFile(sleepGuardAddonOutput, "Native sleep guard addon");
  assertFile(
    notificationAuthorizationOutput,
    "Native notification authorization addon"
  );
  assertFile(fontFamiliesOutput, "Native font families addon");
  assertFile(keychainPasswordOutput, "Native keychain password addon");
  assertFile(cableScannerOutput, "Native caBLE scanner addon");
  assertDirectory(menuBarHostOutput, `Native ${menuBarAppName}.app`);
  assertDirectory(computerUseAppPath, `Native ${computerUseAppName}.app`);
  assertFile(
    resolve(computerUseAppPath, "Contents/MacOS", computerUseProductName),
    `Native ${computerUseProductName}`
  );
}

/** The Comma station: prebuilt native parts and the TypeScript bundle (systems/station/scripts/bundle.sh). */
function bundleStation() {
  if (!stationPlatform) {
    console.log(
      `No station is released for ${platform}/${arch}; the app carries none.`
    );
    return;
  }
  run("sh", [stationBundleScript, stationOutput, stationPlatform], repoRoot);
  assertFile(stationLauncher, `station ${platform}/${arch} launcher`);
  console.log(`station bundled for ${platform}/${arch}.`);
}

/**
 * The station's mesh addon alone, where the station has it, for a build without the native parts: the core's endpoint
 * to stations is on it. Only a prebuilt one (native.ts `fetch` compiles nothing); without one the build reaches no
 * station.
 */
function fetchStationMeshAddon() {
  if (!stationPlatform) return;
  let dir: string;
  try {
    dir = execFileSync(
      process.execPath,
      [stationNativeScript, "fetch", "mesh", stationPlatform],
      { cwd: repoRoot, encoding: "utf8", stdio: ["ignore", "pipe", "inherit"] }
    ).trim();
  } catch {
    console.warn(
      `The station's mesh addon for ${stationPlatform} is not prebuilt; this build reaches no station.`
    );
    return;
  }
  mkdirSync(resolve(stationMeshAddon, ".."), { recursive: true });
  copyFileSync(join(dir, "mesh.node"), stationMeshAddon);
  console.log(`station mesh addon fetched for ${stationPlatform}.`);
}

async function buildNative() {
  if (airDropOnly) {
    await buildAirDrop();
    return;
  }
  verifySynchControlProtocol();
  if (synchOnly) {
    await fetchSynch();
    return;
  }

  if (process.env.COMMA_SKIP_NATIVE_BUILD === "1") {
    mkdirSync(nativeDistRoot(appDir), { recursive: true });
    fetchStationMeshAddon();
    console.log("Skipping native build because COMMA_SKIP_NATIVE_BUILD=1.");
    return;
  }

  if (fileApplicationsOnly) {
    if (platform !== "darwin") {
      throw new Error("The file applications addon can only be built on macOS.");
    }
    buildFileApplicationsAddon();
    return;
  }

  if (fontFamiliesOnly) {
    if (platform !== "darwin") {
      throw new Error("The font families addon can only be built on macOS.");
    }
    buildFontFamiliesAddon();
    return;
  }

  if (keychainPasswordOnly) {
    if (platform !== "darwin") {
      throw new Error("The keychain password addon can only be built on macOS.");
    }
    buildKeychainPasswordAddon();
    return;
  }

  if (cableScannerOnly) {
    if (platform !== "darwin") {
      throw new Error("The caBLE scanner addon can only be built on macOS.");
    }
    buildCableScannerAddon();
    return;
  }

  if (notificationAuthorizationOnly) {
    if (platform !== "darwin") {
      throw new Error(
        "The notification authorization addon can only be built on macOS."
      );
    }
    buildNotificationAuthorizationAddon();
    return;
  }

  if (menuBarOnly) {
    if (platform !== "darwin") {
      throw new Error("The menu-bar helper can only be built on macOS.");
    }
    mkdirSync(outputDir, { recursive: true });
    buildMenuBarHost();
    return;
  }

  if (!incremental) rmSync(nativeDistRoot(appDir), { force: true, recursive: true });
  mkdirSync(platformOutputDir, { recursive: true });
  bundleStation();
  await fetchSynch();

  if (platform !== "darwin") {
    console.log("Skipping macOS native build on non-macOS host.");
    return;
  }

  buildNotchHost();
  buildMicCaptureHost();
  buildQuickChatHost();
  buildSleepGuard();
  await buildAirDrop();
  buildNotificationAuthorizationAddon();
  buildFileApplicationsAddon();
  buildFontFamiliesAddon();
  buildKeychainPasswordAddon();
  buildCableScannerAddon();
  buildMenuBarHost();
  buildComputerUseHelper();
  verifyNativeOutputs();
}

// No top-level await: tsx runs this script as CommonJS.
buildNative().catch((error: unknown) => {
  console.error(error);
  process.exit(1);
});
