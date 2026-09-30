import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync } from "node:fs";
import { basename, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { getPackableReleaseConfig } from "../src/release-config";

interface ReleaseAsset {
  FileName: string;
  Type: string;
  Version: string;
}

interface ParsedVersion {
  major: number;
  minor: number;
  patch: number;
  stagingBuild: number;
}

const appDir = resolve(import.meta.dirname, "..");
const releaseConfig = getPackableReleaseConfig();
const feedDir = resolve(
  appDir,
  process.env.COMMA_RELEASES_DIR ?? "Releases",
  releaseConfig.releaseChannel
);
const metadataFiles = [
  `releases.${releaseConfig.releaseChannel}.json`,
  `assets.${releaseConfig.releaseChannel}.json`,
  `RELEASES-${releaseConfig.releaseChannel}`,
  `dmg.${releaseConfig.releaseChannel}.txt`,
];

function requiredEnv(name: string) {
  const value = process.env[name]?.trim();
  if (!value) {
    throw new Error(`${name} is required.`);
  }
  return value;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function isReleaseAsset(value: unknown): value is ReleaseAsset {
  return (
    isRecord(value) &&
    typeof value.FileName === "string" &&
    typeof value.Type === "string" &&
    typeof value.Version === "string"
  );
}

function parseVersion(version: string): ParsedVersion | undefined {
  const match = version.match(/^(\d+)\.(\d+)\.(\d+)(?:-staging\.(\d+))?$/);
  if (!match) {
    return undefined;
  }

  const [, major, minor, patch, stagingBuild] = match;
  if (!major || !minor || !patch) {
    return undefined;
  }

  return {
    major: Number.parseInt(major, 10),
    minor: Number.parseInt(minor, 10),
    patch: Number.parseInt(patch, 10),
    stagingBuild: stagingBuild ? Number.parseInt(stagingBuild, 10) : 0,
  };
}

function compareVersion(left: ParsedVersion, right: ParsedVersion) {
  return (
    left.major - right.major ||
    left.minor - right.minor ||
    left.patch - right.patch ||
    left.stagingBuild - right.stagingBuild
  );
}

export function findLatestFullNupkg(feed: unknown) {
  if (!isRecord(feed) || !Array.isArray(feed.Assets)) {
    return undefined;
  }

  return feed.Assets.map((asset) => {
    if (!isReleaseAsset(asset)) {
      return undefined;
    }

    const version = parseVersion(asset.Version);
    if (
      asset.Type !== "Full" ||
      !asset.FileName.endsWith(".nupkg") ||
      basename(asset.FileName) !== asset.FileName ||
      !version
    ) {
      return undefined;
    }

    return {
      fileName: asset.FileName,
      version,
    };
  })
    .filter((asset) => asset !== undefined)
    .toSorted((left, right) => compareVersion(right.version, left.version))[0]
    ?.fileName;
}

function runAwsCp({
  endpoint,
  from,
  to,
  required,
}: {
  endpoint: string;
  from: string;
  to: string;
  required: boolean;
}) {
  const result = spawnSync("aws", ["--endpoint-url", endpoint, "s3", "cp", from, to], {
    stdio: "inherit",
  });

  if (result.error) {
    throw result.error;
  }

  if (result.status !== 0 && required) {
    throw new Error(`aws s3 cp failed for ${from}`);
  }

  if (result.status !== 0) {
    console.warn(`Optional release feed object was not downloaded: ${from}`);
  }
}

function readExistingReleaseFeed() {
  const feedPath = resolve(feedDir, `releases.${releaseConfig.releaseChannel}.json`);
  if (!existsSync(feedPath)) {
    return undefined;
  }

  return JSON.parse(readFileSync(feedPath, "utf-8")) as unknown;
}

export function downloadExistingReleaseFeed() {
  const accountId = requiredEnv("CLOUDFLARE_R2_ACCOUNT_ID");
  const bucket = requiredEnv("CLOUDFLARE_R2_BUCKET");
  const prefix = requiredEnv("R2_PATH_PREFIX").replace(/^\/+|\/+$/g, "");
  const endpoint = `https://${accountId}.r2.cloudflarestorage.com`;
  const r2Uri = `s3://${bucket}/${prefix}`;

  mkdirSync(feedDir, { recursive: true });

  for (const metadata of metadataFiles) {
    runAwsCp({
      endpoint,
      from: `${r2Uri}/${metadata}`,
      to: resolve(feedDir, metadata),
      required: false,
    });
  }

  const latestNupkg = findLatestFullNupkg(readExistingReleaseFeed());
  if (!latestNupkg) {
    console.log(`No previous ${releaseConfig.releaseChannel} full package found.`);
    return;
  }

  runAwsCp({
    endpoint,
    from: `${r2Uri}/${latestNupkg}`,
    to: resolve(feedDir, latestNupkg),
    required: true,
  });
}

async function main() {
  downloadExistingReleaseFeed();
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error: unknown) => {
    console.error(error);
    process.exit(1);
  });
}
