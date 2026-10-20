#!/usr/bin/env node

import { createHash } from "node:crypto";
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, join, resolve } from "node:path";
import { spawn, spawnSync } from "node:child_process";

const channelMetadata = {
  staging: {
    active: [
      "assets.staging.json",
      "RELEASES-staging",
      "dmg.staging.txt",
      "setup.staging.txt",
      "releases.staging.json",
    ],
    feed: "releases.staging.json",
    manifest: "assets.staging.json",
    dmgPointer: "dmg.staging.txt",
    setupPointer: "setup.staging.txt",
  },
  "prod-pending": {
    active: [
      "assets.prod.pending.json",
      "RELEASES-prod.pending",
      "dmg.prod.pending.txt",
      "setup.prod.pending.txt",
      "releases.prod.pending.json",
    ],
    excluded: [
      "assets.prod.json",
      "RELEASES-prod",
      "dmg.prod.txt",
      "setup.prod.txt",
      "releases.prod.json",
    ],
    feed: "releases.prod.pending.json",
    manifest: "assets.prod.pending.json",
    dmgPointer: "dmg.prod.pending.txt",
    setupPointer: "setup.prod.pending.txt",
  },
};

function parseOptions(values) {
  const options = new Map();

  for (let index = 0; index < values.length; index += 2) {
    const key = values[index];
    const value = values[index + 1];

    if (!key?.startsWith("--") || value === undefined) {
      throw new Error(`Expected --name value arguments; received: ${values.join(" ")}`);
    }
    if (options.has(key)) {
      throw new Error(`Duplicate option: ${key}`);
    }

    options.set(key, value);
  }

  return options;
}

function requireOption(options, name) {
  const value = options.get(name);
  if (!value) {
    throw new Error(`Missing required option: ${name}`);
  }
  return value;
}

function getStorage(options) {
  const prefix = requireOption(options, "--prefix").replace(/^\/+|\/+$/g, "");
  if (!prefix) {
    throw new Error("--prefix must contain an object key prefix");
  }

  return {
    endpoint: requireOption(options, "--endpoint"),
    bucket: requireOption(options, "--bucket"),
    prefix,
  };
}

function getAwsArguments(storage, arguments_) {
  return ["--endpoint-url", storage.endpoint, ...arguments_];
}

function formatCommand(arguments_) {
  return ["aws", ...arguments_].join(" ");
}

function runAws(storage, arguments_, { allowFailure = false, capture = false } = {}) {
  const awsArguments = getAwsArguments(storage, arguments_);
  const result = spawnSync("aws", awsArguments, {
    encoding: capture ? "utf8" : undefined,
    maxBuffer: 10 * 1024 * 1024,
    stdio: capture ? "pipe" : "inherit",
  });

  if (result.error) {
    throw result.error;
  }
  if (result.status !== 0 && !allowFailure) {
    const stderr =
      typeof result.stderr === "string" && result.stderr.trim()
        ? `\n${result.stderr.trim()}`
        : "";
    throw new Error(
      `AWS CLI exited with status ${result.status}: ${formatCommand(awsArguments)}${stderr}`
    );
  }

  return result;
}

function getObjectKey(storage, fileName) {
  return `${storage.prefix}/${fileName}`;
}

function getObjectUri(storage, fileName = "") {
  const suffix = fileName ? `/${fileName}` : "";
  return `s3://${storage.bucket}/${storage.prefix}${suffix}`;
}

function assertArtifactFileName(fileName, source) {
  if (!fileName || basename(fileName) !== fileName) {
    throw new Error(
      `Release metadata must reference a single artifact filename: ${fileName} (${source})`
    );
  }
}

function readJson(path) {
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch (error) {
    throw new Error(`Invalid release metadata JSON: ${path}`, { cause: error });
  }
}

function isRecord(value) {
  return typeof value === "object" && value !== null;
}

function parseReleaseFeed(path) {
  const feed = readJson(path);
  if (!isRecord(feed) || !Array.isArray(feed.Assets)) {
    throw new Error(`Release feed must contain an Assets array: ${path}`);
  }
  if (feed.Assets.length === 0) {
    throw new Error(`Release feed must contain at least one asset: ${path}`);
  }

  const assets = [];
  const fileNames = new Set();

  for (const [index, value] of feed.Assets.entries()) {
    if (
      !isRecord(value) ||
      typeof value.FileName !== "string" ||
      !Number.isSafeInteger(value.Size) ||
      value.Size < 0 ||
      typeof value.SHA1 !== "string" ||
      !/^[a-f0-9]{40}$/i.test(value.SHA1) ||
      typeof value.SHA256 !== "string" ||
      !/^[a-f0-9]{64}$/i.test(value.SHA256)
    ) {
      throw new Error(`Invalid release asset at Assets[${index}]: ${path}`);
    }

    assertArtifactFileName(value.FileName, path);
    if (fileNames.has(value.FileName)) {
      throw new Error(`Duplicate release feed filename: ${value.FileName} (${path})`);
    }

    fileNames.add(value.FileName);
    assets.push({
      fileName: value.FileName,
      size: value.Size,
      sha1: value.SHA1.toUpperCase(),
      sha256: value.SHA256.toUpperCase(),
    });
  }

  return assets;
}

function parseAssetManifest(path) {
  if (!existsSync(path)) {
    return [];
  }

  const manifest = readJson(path);
  if (!Array.isArray(manifest)) {
    throw new Error(`Release asset manifest must be an array: ${path}`);
  }

  const fileNames = new Set();
  return manifest.map((value, index) => {
    if (!isRecord(value) || typeof value.RelativeFileName !== "string") {
      throw new Error(`Invalid release asset manifest entry at [${index}]: ${path}`);
    }

    assertArtifactFileName(value.RelativeFileName, path);
    if (fileNames.has(value.RelativeFileName)) {
      throw new Error(
        `Duplicate release asset manifest filename: ${value.RelativeFileName} (${path})`
      );
    }
    fileNames.add(value.RelativeFileName);
    return value.RelativeFileName;
  });
}

/** The artifact a pointer file names: a macOS DMG (`dmg.*.txt`) or a Windows installer (`setup.*.txt`). */
const pointerKinds = {
  dmg: { label: "DMG", suffix: ".dmg" },
  setup: { label: "Windows installer", suffix: "-Setup.exe" },
};

function parsePointer(path, { required, kind = "dmg" }) {
  const { label, suffix } = pointerKinds[kind];
  if (!existsSync(path)) {
    if (required) {
      throw new Error(`${label} pointer not found: ${path}`);
    }
    return undefined;
  }

  const fileName = readFileSync(path, "utf8").trim();
  assertArtifactFileName(fileName, path);
  if (!fileName.endsWith(suffix)) {
    throw new Error(`${label} pointer must reference a ${suffix} artifact: ${path}`);
  }
  return fileName;
}

function parseDmgPointer(path, { required }) {
  return parsePointer(path, { required, kind: "dmg" });
}

function headRemoteObject(storage, fileName, { allowMissing = false } = {}) {
  assertArtifactFileName(fileName, "remote object lookup");
  const awsArguments = [
    "s3api",
    "head-object",
    "--bucket",
    storage.bucket,
    "--key",
    getObjectKey(storage, fileName),
    "--output",
    "json",
  ];
  const result = runAws(storage, awsArguments, { allowFailure: true, capture: true });

  if (result.status !== 0) {
    const stderr = typeof result.stderr === "string" ? result.stderr.trim() : "";
    const missing = /(?:\b404\b|NoSuchKey|Not Found|not found)/i.test(stderr);
    if (allowMissing && missing) {
      return undefined;
    }

    throw new Error(
      `AWS CLI exited with status ${result.status}: ${formatCommand(
        getAwsArguments(storage, awsArguments)
      )}${stderr ? `\n${stderr}` : ""}${missing ? `\n${listReleaseObjects(storage, fileName)}` : ""}`
    );
  }

  let head;
  try {
    head = JSON.parse(result.stdout);
  } catch (error) {
    throw new Error(`Invalid head-object response for ${fileName}`, { cause: error });
  }

  if (!isRecord(head) || !Number.isSafeInteger(head.ContentLength)) {
    throw new Error(`head-object did not return ContentLength for ${fileName}`);
  }

  return { size: head.ContentLength };
}

/**
 * What the bucket holds now of the release a missing object belongs to: whether
 * the upload never landed, or landed under another name or size.
 */
function listReleaseObjects(storage, fileName) {
  const release = fileName.replace(/(?:-full|-delta)?\.[a-z]+$/i, "");
  const prefix = getObjectKey(storage, release);
  const result = runAws(
    storage,
    [
      "s3api",
      "list-objects-v2",
      "--bucket",
      storage.bucket,
      "--prefix",
      prefix,
      "--output",
      "json",
    ],
    { allowFailure: true, capture: true }
  );
  if (result.status !== 0) {
    return `Listing ${prefix}* failed: ${String(result.stderr ?? "").trim()}`;
  }
  let listing;
  try {
    listing = JSON.parse(result.stdout || "{}");
  } catch {
    return `Listing ${prefix}* returned: ${String(result.stdout).trim()}`;
  }
  const objects = Array.isArray(listing?.Contents) ? listing.Contents : [];
  return objects.length === 0
    ? `The bucket holds no object under ${prefix}*.`
    : `The bucket holds under ${prefix}*:\n${objects
        .map((object) =>
          `  ${object.Key} ${object.Size} bytes ${object.LastModified ?? ""}`.trimEnd()
        )
        .join("\n")}`;
}

async function getRemoteHashes(storage, fileName) {
  const sha1 = createHash("sha1");
  const sha256 = createHash("sha256");
  const awsArguments = getAwsArguments(storage, [
    "s3",
    "cp",
    getObjectUri(storage, fileName),
    "-",
    "--only-show-errors",
  ]);

  await new Promise((resolvePromise, rejectPromise) => {
    const child = spawn("aws", awsArguments, {
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stderr = "";

    child.stdout.on("data", (chunk) => {
      sha1.update(chunk);
      sha256.update(chunk);
    });
    child.stderr.setEncoding("utf8");
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });
    child.on("error", rejectPromise);
    child.on("close", (status) => {
      if (status === 0) {
        resolvePromise();
        return;
      }

      rejectPromise(
        new Error(
          `AWS CLI exited with status ${status}: ${formatCommand(awsArguments)}${
            stderr.trim() ? `\n${stderr.trim()}` : ""
          }`
        )
      );
    });
  });

  return {
    sha1: sha1.digest("hex").toUpperCase(),
    sha256: sha256.digest("hex").toUpperCase(),
  };
}

async function verifyRemoteFeedAssets(storage, assets, { verifyHashes }) {
  for (const asset of assets) {
    const head = headRemoteObject(storage, asset.fileName);
    if (head.size !== asset.size) {
      throw new Error(
        `Remote release asset size mismatch for ${asset.fileName}: expected ${asset.size}, got ${head.size}`
      );
    }

    if (verifyHashes) {
      const hashes = await getRemoteHashes(storage, asset.fileName);
      if (hashes.sha1 !== asset.sha1) {
        throw new Error(`Remote release asset SHA1 mismatch: ${asset.fileName}`);
      }
      if (hashes.sha256 !== asset.sha256) {
        throw new Error(`Remote release asset SHA256 mismatch: ${asset.fileName}`);
      }
    }
  }
}

function verifyRemoteManifestAssets(storage, manifestPath, localArtifactDir) {
  for (const fileName of parseAssetManifest(manifestPath)) {
    const localPath = resolve(localArtifactDir, fileName);
    if (!existsSync(localPath) || !statSync(localPath).isFile()) {
      throw new Error(`Release asset manifest artifact not found: ${localPath}`);
    }

    const expectedSize = statSync(localPath).size;
    const head = headRemoteObject(storage, fileName);
    if (head.size !== expectedSize) {
      throw new Error(
        `Remote release manifest asset size mismatch for ${fileName}: expected ${expectedSize}, got ${head.size}`
      );
    }
  }
}

function verifyRemoteDmg(
  storage,
  pointerPath,
  localArtifactDir,
  { required, kind = "dmg" }
) {
  const fileName = parsePointer(pointerPath, { required, kind });
  if (!fileName) {
    return;
  }
  const { label } = pointerKinds[kind];

  const localPath = resolve(localArtifactDir, fileName);
  const expectedSize =
    existsSync(localPath) && statSync(localPath).isFile()
      ? statSync(localPath).size
      : undefined;
  const head = headRemoteObject(storage, fileName);

  if (head.size <= 0) {
    throw new Error(`Remote ${label} is empty: ${fileName}`);
  }
  if (expectedSize !== undefined && head.size !== expectedSize) {
    throw new Error(
      `Remote ${label} size mismatch for ${fileName}: expected ${expectedSize}, got ${head.size}`
    );
  }
}

function getContentType(fileName) {
  return fileName.endsWith(".json") ? "application/json" : "text/plain";
}

function uploadMetadataPath(storage, path, fileName) {
  runAws(storage, [
    "s3",
    "cp",
    path,
    getObjectUri(storage, fileName),
    "--content-type",
    getContentType(fileName),
    "--only-show-errors",
  ]);
}

function uploadMetadataFile(storage, releaseDir, fileName, { required }) {
  const path = resolve(releaseDir, fileName);
  if (!existsSync(path)) {
    if (required) {
      throw new Error(`Release metadata not found: ${path}`);
    }
    return;
  }

  uploadMetadataPath(storage, path, fileName);
}

/** Each file of a release directory with its size and modification time. */
function describeReleaseDirectory(releaseDir) {
  return readdirSync(releaseDir)
    .toSorted()
    .map((name) => {
      const stats = statSync(resolve(releaseDir, name));
      return `  ${name} ${stats.isFile() ? `${stats.size} bytes` : "(not a file)"} ${stats.mtime.toISOString()}`;
    })
    .join("\n");
}

async function publishRelease(storage, releaseDir, metadata, { requireDmg }) {
  const feedPath = resolve(releaseDir, metadata.feed);
  if (!existsSync(feedPath)) {
    throw new Error(`Release feed not found: ${feedPath}`);
  }

  const assets = parseReleaseFeed(feedPath);
  const excludedMetadata = [...metadata.active, ...(metadata.excluded ?? [])];
  const syncArguments = [
    "s3",
    "sync",
    releaseDir,
    getObjectUri(storage),
    // Each file it uploads is logged: a release that then misses one shows
    // whether the sync sent it.
    "--no-progress",
  ];
  for (const fileName of excludedMetadata) {
    syncArguments.push("--exclude", fileName);
  }

  // What the sync compares, logged before it runs: on 10-13 and 10-20 it sent
  // every asset but the DMG and exited 0, and the logs could not show whether
  // the DMG was in the release directory or already listed in the bucket.
  console.log(
    `Release directory before the upload:\n${describeReleaseDirectory(releaseDir)}`
  );
  const dmgName = parseDmgPointer(resolve(releaseDir, metadata.dmgPointer), {
    required: false,
  });
  if (dmgName) console.log(listReleaseObjects(storage, dmgName));

  console.log("Uploading release assets before metadata...");
  runAws(storage, syncArguments);

  console.log("Verifying remote release assets...");
  await verifyRemoteFeedAssets(storage, assets, { verifyHashes: false });
  verifyRemoteManifestAssets(
    storage,
    resolve(releaseDir, metadata.manifest),
    releaseDir
  );
  verifyRemoteDmg(storage, resolve(releaseDir, metadata.dmgPointer), releaseDir, {
    required: requireDmg,
  });
  verifyRemoteDmg(storage, resolve(releaseDir, metadata.setupPointer), releaseDir, {
    required: false,
    kind: "setup",
  });

  console.log("Publishing secondary metadata...");
  for (const fileName of metadata.active.slice(0, -1)) {
    uploadMetadataFile(storage, releaseDir, fileName, {
      required: fileName === metadata.dmgPointer && requireDmg,
    });
  }

  const activeFeed = metadata.active.at(-1);
  console.log(`Publishing activation feed last: ${activeFeed}`);
  uploadMetadataFile(storage, releaseDir, activeFeed, { required: true });
}

async function downloadRemoteMetadata(storage, destinationDir, fileName, { required }) {
  if (!required && !headRemoteObject(storage, fileName, { allowMissing: true })) {
    return undefined;
  }

  const destination = resolve(destinationDir, fileName);
  runAws(storage, [
    "s3",
    "cp",
    getObjectUri(storage, fileName),
    destination,
    "--only-show-errors",
  ]);
  return destination;
}

function promoteOptionalMetadataFile(storage, pendingName, activeName) {
  if (!headRemoteObject(storage, pendingName, { allowMissing: true })) {
    return;
  }

  runAws(storage, [
    "s3",
    "cp",
    getObjectUri(storage, pendingName),
    getObjectUri(storage, activeName),
    "--content-type",
    getContentType(activeName),
    "--only-show-errors",
  ]);
}

async function promoteProduction(storage, { requireDmg }) {
  const verificationDir = await mkdtemp(join(tmpdir(), "comma-prod-signoff-"));

  try {
    const pendingFeedName = "releases.prod.pending.json";
    const pendingManifestName = "assets.prod.pending.json";
    const pendingDmgPointerName = "dmg.prod.pending.txt";
    const feedPath = await downloadRemoteMetadata(
      storage,
      verificationDir,
      pendingFeedName,
      { required: true }
    );
    const manifestPath = await downloadRemoteMetadata(
      storage,
      verificationDir,
      pendingManifestName,
      { required: false }
    );
    const dmgPointerPath = await downloadRemoteMetadata(
      storage,
      verificationDir,
      pendingDmgPointerName,
      { required: requireDmg }
    );
    const setupPointerPath = await downloadRemoteMetadata(
      storage,
      verificationDir,
      "setup.prod.pending.txt",
      { required: false }
    );

    console.log("Verifying every package referenced by the pending feed...");
    await verifyRemoteFeedAssets(storage, parseReleaseFeed(feedPath), {
      verifyHashes: true,
    });

    if (manifestPath) {
      for (const fileName of parseAssetManifest(manifestPath)) {
        const head = headRemoteObject(storage, fileName);
        if (head.size <= 0) {
          throw new Error(`Remote release manifest asset is empty: ${fileName}`);
        }
      }
    }
    if (dmgPointerPath) {
      verifyRemoteDmg(storage, dmgPointerPath, verificationDir, { required: true });
    }
    if (setupPointerPath) {
      verifyRemoteDmg(storage, setupPointerPath, verificationDir, {
        required: true,
        kind: "setup",
      });
    }

    console.log("Promoting secondary production metadata...");
    if (manifestPath) {
      uploadMetadataPath(storage, manifestPath, "assets.prod.json");
    }
    promoteOptionalMetadataFile(storage, "RELEASES-prod.pending", "RELEASES-prod");
    if (dmgPointerPath) uploadMetadataPath(storage, dmgPointerPath, "dmg.prod.txt");
    if (setupPointerPath)
      uploadMetadataPath(storage, setupPointerPath, "setup.prod.txt");

    console.log("Promoting the active production feed last...");
    uploadMetadataPath(storage, feedPath, "releases.prod.json");
  } finally {
    await rm(verificationDir, { recursive: true, force: true });
  }
}

async function main() {
  const [command, ...values] = process.argv.slice(2);
  const options = parseOptions(values);
  const storage = getStorage(options);

  // A Windows feed has no DMG (`--dmg none`); a macOS one must.
  const requireDmg = options.get("--dmg") !== "none";

  if (command === "publish-staging") {
    await publishRelease(
      storage,
      resolve(requireOption(options, "--release-dir")),
      channelMetadata.staging,
      { requireDmg }
    );
    return;
  }

  if (command === "publish-production-pending") {
    await publishRelease(
      storage,
      resolve(requireOption(options, "--release-dir")),
      channelMetadata["prod-pending"],
      { requireDmg }
    );
    return;
  }

  if (command === "promote-production") {
    await promoteProduction(storage, { requireDmg });
    return;
  }

  throw new Error(
    "Usage: release-storage.mjs <publish-staging|publish-production-pending|promote-production> --endpoint <url> --bucket <name> --prefix <path> [--release-dir <path>] [--dmg required|none]"
  );
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : error);
  process.exitCode = 1;
});
