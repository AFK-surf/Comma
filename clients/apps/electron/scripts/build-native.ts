import { spawnSync } from "node:child_process";
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
  fileApplicationsAddonDistPath,
  fontFamiliesAddonDistPath,
  notchBinaryName,
  notchHostDistPath,
  notificationAuthorizationAddonDistPath,
  platformNativeDistDir,
  salixConnectBinaryName,
  salixConnectBinaryPath,
  sharedMacOSNativeDistDir,
  sideChatAppName,
  sideChatBackdropAddonDistPath,
  sideChatHostBundleId,
  sideChatHostDistAppPath,
  sleepGuardAddonDistPath,
  sleepGuardBinaryName,
  sleepGuardDistPath,
  synchBinaryName,
  synchBinaryPath,
} from "./native-paths";
import { fetchOpenDropKit } from "./opendropkit-release";
import {
  synchControlProtocol,
  synchReleaseArchive,
  synchReleaseBaseUrl,
  synchReleaseTag,
} from "./synch-release";

const configuration = process.env.NODE_ENV === "production" ? "release" : "debug";
const appDir = resolve(import.meta.dirname, "..");
const repoRoot = resolve(appDir, "../../..");
const releaseConfig = getCommaReleaseConfig();
const notchPackageDir = resolve(appDir, "native/macos/NotchHost");
const micCapturePackageDir = resolve(appDir, "native/macos/MicCaptureHost");
const sleepGuardDir = resolve(appDir, "native/macos/SleepGuard");
const sleepGuardOutput = sleepGuardDistPath(appDir);
const sleepGuardAddonOutput = sleepGuardAddonDistPath(appDir);
const sideChatProjectDir = resolve(appDir, "native/macos/SideChatHost");
const sideChatBackdropAddonDir = resolve(appDir, "native/macos/SideChatBackdrop");
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
const notificationAuthorizationOnly = process.argv.includes(
  "--notification-authorization-only"
);
const nodeGypPath = resolve(repoRoot, "node_modules/.bin/node-gyp");
const salixConnectDir = resolve(repoRoot, "systems/connector/salix-connect");
const computerUsePackageScript = resolve(
  salixConnectDir,
  "scripts/package-computer-use-helper.sh"
);
const salixConnectOutputDir = platformNativeDistDir(appDir);
const salixConnectBinary = salixConnectBinaryPath(appDir);
const computerUseAppPath = computerUseDistAppPath(appDir);
const outputDir = sharedMacOSNativeDistDir(appDir);
const notchHostOutput = notchHostDistPath(appDir);
const micCaptureHostOutput = micCaptureHostDistPath(appDir);
const sideChatHostOutput = sideChatHostDistAppPath(appDir);
const sideChatBackdropOutput = sideChatBackdropAddonDistPath(appDir);
const notificationAuthorizationOutput = notificationAuthorizationAddonDistPath(appDir);
const sideChatOnly = process.argv.includes("--side-chat-only");
const sideChatBackdropOnly = process.argv.includes("--side-chat-backdrop-only");
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
  });
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
  copyFileSync(
    resolve(micCapturePackageDir, ".build", configuration, micCaptureBinaryName),
    micCaptureHostOutput
  );
  assertFile(micCaptureHostOutput, "Native MicCaptureHost");

  console.log(`Native MicCaptureHost built (${configuration}).`);
}

/** The privileged lid-sleep daemon and the addon Main talks to it through. */
function buildSleepGuard() {
  run("swift", ["build", "-c", configuration], sleepGuardDir);
  mkdirSync(outputDir, { recursive: true });
  copyFileSync(
    resolve(sleepGuardDir, ".build", configuration, sleepGuardBinaryName),
    sleepGuardOutput
  );
  assertFile(sleepGuardOutput, "Native CommaSleepGuard");
  buildNodeAddon({
    addonDir: sleepGuardDir,
    label: "Native sleep guard addon",
    output: sleepGuardAddonOutput,
    targetName: "comma_sleep_guard",
  });
}

function buildNotchHost() {
  run("swift", ["build", "-c", configuration], notchPackageDir);
  mkdirSync(outputDir, { recursive: true });
  copyFileSync(
    resolve(notchPackageDir, ".build", configuration, notchBinaryName),
    notchHostOutput
  );
  assertFile(notchHostOutput, "Native NotchHost");

  console.log(`Native NotchHost built (${configuration}).`);
}

function buildSideChatHost() {
  const xcodeConfiguration = configuration === "release" ? "Release" : "Debug";
  const derivedDataPath = resolve(sideChatProjectDir, ".derived");
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
      `PRODUCT_BUNDLE_IDENTIFIER=${sideChatHostBundleId(releaseConfig.appBundleId)}`,
      "build",
    ],
    sideChatProjectDir
  );

  rmSync(sideChatHostOutput, { force: true, recursive: true });
  cpSync(
    resolve(
      derivedDataPath,
      "Build/Products",
      xcodeConfiguration,
      `${sideChatAppName}.app`
    ),
    sideChatHostOutput,
    { dereference: true, recursive: true }
  );
  assertDirectory(sideChatHostOutput, `Native ${sideChatAppName}.app`);
  assertFile(
    resolve(sideChatHostOutput, "Contents/MacOS", sideChatAppName),
    `Native ${sideChatAppName}`
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
      sideChatHostOutput,
    ],
    appDir
  );
  run(
    "codesign",
    ["--verify", "--deep", "--strict", "--verbose=2", sideChatHostOutput],
    appDir
  );

  console.log(`Native ${sideChatAppName}.app built (${xcodeConfiguration}).`);
}

function buildNodeAddon({
  addonDir,
  label,
  output,
  targetName,
}: {
  addonDir: string;
  label: string;
  output: string;
  targetName: string;
}) {
  const nodeGypConfiguration = configuration === "release" ? "Release" : "Debug";
  run(
    nodeGypPath,
    ["rebuild", configuration === "release" ? "--release" : "--debug"],
    addonDir
  );
  mkdirSync(outputDir, { recursive: true });
  copyFileSync(
    resolve(addonDir, "build", nodeGypConfiguration, `${targetName}.node`),
    output
  );
  assertFile(output, label);

  console.log(`${label} built (${configuration}).`);
}

function buildSideChatBackdropAddon() {
  buildNodeAddon({
    addonDir: sideChatBackdropAddonDir,
    label: "Native Side Chat backdrop addon",
    output: sideChatBackdropOutput,
    targetName: "comma_side_chat_backdrop",
  });
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

function buildNotificationAuthorizationAddon() {
  buildNodeAddon({
    addonDir: notificationAuthorizationAddonDir,
    label: "Native notification authorization addon",
    output: notificationAuthorizationOutput,
    targetName: "comma_notification_authorization",
  });
}

function buildComputerUseHelper() {
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
    ],
    repoRoot
  );
  assertDirectory(computerUseAppPath, `Native ${computerUseAppName}.app`);
  assertFile(
    resolve(computerUseAppPath, "Contents/MacOS", computerUseProductName),
    `Native ${computerUseProductName}`
  );

  console.log(`Native ${computerUseAppName}.app built (${configuration}).`);
}

const synchBinary = synchBinaryPath(appDir);
const synchArchiveCacheDir = resolve(appDir, ".native-cache", "synchronicity");
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
  mkdirSync(salixConnectOutputDir, { recursive: true });

  const override = process.env.COMMA_SYNCH_BINARY?.trim();
  if (override) {
    assertFile(override, "COMMA_SYNCH_BINARY");
    placeSynchBinary(override);
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
    writeFileSync(cachedArchive, Buffer.from(await response.arrayBuffer()));
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
    // bsdtar reads both the .tar.gz and the Windows .zip.
    run("tar", ["-xf", cachedArchive, "-C", extractDir], appDir);
    const extracted = findExtractedSynch(extractDir);
    if (!extracted) {
      throw new Error(`${archive} does not contain ${synchBinaryName(platform)}.`);
    }
    placeSynchBinary(extracted);
  } finally {
    rmSync(extractDir, { force: true, recursive: true });
  }

  assertFile(synchBinary, `synch ${platform}/${arch} binary`);
  console.log(`synch ${synchReleaseTag} ready for ${platform}/${arch}.`);
}

function verifyNativeOutputs() {
  assertFile(salixConnectBinary, `salix-connect ${platform}/${arch} binary`);
  assertFile(synchBinary, `synch ${platform}/${arch} binary`);
  if (platform !== "darwin") {
    return;
  }

  assertFile(notchHostOutput, "Native NotchHost");
  assertFile(micCaptureHostOutput, "Native MicCaptureHost");
  assertFile(sleepGuardOutput, "Native CommaSleepGuard");
  assertFile(sleepGuardAddonOutput, "Native sleep guard addon");
  assertFile(sideChatBackdropOutput, "Native Side Chat backdrop addon");
  assertFile(
    notificationAuthorizationOutput,
    "Native notification authorization addon"
  );
  assertFile(fontFamiliesOutput, "Native font families addon");
  assertDirectory(sideChatHostOutput, `Native ${sideChatAppName}.app`);
  assertDirectory(computerUseAppPath, `Native ${computerUseAppName}.app`);
  assertFile(
    resolve(computerUseAppPath, "Contents/MacOS", computerUseProductName),
    `Native ${computerUseProductName}`
  );
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

  if (notificationAuthorizationOnly) {
    if (platform !== "darwin") {
      throw new Error(
        "The notification authorization addon can only be built on macOS."
      );
    }
    buildNotificationAuthorizationAddon();
    return;
  }

  if (sideChatOnly) {
    if (platform !== "darwin") {
      throw new Error("The Side Chat host can only be built on macOS.");
    }
    mkdirSync(outputDir, { recursive: true });
    buildSideChatBackdropAddon();
    buildSideChatHost();
    return;
  }

  if (sideChatBackdropOnly) {
    if (platform !== "darwin") {
      throw new Error("The Side Chat backdrop addon can only be built on macOS.");
    }
    mkdirSync(outputDir, { recursive: true });
    buildSideChatBackdropAddon();
    return;
  }

  rmSync(nativeDistRoot(appDir), { force: true, recursive: true });
  mkdirSync(salixConnectOutputDir, { recursive: true });
  run(
    "go",
    [
      "build",
      "-ldflags",
      `-X 'main.computerUseHelperAppName=${computerUseAppName}.app'`,
      "-o",
      salixConnectBinary,
      ".",
    ],
    salixConnectDir
  );
  assertFile(
    salixConnectBinary,
    `salix-connect ${platform}/${arch} binary (${salixConnectBinaryName(platform)})`
  );
  console.log(`salix-connect built for ${platform}/${arch}.`);
  await fetchSynch();

  if (platform !== "darwin") {
    console.log("Skipping macOS native build on non-macOS host.");
    return;
  }

  buildNotchHost();
  buildMicCaptureHost();
  buildSleepGuard();
  await buildAirDrop();
  buildSideChatBackdropAddon();
  buildNotificationAuthorizationAddon();
  buildFileApplicationsAddon();
  buildFontFamiliesAddon();
  buildSideChatHost();
  buildComputerUseHelper();
  verifyNativeOutputs();
}

// No top-level await: tsx runs this script as CommonJS.
buildNative().catch((error: unknown) => {
  console.error(error);
  process.exit(1);
});
