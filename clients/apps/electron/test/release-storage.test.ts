import { createHash } from "node:crypto";
import {
  chmodSync,
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { delimiter, dirname, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { afterEach, describe, expect, it } from "vitest";

const releaseStorageScript = resolve(
  import.meta.dirname,
  "../scripts/release-storage.mjs"
);
const testDirectories: string[] = [];

const fakeAwsScript = resolve(import.meta.dirname, "fixtures/fake-aws.sh");

interface ReleaseHarness {
  bucket: string;
  fakeBin: string;
  logPath: string;
  prefix: string;
  releaseDir: string;
  remoteRoot: string;
  root: string;
}

function createHarness(prefix: string): ReleaseHarness {
  const root = mkdtempSync(resolve(tmpdir(), "comma-release-storage-"));
  const fakeBin = resolve(root, "bin");
  const releaseDir = resolve(root, "release");
  const remoteRoot = resolve(root, "r2");
  const logPath = resolve(root, "aws.log");

  testDirectories.push(root);
  mkdirSync(fakeBin, { recursive: true });
  mkdirSync(releaseDir, { recursive: true });
  mkdirSync(remoteRoot, { recursive: true });
  writeFileSync(logPath, "");

  const fakeAwsPath = resolve(fakeBin, "aws");
  copyFileSync(fakeAwsScript, fakeAwsPath);
  chmodSync(fakeAwsPath, 0o755);

  return {
    bucket: "example-release-bucket",
    fakeBin,
    logPath,
    prefix,
    releaseDir,
    remoteRoot,
    root,
  };
}

function getRemotePath(harness: ReleaseHarness, fileName: string) {
  return resolve(harness.remoteRoot, harness.bucket, harness.prefix, fileName);
}

function writeRemote(harness: ReleaseHarness, fileName: string, content: string) {
  const path = getRemotePath(harness, fileName);
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, content);
}

function getReleaseAsset(fileName: string, content: string) {
  return {
    PackageId: "surf.comma.desktop",
    Version: "1.2.3",
    Type: "Full",
    FileName: fileName,
    SHA1: createHash("sha1").update(content).digest("hex").toUpperCase(),
    SHA256: createHash("sha256").update(content).digest("hex").toUpperCase(),
    Size: Buffer.byteLength(content),
  };
}

function runReleaseStorage(
  harness: ReleaseHarness,
  command: "promote-production" | "publish-staging",
  extraEnvironment: NodeJS.ProcessEnv = {},
  extraArguments: string[] = []
) {
  const cliArguments = [
    releaseStorageScript,
    command,
    "--endpoint",
    "https://example.r2.cloudflarestorage.com",
    "--bucket",
    harness.bucket,
    "--prefix",
    harness.prefix,
  ];

  if (command === "publish-staging") {
    cliArguments.push("--release-dir", harness.releaseDir);
  }
  cliArguments.push(...extraArguments);

  return spawnSync(process.execPath, cliArguments, {
    encoding: "utf8",
    env: {
      ...process.env,
      ...extraEnvironment,
      FAKE_AWS_LOG: harness.logPath,
      FAKE_R2_ROOT: harness.remoteRoot,
      PATH: `${harness.fakeBin}${delimiter}${process.env.PATH}`,
    },
  });
}

function readAwsOperations(harness: ReleaseHarness) {
  return readFileSync(harness.logPath, "utf8")
    .trim()
    .split("\n")
    .filter(Boolean)
    .map((line) => (JSON.parse(line) as { arguments: string[] }).arguments);
}

afterEach(() => {
  for (const directory of testDirectories.splice(0)) {
    rmSync(directory, { recursive: true, force: true });
  }
});

describe("release storage publication", () => {
  it("keeps the old staging feed active until every referenced asset exists", () => {
    const harness = createHarness("comma/electron/staging");
    const packageName = "Comma-1.2.3-staging.456-full.nupkg";
    const portableName = "Comma-1.2.3-staging.456.zip";
    const dmgName = "Comma-1.2.3-staging.456.dmg";
    const packageContent = "full package";
    const oldFeed = '{"release":"old"}\n';
    const newFeed = `${JSON.stringify({
      Assets: [getReleaseAsset(packageName, packageContent)],
    })}\n`;

    writeRemote(harness, "releases.staging.json", oldFeed);
    writeRemote(harness, "unreferenced-old-package.nupkg", "retained");
    writeFileSync(resolve(harness.releaseDir, packageName), packageContent);
    writeFileSync(resolve(harness.releaseDir, portableName), "portable");
    writeFileSync(resolve(harness.releaseDir, dmgName), "dmg");
    writeFileSync(resolve(harness.releaseDir, "releases.staging.json"), newFeed);
    writeFileSync(
      resolve(harness.releaseDir, "assets.staging.json"),
      JSON.stringify([
        { RelativeFileName: packageName, Type: "Full" },
        { RelativeFileName: portableName, Type: "Portable" },
      ])
    );
    writeFileSync(resolve(harness.releaseDir, "RELEASES-staging"), `${packageName}\n`);
    writeFileSync(resolve(harness.releaseDir, "dmg.staging.txt"), `${dmgName}\n`);

    const failed = runReleaseStorage(harness, "publish-staging", {
      FAKE_AWS_SKIP_UPLOAD_KEY: `${harness.prefix}/${packageName}`,
    });

    expect(failed.status).not.toBe(0);
    // The failure says what the bucket holds of this release: the sync sent the
    // portable zip, not the package.
    const listing = failed.stderr.slice(failed.stderr.indexOf("The bucket holds"));
    expect(listing).toContain(
      `The bucket holds under ${harness.prefix}/Comma-1.2.3-staging.456*:`
    );
    expect(listing).toContain(`${harness.prefix}/${portableName} 8 bytes`);
    expect(listing).not.toContain(packageName);
    expect(readFileSync(getRemotePath(harness, "releases.staging.json"), "utf8")).toBe(
      oldFeed
    );

    writeFileSync(harness.logPath, "");
    const published = runReleaseStorage(harness, "publish-staging");

    expect(published.status, published.stderr).toBe(0);
    expect(readFileSync(getRemotePath(harness, "releases.staging.json"), "utf8")).toBe(
      newFeed
    );
    expect(existsSync(getRemotePath(harness, "unreferenced-old-package.nupkg"))).toBe(
      true
    );

    const operations = readAwsOperations(harness);
    const syncIndex = operations.findIndex(
      (arguments_) => arguments_[0] === "s3" && arguments_[1] === "sync"
    );
    const packageHeadIndex = operations.findIndex(
      (arguments_) =>
        arguments_[0] === "s3api" &&
        arguments_[arguments_.indexOf("--key") + 1] ===
          `${harness.prefix}/${packageName}`
    );
    const activeFeedIndex = operations.findIndex(
      (arguments_) =>
        arguments_[0] === "s3" &&
        arguments_[1] === "cp" &&
        arguments_[3]?.endsWith("/releases.staging.json")
    );

    expect(syncIndex).toBeGreaterThanOrEqual(0);
    expect(packageHeadIndex).toBeGreaterThan(syncIndex);
    expect(activeFeedIndex).toBe(operations.length - 1);
    expect(operations.flat()).not.toContain("--delete");
  });

  it("does not promote production when a feed asset is missing or corrupted", () => {
    const harness = createHarness("comma/electron/prod");
    const packageName = "Comma-1.2.3-full.nupkg";
    const packageContent = "verified full package";
    const dmgName = "Comma-1.2.3.dmg";
    const oldFeed = '{"release":"old"}\n';
    const pendingFeed = `${JSON.stringify({
      Assets: [getReleaseAsset(packageName, packageContent)],
    })}\n`;

    writeRemote(harness, "releases.prod.json", oldFeed);
    writeRemote(harness, "releases.prod.pending.json", pendingFeed);
    writeRemote(harness, "dmg.prod.pending.txt", `${dmgName}\n`);
    writeRemote(harness, dmgName, "signed dmg");

    const missingAsset = runReleaseStorage(harness, "promote-production");
    expect(missingAsset.status).not.toBe(0);
    expect(readFileSync(getRemotePath(harness, "releases.prod.json"), "utf8")).toBe(
      oldFeed
    );

    writeRemote(harness, packageName, "tampered full package");
    const corruptedAsset = runReleaseStorage(harness, "promote-production");
    expect(corruptedAsset.status).not.toBe(0);
    expect(corruptedAsset.stderr).toContain("SHA1 mismatch");
    expect(readFileSync(getRemotePath(harness, "releases.prod.json"), "utf8")).toBe(
      oldFeed
    );

    writeRemote(harness, packageName, packageContent);
    writeRemote(
      harness,
      "assets.prod.pending.json",
      JSON.stringify([{ RelativeFileName: packageName, Type: "Full" }])
    );
    writeRemote(harness, "RELEASES-prod.pending", `${packageName}\n`);
    writeFileSync(harness.logPath, "");

    const promoted = runReleaseStorage(harness, "promote-production");
    expect(promoted.status, promoted.stderr).toBe(0);
    expect(readFileSync(getRemotePath(harness, "releases.prod.json"), "utf8")).toBe(
      pendingFeed
    );
    expect(readFileSync(getRemotePath(harness, "dmg.prod.txt"), "utf8")).toBe(
      `${dmgName}\n`
    );

    const operations = readAwsOperations(harness);
    const finalOperation = operations.at(-1);
    expect(finalOperation?.[0]).toBe("s3");
    expect(finalOperation?.[1]).toBe("cp");
    expect(finalOperation?.[2]).toContain("releases.prod.pending.json");
    expect(finalOperation?.[3]).toContain("releases.prod.json");
  });

  it("promotes a Windows production feed, which has an installer and no DMG", () => {
    const harness = createHarness("comma/electron/prod/win32");
    const packageName = "Comma-1.2.3-full.nupkg";
    const packageContent = "windows full package";
    const installer = "Comma-1.2.3-Setup.exe";
    const pendingFeed = `${JSON.stringify({
      Assets: [getReleaseAsset(packageName, packageContent)],
    })}\n`;
    writeRemote(harness, "releases.prod.pending.json", pendingFeed);
    writeRemote(harness, packageName, packageContent);
    writeRemote(harness, "setup.prod.pending.txt", `${installer}\n`);

    // The installer the pointer names must be there before anything is promoted.
    const missing = runReleaseStorage(harness, "promote-production", {}, [
      "--dmg",
      "none",
    ]);
    expect(missing.status).not.toBe(0);
    expect(existsSync(getRemotePath(harness, "releases.prod.json"))).toBe(false);

    writeRemote(harness, installer, "windows installer");
    const promoted = runReleaseStorage(harness, "promote-production", {}, [
      "--dmg",
      "none",
    ]);
    expect(promoted.status, promoted.stderr).toBe(0);
    expect(readFileSync(getRemotePath(harness, "releases.prod.json"), "utf8")).toBe(
      pendingFeed
    );
    expect(readFileSync(getRemotePath(harness, "setup.prod.txt"), "utf8")).toBe(
      `${installer}\n`
    );
    expect(existsSync(getRemotePath(harness, "dmg.prod.txt"))).toBe(false);
  });
});
