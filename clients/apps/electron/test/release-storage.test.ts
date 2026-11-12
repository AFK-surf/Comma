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
  command: "promote-production" | "publish-production-pending" | "publish-staging",
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

  if (command !== "promote-production") {
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

/** A feed entry of the given version and type, as `vpk pack` writes it, for a package of `content`. */
function getFeedAsset(
  packageId: string,
  version: string,
  type: "Delta" | "Full",
  content: string
) {
  return {
    ...getReleaseAsset(`Comma-${version}-${type.toLowerCase()}.nupkg`, content),
    PackageId: packageId,
    Version: version,
    Type: type,
  };
}

/** Writes each asset's package beside the feed, with `packageBytes(asset)` as its bytes. */
function writeLocalPackages(
  harness: ReleaseHarness,
  assets: ReturnType<typeof getFeedAsset>[]
) {
  for (const asset of assets) {
    writeFileSync(resolve(harness.releaseDir, asset.FileName), packageBytes(asset));
  }
}

function packageBytes(asset: { Type: string; Version: string }) {
  return `${asset.Type} ${asset.Version}`;
}

function stagingVersion(build: number) {
  return `1.0.14-staging.${build}`;
}

function feedDeltaVersions(feed: { Assets: { Type: string; Version: string }[] }) {
  return feed.Assets.filter((asset) => asset.Type === "Delta").map(
    (asset) => asset.Version
  );
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
        arguments_[3] ===
          `s3://${harness.bucket}/${harness.prefix}/releases.staging.json`
    );

    expect(syncIndex).toBeGreaterThanOrEqual(0);
    expect(packageHeadIndex).toBeGreaterThan(syncIndex);
    expect(activeFeedIndex).toBe(operations.length - 1);
    expect(operations.flat()).not.toContain("--delete");
  });

  it("keeps the remote feed's newest deltas, so a client several versions behind gets each step", () => {
    const harness = createHarness("comma/electron/staging");
    const packageId = "surf.comma.desktop.staging";
    const asset = (build: number, type: "Delta" | "Full") =>
      getFeedAsset(
        packageId,
        stagingVersion(build),
        type,
        packageBytes({ Type: type, Version: stagingVersion(build) })
      );

    // The live feed after a run of releases from build 5 to build 40 that merged their feeds.
    const remoteAssets = [asset(40, "Full")];
    for (let build = 40; build >= 5; build -= 1)
      remoteAssets.push(asset(build, "Delta"));
    remoteAssets.push(asset(39, "Full"));
    // An older upload under the new delta's name: the packed entry must win.
    remoteAssets.push({ ...asset(41, "Delta"), Size: 1 });
    const remoteFeed = JSON.stringify({ Assets: remoteAssets });
    writeRemote(harness, "releases.staging.json", remoteFeed);
    for (const remote of remoteAssets.slice(0, -1)) {
      writeRemote(harness, remote.FileName, packageBytes(remote));
    }

    // What `vpk pack` writes for build 41: its full package and delta, and the previous full package it downloaded.
    const packed = [asset(41, "Full"), asset(41, "Delta"), asset(40, "Full")];
    writeLocalPackages(harness, packed);
    writeFileSync(
      resolve(harness.releaseDir, "releases.staging.json"),
      JSON.stringify({ Assets: packed })
    );

    // Each listed package must be in the bucket before the feed changes.
    rmSync(getRemotePath(harness, asset(20, "Delta").FileName));
    const missing = runReleaseStorage(harness, "publish-staging", {}, [
      "--dmg",
      "none",
    ]);
    expect(missing.status).not.toBe(0);
    expect(missing.stderr).toContain(asset(20, "Delta").FileName);
    expect(readFileSync(getRemotePath(harness, "releases.staging.json"), "utf8")).toBe(
      remoteFeed
    );

    writeRemote(harness, asset(20, "Delta").FileName, packageBytes(asset(20, "Delta")));
    writeFileSync(
      resolve(harness.releaseDir, "releases.staging.json"),
      JSON.stringify({ Assets: packed })
    );
    const published = runReleaseStorage(harness, "publish-staging", {}, [
      "--dmg",
      "none",
    ]);
    expect(published.status, published.stderr).toBe(0);

    const feed = JSON.parse(
      readFileSync(getRemotePath(harness, "releases.staging.json"), "utf8")
    ) as { Assets: ReturnType<typeof getFeedAsset>[] };
    // The packed entries first and unchanged, then the 29 newest remote deltas: 30 deltas from build 41 to 12.
    expect(feed.Assets.slice(0, 3)).toEqual(packed);
    expect(feedDeltaVersions(feed)).toEqual(
      Array.from({ length: 30 }, (_, index) => stagingVersion(41 - index))
    );
    expect(
      feed.Assets.filter((entry) => entry.Type === "Full").map((entry) => entry.Version)
    ).toEqual([stagingVersion(41), stagingVersion(40)]);
    // Deltas out of the window leave the feed, not the bucket.
    expect(existsSync(getRemotePath(harness, asset(5, "Delta").FileName))).toBe(true);
  });

  it("merges the active production feed into the pending one, which sign-off promotes", () => {
    const harness = createHarness("comma/electron/prod");
    const packageId = "surf.comma.desktop";
    const asset = (version: string, type: "Delta" | "Full") =>
      getFeedAsset(
        packageId,
        version,
        type,
        packageBytes({ Type: type, Version: version })
      );

    const activeAssets = [
      asset("1.0.1", "Full"),
      asset("1.0.1", "Delta"),
      asset("1.0.0", "Full"),
    ];
    const activeFeed = JSON.stringify({ Assets: activeAssets });
    writeRemote(harness, "releases.prod.json", activeFeed);
    // A pending release that was never promoted: no client has 1.0.2, and 1.0.3 is made from 1.0.1.
    const stalePending = [
      asset("1.0.2", "Full"),
      asset("1.0.2", "Delta"),
      asset("1.0.1", "Full"),
    ];
    writeRemote(
      harness,
      "releases.prod.pending.json",
      JSON.stringify({ Assets: stalePending })
    );
    for (const remote of [...activeAssets, ...stalePending]) {
      writeRemote(harness, remote.FileName, packageBytes(remote));
    }

    const packed = [
      asset("1.0.3", "Full"),
      asset("1.0.3", "Delta"),
      asset("1.0.1", "Full"),
    ];
    writeLocalPackages(harness, packed);
    // The release job's "Prepare pending production feed" copy of the packed feed.
    for (const name of ["releases.prod.json", "releases.prod.pending.json"]) {
      writeFileSync(
        resolve(harness.releaseDir, name),
        JSON.stringify({ Assets: packed })
      );
    }

    const published = runReleaseStorage(harness, "publish-production-pending", {}, [
      "--dmg",
      "none",
    ]);
    expect(published.status, published.stderr).toBe(0);
    expect(readFileSync(getRemotePath(harness, "releases.prod.json"), "utf8")).toBe(
      activeFeed
    );
    const pending = JSON.parse(
      readFileSync(getRemotePath(harness, "releases.prod.pending.json"), "utf8")
    ) as { Assets: ReturnType<typeof getFeedAsset>[] };
    expect(feedDeltaVersions(pending)).toEqual(["1.0.3", "1.0.1"]);

    const promoted = runReleaseStorage(harness, "promote-production", {}, [
      "--dmg",
      "none",
    ]);
    expect(promoted.status, promoted.stderr).toBe(0);
    expect(
      JSON.parse(readFileSync(getRemotePath(harness, "releases.prod.json"), "utf8"))
    ).toEqual(pending);
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
