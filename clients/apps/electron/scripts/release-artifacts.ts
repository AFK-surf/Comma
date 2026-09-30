import { createHash } from "node:crypto";
import {
  createReadStream,
  existsSync,
  readFileSync,
  readdirSync,
  renameSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { basename, resolve } from "node:path";

interface ReleaseFeedAsset {
  FileName: string;
  SHA1: string;
  SHA256: string;
  Size: number;
  Type: string;
  Version: string;
}

interface ReleaseAssetManifestEntry {
  RelativeFileName: string;
  Type: string;
}

export function getReleaseArtifactBaseName(packVersion: string) {
  return `Comma-${packVersion}`;
}

export function getDmgArtifactName({ packVersion }: { packVersion: string }) {
  return `${getReleaseArtifactBaseName(packVersion)}.dmg`;
}

function updateJsonFile(path: string, renamedFiles: Map<string, string>) {
  if (!existsSync(path)) {
    return;
  }

  const replaceReferences = (value: unknown): unknown => {
    if (typeof value === "string") {
      return renamedFiles.get(value) ?? value;
    }

    if (Array.isArray(value)) {
      return value.map((entry) => replaceReferences(entry));
    }

    if (value && typeof value === "object") {
      return Object.fromEntries(
        Object.entries(value).map(([key, entry]) => [key, replaceReferences(entry)])
      );
    }

    return value;
  };

  const json = JSON.parse(readFileSync(path, "utf-8")) as unknown;
  writeFileSync(path, `${JSON.stringify(replaceReferences(json))}\n`);
}

function updateTextFile(path: string, renamedFiles: Map<string, string>) {
  if (!existsSync(path)) {
    return;
  }

  let content = readFileSync(path, "utf-8");

  for (const [from, to] of renamedFiles) {
    content = content.replaceAll(from, to);
  }

  writeFileSync(path, content);
}

function getNormalizedArtifactName(fileName: string, packVersion: string) {
  const baseName = getReleaseArtifactBaseName(packVersion);

  if (fileName.endsWith("-full.nupkg") && fileName.includes(packVersion)) {
    return `${baseName}-full.nupkg`;
  }

  if (fileName.endsWith("-delta.nupkg") && fileName.includes(packVersion)) {
    return `${baseName}-delta.nupkg`;
  }

  if (fileName.endsWith(".nupkg") && fileName.includes(packVersion)) {
    throw new Error(
      `Cannot normalize Velopack package without a full/delta suffix: ${fileName}`
    );
  }

  if (
    fileName.endsWith("-Portable.zip") ||
    (fileName.endsWith(".zip") && fileName.includes(packVersion))
  ) {
    return `${baseName}.zip`;
  }

  if (fileName.endsWith(".dmg") && fileName.includes(packVersion)) {
    return `${baseName}.dmg`;
  }

  return undefined;
}

export function normalizeReleaseArtifactNames({
  releaseOutputDir,
  packVersion,
  releaseChannel,
}: {
  releaseOutputDir: string;
  packVersion: string;
  releaseChannel: string;
}) {
  const renamedFiles = new Map<string, string>();
  const normalizedSources = new Map<string, string>();
  const directoryEntries = readdirSync(releaseOutputDir);

  for (const fileName of directoryEntries) {
    const normalizedName = getNormalizedArtifactName(fileName, packVersion);

    if (!normalizedName || normalizedName === fileName) {
      continue;
    }

    const existingSource = normalizedSources.get(normalizedName);
    if (existingSource) {
      throw new Error(
        `Release artifact name collision: ${existingSource} and ${fileName} both normalize to ${normalizedName}`
      );
    }

    normalizedSources.set(normalizedName, fileName);
    renamedFiles.set(fileName, normalizedName);
  }

  for (const normalizedName of renamedFiles.values()) {
    if (
      directoryEntries.includes(normalizedName) &&
      !renamedFiles.has(normalizedName)
    ) {
      throw new Error(
        `Release artifact already exists and would be overwritten: ${normalizedName}`
      );
    }
  }

  for (const [fileName, normalizedName] of renamedFiles) {
    renameSync(
      resolve(releaseOutputDir, fileName),
      resolve(releaseOutputDir, normalizedName)
    );
  }

  if (renamedFiles.size === 0) {
    return;
  }

  updateJsonFile(
    resolve(releaseOutputDir, `releases.${releaseChannel}.json`),
    renamedFiles
  );
  updateJsonFile(
    resolve(releaseOutputDir, `assets.${releaseChannel}.json`),
    renamedFiles
  );
  updateTextFile(resolve(releaseOutputDir, `RELEASES-${releaseChannel}`), renamedFiles);
  updateTextFile(resolve(releaseOutputDir, `dmg.${releaseChannel}.txt`), renamedFiles);
}

function readJson(path: string) {
  try {
    return JSON.parse(readFileSync(path, "utf-8")) as unknown;
  } catch (error) {
    throw new Error(`Invalid release metadata JSON: ${path}`, { cause: error });
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function parseReleaseFeedAssets(path: string): ReleaseFeedAsset[] {
  const feed = readJson(path);
  if (!isRecord(feed) || !Array.isArray(feed.Assets)) {
    throw new Error(`Release feed must contain an Assets array: ${path}`);
  }

  return feed.Assets.map((value, index) => {
    if (
      !isRecord(value) ||
      typeof value.FileName !== "string" ||
      typeof value.Type !== "string" ||
      typeof value.Version !== "string" ||
      typeof value.Size !== "number" ||
      typeof value.SHA1 !== "string" ||
      typeof value.SHA256 !== "string"
    ) {
      throw new Error(`Invalid release asset at Assets[${index}]: ${path}`);
    }

    return {
      FileName: value.FileName,
      Type: value.Type,
      Version: value.Version,
      Size: value.Size,
      SHA1: value.SHA1,
      SHA256: value.SHA256,
    };
  });
}

function parseReleaseAssetManifest(path: string): ReleaseAssetManifestEntry[] {
  const manifest = readJson(path);
  if (!Array.isArray(manifest)) {
    throw new Error(`Release asset manifest must be an array: ${path}`);
  }

  return manifest.map((value, index) => {
    if (
      !isRecord(value) ||
      typeof value.RelativeFileName !== "string" ||
      typeof value.Type !== "string"
    ) {
      throw new Error(`Invalid release asset manifest entry at [${index}]: ${path}`);
    }

    return {
      RelativeFileName: value.RelativeFileName,
      Type: value.Type,
    };
  });
}

function assertLocalArtifactPath(fileName: string, metadataPath: string) {
  if (!fileName || basename(fileName) !== fileName) {
    throw new Error(
      `Release metadata must reference a local artifact filename: ${fileName} (${metadataPath})`
    );
  }
}

async function getFileHashes(path: string) {
  const sha1 = createHash("sha1");
  const sha256 = createHash("sha256");

  for await (const chunk of createReadStream(path)) {
    sha1.update(chunk);
    sha256.update(chunk);
  }

  return {
    sha1: sha1.digest("hex").toUpperCase(),
    sha256: sha256.digest("hex").toUpperCase(),
  };
}

export async function validateReleaseArtifacts({
  releaseOutputDir,
  releaseChannel,
  packVersion,
}: {
  releaseOutputDir: string;
  releaseChannel: string;
  packVersion: string;
}) {
  const feedPath = resolve(releaseOutputDir, `releases.${releaseChannel}.json`);
  if (!existsSync(feedPath)) {
    throw new Error(`Release feed not found: ${feedPath}`);
  }

  const feedAssets = parseReleaseFeedAssets(feedPath);
  const feedAssetsByName = new Map<string, ReleaseFeedAsset>();
  const currentFullAssets = feedAssets.filter(
    (asset) => asset.Version === packVersion && asset.Type === "Full"
  );
  if (currentFullAssets.length !== 1) {
    throw new Error(
      `Release feed must contain exactly one Full asset for ${packVersion}; found ${currentFullAssets.length}`
    );
  }

  for (const asset of feedAssets) {
    assertLocalArtifactPath(asset.FileName, feedPath);

    const duplicate = feedAssetsByName.get(asset.FileName);
    if (duplicate) {
      throw new Error(
        `Release feed filename collision: ${asset.FileName} is used by ${duplicate.Type} and ${asset.Type}`
      );
    }

    const artifactPath = resolve(releaseOutputDir, asset.FileName);
    if (!existsSync(artifactPath) || !statSync(artifactPath).isFile()) {
      throw new Error(`Release feed artifact not found: ${artifactPath}`);
    }

    const size = statSync(artifactPath).size;
    if (size !== asset.Size) {
      throw new Error(
        `Release artifact size mismatch for ${asset.FileName}: expected ${asset.Size}, got ${size}`
      );
    }

    feedAssetsByName.set(asset.FileName, asset);
  }

  for (const asset of feedAssets) {
    const artifactPath = resolve(releaseOutputDir, asset.FileName);
    const hashes = await getFileHashes(artifactPath);

    if (hashes.sha1 !== asset.SHA1.toUpperCase()) {
      throw new Error(`Release artifact SHA1 mismatch: ${asset.FileName}`);
    }
    if (hashes.sha256 !== asset.SHA256.toUpperCase()) {
      throw new Error(`Release artifact SHA256 mismatch: ${asset.FileName}`);
    }
  }

  const manifestPath = resolve(releaseOutputDir, `assets.${releaseChannel}.json`);
  if (existsSync(manifestPath)) {
    const manifestEntries = parseReleaseAssetManifest(manifestPath);
    const manifestEntriesByName = new Map<string, ReleaseAssetManifestEntry>();

    for (const entry of manifestEntries) {
      assertLocalArtifactPath(entry.RelativeFileName, manifestPath);

      const duplicate = manifestEntriesByName.get(entry.RelativeFileName);
      if (duplicate) {
        throw new Error(
          `Release asset manifest filename collision: ${entry.RelativeFileName} is used by ${duplicate.Type} and ${entry.Type}`
        );
      }

      const artifactPath = resolve(releaseOutputDir, entry.RelativeFileName);
      if (!existsSync(artifactPath) || !statSync(artifactPath).isFile()) {
        throw new Error(`Release asset manifest artifact not found: ${artifactPath}`);
      }

      if (entry.RelativeFileName.endsWith(".nupkg")) {
        const feedAsset = feedAssetsByName.get(entry.RelativeFileName);
        if (!feedAsset || feedAsset.Type !== entry.Type) {
          throw new Error(
            `Release asset manifest does not match the feed: ${entry.RelativeFileName} (${entry.Type})`
          );
        }
      }

      manifestEntriesByName.set(entry.RelativeFileName, entry);
    }

    for (const asset of feedAssets) {
      if (asset.Version === packVersion && !manifestEntriesByName.has(asset.FileName)) {
        throw new Error(
          `Current release feed artifact is missing from the asset manifest: ${asset.FileName}`
        );
      }
    }
  }

  const dmgPointerPath = resolve(releaseOutputDir, `dmg.${releaseChannel}.txt`);
  if (existsSync(dmgPointerPath)) {
    const dmgName = readFileSync(dmgPointerPath, "utf-8").trim();
    assertLocalArtifactPath(dmgName, dmgPointerPath);

    const dmgPath = resolve(releaseOutputDir, dmgName);
    if (
      !dmgName.endsWith(".dmg") ||
      !existsSync(dmgPath) ||
      !statSync(dmgPath).isFile()
    ) {
      throw new Error(`DMG pointer artifact not found: ${dmgPath}`);
    }
  }
}
