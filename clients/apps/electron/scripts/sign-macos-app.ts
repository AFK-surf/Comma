import { spawnSync } from "node:child_process";
import { existsSync, readdirSync, statSync } from "node:fs";
import { arch, platform } from "node:process";
import { basename, resolve } from "node:path";
import { sign } from "@electron/osx-sign";
import { getPackableReleaseConfig } from "../src/release-config";
import {
  packagedComputerUseAppPath,
  packagedNotchHostPath,
  packagedSideChatHostAppPath,
} from "./native-paths";

const appDir = resolve(import.meta.dirname, "..");
const repoRoot = resolve(appDir, "../../..");
const releaseConfig = getPackableReleaseConfig();
const forgePlatform = process.env.COMMA_FORGE_PLATFORM ?? platform;
const forgeArch = process.env.COMMA_FORGE_ARCH ?? arch;
const outDir = process.env.COMMA_FORGE_OUT_DIR ?? resolve(appDir, "out");
const entitlements = resolve(appDir, "build/entitlements.mac.entitlements");
const computerUsePackageScript = resolve(
  repoRoot,
  "systems/connector/salix-connect/scripts/package-computer-use-helper.sh"
);

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
    const path = resolve(root, entry);
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

function resolveAppBundle() {
  const bundleName = `${releaseConfig.productName}.app`;
  const exact = resolve(
    outDir,
    `${releaseConfig.productName}-${forgePlatform}-${forgeArch}`,
    bundleName
  );

  if (existsSync(exact)) {
    return exact;
  }

  const discovered = findAppBundle(outDir, bundleName);
  if (discovered) {
    return discovered;
  }

  throw new Error(`Cannot find ${bundleName} under ${outDir}`);
}

function signNestedHelperApp(helperApp: string, identity: string, keychain: string) {
  if (!existsSync(helperApp)) {
    throw new Error(`Cannot find CommaComputerUse helper app at ${helperApp}`);
  }

  console.log(`Signing helper app: ${basename(helperApp)}`);
  run("bash", [
    computerUsePackageScript,
    "--sign-only",
    "--app-path",
    helperApp,
    "--sign-identity",
    identity,
    "--keychain",
    keychain,
    "--hardened-runtime",
    "--timestamp",
    "--entitlements",
    entitlements,
  ]);
}

async function main() {
  if (forgePlatform !== "darwin" || process.env.COMMA_MACOS_SIGN !== "1") {
    return;
  }

  const identity = process.env.COMMA_MACOS_SIGN_IDENTITY;
  const keychain = process.env.COMMA_MACOS_KEYCHAIN;

  if (!identity || !keychain) {
    throw new Error(
      "COMMA_MACOS_SIGN=1 requires COMMA_MACOS_SIGN_IDENTITY and COMMA_MACOS_KEYCHAIN."
    );
  }

  const app = resolveAppBundle();
  const notchHost = packagedNotchHostPath(app);
  const computerUseHelper = packagedComputerUseAppPath(app, forgePlatform, forgeArch);
  const sideChatHelper = packagedSideChatHostAppPath(app);
  const binaries = existsSync(notchHost) ? [notchHost] : [];

  signNestedHelperApp(computerUseHelper, identity, keychain);
  signNestedHelperApp(sideChatHelper, identity, keychain);

  console.log(`Signing ${app}`);
  if (binaries.length > 0) {
    console.log(`Signing extra binary: ${basename(notchHost)}`);
  }

  await sign({
    app,
    identity,
    keychain,
    platform: "darwin",
    optionsForFile: () => ({ hardenedRuntime: true, entitlements }),
    preAutoEntitlements: false,
    preEmbedProvisioningProfile: false,
    binaries,
    ignore: (filePath) => /\.(pak|bin|dat)$/u.test(filePath),
  });

  run("codesign", ["--verify", "--deep", "--strict", "--verbose=2", app]);
  console.log(`Signed and verified ${app}`);
}

main().catch((error: unknown) => {
  console.error(error);
  process.exit(1);
});
