import { spawnSync } from "node:child_process";
import {
  existsSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  renameSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { basename, join, resolve } from "node:path";
import { arch as hostArch, platform as hostPlatform } from "node:process";
import { tmpdir } from "node:os";
import { notarize } from "@electron/notarize";
import { getPackableReleaseConfig } from "../src/release-config";
import {
  getDmgArtifactName,
  normalizeReleaseArtifactNames,
  validateReleaseArtifacts,
} from "./release-artifacts";

interface PackageJson {
  version?: string;
}

const appDir = resolve(import.meta.dirname, "..");
const packageJson = JSON.parse(
  readFileSync(resolve(appDir, "package.json"), "utf-8")
) as PackageJson;
const releaseConfig = getPackableReleaseConfig();
const forgePlatform = process.env.COMMA_FORGE_PLATFORM ?? hostPlatform;
const forgeArch = process.env.COMMA_FORGE_ARCH ?? hostArch;
const outDir = process.env.COMMA_FORGE_OUT_DIR ?? resolve(appDir, "out");
const packVersion = process.env.COMMA_PACK_VERSION ?? packageJson.version ?? "0.0.0";
const releaseOutputDir = resolve(
  appDir,
  process.env.COMMA_RELEASES_DIR ?? "Releases",
  releaseConfig.releaseChannel
);

function listDirectory(path: string) {
  if (!existsSync(path)) {
    return "<missing>";
  }

  return readdirSync(path).join(", ") || "<empty>";
}

function run(command: string, args: string[]) {
  const result = spawnSync(command, args, { stdio: "inherit" });

  if (result.error) {
    throw result.error;
  }

  if (result.status !== 0) {
    throw new Error(`${command} exited with status ${result.status ?? "unknown"}`);
  }
}

function findAppBundle(root: string, bundleName: string): string | undefined {
  if (!existsSync(root)) {
    return undefined;
  }

  for (const entry of readdirSync(root)) {
    if (entry === "node_modules" || entry === ".git" || entry === "Releases") {
      continue;
    }

    const path = join(root, entry);
    const stats = statSync(path);

    if (stats.isDirectory() && entry === bundleName) {
      return path;
    }

    if (stats.isDirectory()) {
      const nested = findAppBundle(path, bundleName);
      if (nested) {
        return nested;
      }
    }
  }

  return undefined;
}

function resolvePackDir() {
  if (forgePlatform !== "darwin") {
    return resolve(
      outDir,
      `${releaseConfig.productName}-${forgePlatform}-${forgeArch}`
    );
  }

  const bundleName = `${releaseConfig.productName}.app`;
  const searchRoots = [outDir, appDir, resolve(appDir, "..", "..", "..")];

  for (const root of searchRoots) {
    const discovered = findAppBundle(root, bundleName);
    if (discovered) {
      return discovered;
    }
  }

  throw new Error(
    `Electron Forge package output does not contain ${bundleName}. ` +
      `out entries: ${listDirectory(outDir)}`
  );
}

function findPortableZip() {
  const portableZip = readdirSync(releaseOutputDir).find((entry) =>
    entry.endsWith("-Portable.zip")
  );

  if (!portableZip) {
    throw new Error(`Velopack portable zip not found in ${releaseOutputDir}`);
  }

  return resolve(releaseOutputDir, portableZip);
}

function findExtractedApp(root: string) {
  const appBundle = readdirSync(root).find(
    (entry) => entry.endsWith(".app") && statSync(resolve(root, entry)).isDirectory()
  );

  if (!appBundle) {
    throw new Error(`Portable zip did not contain an app bundle: ${root}`);
  }

  return resolve(root, appBundle);
}

async function createSignedDmg() {
  if (forgePlatform !== "darwin" || process.env.COMMA_MACOS_SIGN !== "1") {
    return;
  }

  const identity = process.env.COMMA_MACOS_SIGN_IDENTITY;
  const keychain = process.env.COMMA_MACOS_KEYCHAIN;
  const keychainProfile = process.env.COMMA_MACOS_NOTARY_PROFILE;

  if (!identity || !keychain || !keychainProfile) {
    throw new Error(
      "DMG creation requires COMMA_MACOS_SIGN_IDENTITY, COMMA_MACOS_KEYCHAIN, and COMMA_MACOS_NOTARY_PROFILE."
    );
  }

  const tempDir = mkdtempSync(join(tmpdir(), "comma-dmg-"));
  const stagingDir = resolve(tempDir, "staging");
  const portableDir = resolve(tempDir, "portable");
  const tempDmgPath = resolve(tempDir, `${releaseConfig.productName}.dmg`);

  try {
    const portableZip = findPortableZip();

    run("mkdir", ["-p", portableDir, stagingDir]);
    run("unzip", ["-q", portableZip, "-d", portableDir]);

    const portableApp = findExtractedApp(portableDir);
    run("xcrun", ["stapler", "validate", portableApp]);
    run("codesign", ["--verify", "--deep", "--strict", "--verbose=2", portableApp]);

    const appCopyPath = resolve(stagingDir, basename(portableApp));
    run("ditto", [portableApp, appCopyPath]);
    symlinkSync("/Applications", resolve(stagingDir, "Applications"));

    console.log(`Creating DMG ${tempDmgPath}`);
    run("hdiutil", [
      "create",
      "-volname",
      releaseConfig.productName,
      "-srcfolder",
      stagingDir,
      "-ov",
      "-format",
      "UDZO",
      tempDmgPath,
    ]);

    console.log(`Signing DMG ${tempDmgPath}`);
    run("codesign", ["--sign", identity, "--timestamp", tempDmgPath]);

    console.log(`Notarizing DMG ${tempDmgPath}`);
    await notarize({
      appPath: tempDmgPath,
      keychain,
      keychainProfile,
    });

    console.log(`Stapling DMG ${tempDmgPath}`);
    run("xcrun", ["stapler", "staple", tempDmgPath]);
    run("xcrun", ["stapler", "validate", tempDmgPath]);

    run("mkdir", ["-p", releaseOutputDir]);

    const dmgName = getDmgArtifactName({
      packVersion,
    });
    const dmgPath = resolve(releaseOutputDir, dmgName);
    renameSync(tempDmgPath, dmgPath);
    writeFileSync(
      resolve(releaseOutputDir, `dmg.${releaseConfig.releaseChannel}.txt`),
      `${dmgName}\n`
    );
    console.log(`DMG created: ${dmgPath}`);
  } finally {
    rmSync(tempDir, { recursive: true, force: true });
  }
}

async function main() {
  console.log(`Forge appDir: ${appDir}`);
  console.log(`Forge outDir: ${outDir}`);
  console.log(`Forge out entries: ${listDirectory(outDir)}`);

  const packDir = resolvePackDir();

  if (!existsSync(packDir)) {
    throw new Error(`Resolved Velopack packDir does not exist: ${packDir}`);
  }

  const packResult = spawnSync("pnpm", ["pack:velopack"], {
    cwd: appDir,
    env: {
      ...process.env,
      COMMA_PACK_DIR: packDir,
    },
    stdio: "inherit",
  });

  if (packResult.error) {
    throw packResult.error;
  }

  if (packResult.status !== 0) {
    throw new Error(`pnpm pack:velopack exited with status ${packResult.status}`);
  }

  await createSignedDmg();
  normalizeReleaseArtifactNames({
    releaseOutputDir,
    packVersion,
    releaseChannel: releaseConfig.releaseChannel,
  });
  await validateReleaseArtifacts({
    releaseOutputDir,
    releaseChannel: releaseConfig.releaseChannel,
    packVersion,
  });
}

main().catch((error: unknown) => {
  console.error(error);
  process.exit(1);
});
