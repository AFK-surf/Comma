import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

interface StableVersion {
  major: number;
  minor: number;
  patch: number;
}

interface PackageJson {
  version?: string;
}

const appDir = resolve(import.meta.dirname, "..");
const packageJson = JSON.parse(
  readFileSync(resolve(appDir, "package.json"), "utf-8")
) as PackageJson;

function git(args: string[]) {
  return execFileSync("git", args, {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  }).trim();
}

function parseStableTag(tag: string): StableVersion | undefined {
  return parseStableVersion(tag.replace(/^v/, ""));
}

function parseStableVersion(version: string): StableVersion | undefined {
  const match = version.match(/^(\d+)\.(\d+)\.(\d+)$/);

  if (!match) {
    return undefined;
  }

  const [, major, minor, patch] = match;

  if (!major || !minor || !patch) {
    return undefined;
  }

  return {
    major: Number.parseInt(major, 10),
    minor: Number.parseInt(minor, 10),
    patch: Number.parseInt(patch, 10),
  };
}

function findLatestStableTag() {
  const tags = git(["tag", "--merged", "HEAD", "--sort=-v:refname"])
    .split("\n")
    .map((tag) => tag.trim())
    .filter(Boolean);

  return tags.find((tag) => parseStableTag(tag));
}

function nextPatchVersion(version: StableVersion) {
  return `${version.major}.${version.minor}.${version.patch + 1}`;
}

function parseStagingRunNumber(value: string | undefined) {
  if (!value) {
    throw new Error("GITHUB_RUN_NUMBER is required for staging release versions.");
  }

  if (!/^[1-9]\d*$/.test(value)) {
    throw new Error(`Invalid staging run number: ${value}`);
  }

  return value;
}

function resolveStagingReleaseVersion({
  baseVersion,
  runNumber,
}: {
  baseVersion: string;
  runNumber: string | undefined;
}) {
  if (!parseStableVersion(baseVersion)) {
    throw new Error(`Invalid base staging version: ${baseVersion || "<missing>"}`);
  }

  const stagingBuild = parseStagingRunNumber(runNumber);
  const version = `${baseVersion}-staging.${stagingBuild}`;

  return {
    build: stagingBuild,
    tag: `v${version}`,
    version,
  };
}

function currentPackageVersion() {
  const version = packageJson.version ?? "";

  if (!parseStableVersion(version)) {
    throw new Error(`Invalid Electron package version: ${version || "<missing>"}`);
  }

  return version;
}

async function main() {
  const latestStableTag = findLatestStableTag();
  const latestStableVersion = latestStableTag
    ? parseStableTag(latestStableTag)
    : undefined;
  const baseVersion =
    latestStableTag && latestStableVersion
      ? nextPatchVersion(latestStableVersion)
      : currentPackageVersion();
  const { build, tag, version } = resolveStagingReleaseVersion({
    baseVersion,
    runNumber: process.env.GITHUB_RUN_NUMBER,
  });

  console.log(`latest stable release tag: ${latestStableTag ?? "<none>"}`);
  console.log(`base staging version: ${baseVersion}`);
  console.log(`staging run number: ${build}`);
  console.log(`resolved staging version: ${version}`);
  console.log(`resolved staging tag: ${tag}`);

  const githubOutput = process.env.GITHUB_OUTPUT;
  if (githubOutput) {
    await import("node:fs/promises").then(({ appendFile }) =>
      appendFile(githubOutput, `version=${version}\ntag=${tag}\nbuild=${build}\n`)
    );
  }
}

main().catch((error: unknown) => {
  console.error(error);
  process.exit(1);
});
