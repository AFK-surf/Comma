import { createHash } from "node:crypto";
import {
  chmodSync,
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

const fakeAwsSource = String.raw`#!/usr/bin/env node
const {
  appendFileSync,
  copyFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  statSync,
} = require("node:fs");
const { dirname, resolve } = require("node:path");

const values = process.argv.slice(2);
if (values[0] === "--endpoint-url") {
  values.splice(0, 2);
}

appendFileSync(
  process.env.FAKE_AWS_LOG,
  JSON.stringify({ arguments: values }) + "\n"
);

function parseRemote(value) {
  const match = /^s3:\/\/([^/]+)\/?(.*)$/.exec(value);
  if (!match) return undefined;
  return {
    bucket: match[1],
    key: match[2],
    path: resolve(process.env.FAKE_R2_ROOT, match[1], match[2]),
  };
}

function copy(source, destination) {
  mkdirSync(dirname(destination), { recursive: true });
  copyFileSync(source, destination);
}

function fail(message) {
  process.stderr.write(message + "\n");
  process.exit(1);
}

if (values[0] === "s3api" && values[1] === "head-object") {
  const bucket = values[values.indexOf("--bucket") + 1];
  const key = values[values.indexOf("--key") + 1];
  const path = resolve(process.env.FAKE_R2_ROOT, bucket, key);
  if (!existsSync(path)) fail("not found: " + key);
  process.stdout.write(JSON.stringify({ ContentLength: statSync(path).size }));
  process.exit(0);
}

if (values[0] !== "s3") fail("unsupported fake aws command");

if (values[1] === "sync") {
  const source = values[2];
  const destination = parseRemote(values[3]);
  const excluded = new Set();
  for (let index = 4; index < values.length; index += 1) {
    if (values[index] === "--exclude") {
      excluded.add(values[index + 1]);
      index += 1;
    }
  }

  for (const fileName of readdirSync(source)) {
    const sourcePath = resolve(source, fileName);
    if (!statSync(sourcePath).isFile() || excluded.has(fileName)) continue;
    const key = destination.key + "/" + fileName;
    if (process.env.FAKE_AWS_SKIP_UPLOAD_KEY === key) continue;
    copy(sourcePath, resolve(process.env.FAKE_R2_ROOT, destination.bucket, key));
  }
  process.exit(0);
}

if (values[1] === "cp") {
  const source = values[2];
  const destination = values[3];
  const remoteSource = parseRemote(source);
  const remoteDestination = parseRemote(destination);

  if (remoteSource && !existsSync(remoteSource.path)) {
    fail("not found: " + remoteSource.key);
  }

  if (remoteSource && destination === "-") {
    process.stdout.write(readFileSync(remoteSource.path));
    process.exit(0);
  }

  if (remoteSource && remoteDestination) {
    copy(remoteSource.path, remoteDestination.path);
    process.exit(0);
  }

  if (remoteSource) {
    copy(remoteSource.path, destination);
    process.exit(0);
  }

  if (remoteDestination) {
    if (process.env.FAKE_AWS_SKIP_UPLOAD_KEY !== remoteDestination.key) {
      copy(source, remoteDestination.path);
    }
    process.exit(0);
  }
}

fail("unsupported fake aws arguments: " + values.join(" "));
`;

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
  writeFileSync(fakeAwsPath, fakeAwsSource);
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
  extraEnvironment: NodeJS.ProcessEnv = {}
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
});
