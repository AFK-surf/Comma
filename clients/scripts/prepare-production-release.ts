#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import { readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import path from "node:path";
import readline from "node:readline/promises";
import { stdin as input, stdout as output } from "node:process";
import { fileURLToPath } from "node:url";

interface PackageJson {
  version?: string;
  [key: string]: unknown;
}

interface VersionedPackage {
  file: string;
  packageJson: PackageJson & { version: string };
}

type BumpKind = "patch" | "minor" | "major";

const clientsRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const repoRoot = path.resolve(clientsRoot, "..");

assertCleanWorktree();

const versionedPackages = readVersionedPackages();
const packageVersion = assertSingleCurrentVersion(versionedPackages);
const selectedBump = await promptForBump(packageVersion);
const nextVersion = bumpVersion(packageVersion, selectedBump);
const releaseTag = `v${nextVersion}`;
const releaseBranch = currentBranch();

assertTagAvailable(releaseTag);
writePackageVersions(versionedPackages, nextVersion);

try {
  git(["add", ...versionedPackages.map((pkg) => path.relative(repoRoot, pkg.file))]);
  git(["commit", "-m", `Release ${releaseTag}`]);
  git(["tag", releaseTag]);
  git(["push", "origin", `HEAD:${releaseBranch}`]);
  git(["push", "origin", `refs/tags/${releaseTag}`]);
} catch (error) {
  console.error(
    "\nRelease preparation failed after modifying git state. Inspect `git status` before retrying."
  );
  throw error;
}

console.log(`\nPrepared and pushed ${releaseTag}.`);

function git(args: string[], options: { stdio?: "pipe" | "inherit" } = {}) {
  return execFileSync("git", args, {
    cwd: repoRoot,
    encoding: "utf8",
    stdio: options.stdio ?? ["ignore", "pipe", "pipe"],
  }).trim();
}

function assertCleanWorktree() {
  const status = git(["status", "--porcelain=v1"]);

  if (status) {
    console.error("Release preparation must run from a clean worktree.");
    console.error(status);
    process.exit(1);
  }
}

function readVersionedPackages(): VersionedPackage[] {
  const files = findPackageJsonFiles(clientsRoot);
  const foundPackages: VersionedPackage[] = [];

  for (const file of files) {
    const raw = readFileSync(file, "utf8");
    const packageJson = JSON.parse(raw) as PackageJson;

    if (!Object.hasOwn(packageJson, "version")) {
      continue;
    }

    if (!packageJson.version || !/^\d+\.\d+\.\d+$/.test(packageJson.version)) {
      throw new Error(
        `${path.relative(repoRoot, file)} has invalid version ${packageJson.version}`
      );
    }

    foundPackages.push({
      file,
      packageJson: packageJson as PackageJson & { version: string },
    });
  }

  if (foundPackages.length === 0) {
    throw new Error("No package.json files with stable versions were found.");
  }

  return foundPackages;
}

function assertSingleCurrentVersion(packageList: VersionedPackage[]) {
  const versions = new Set(packageList.map((pkg) => pkg.packageJson.version));

  if (versions.size !== 1) {
    throw new Error(
      `Package versions are not aligned: ${Array.from(versions).toSorted().join(", ")}`
    );
  }

  return packageList[0]!.packageJson.version;
}

async function promptForBump(version: string): Promise<BumpKind> {
  const rl = readline.createInterface({ input, output });

  try {
    while (true) {
      const answer = (
        await rl.question(
          `Current version is ${version}. Bump which part? [patch/minor/major] `
        )
      )
        .trim()
        .toLowerCase();

      if (answer === "patch" || answer === "minor" || answer === "major") {
        return answer;
      }

      console.log("Please enter patch, minor, or major.");
    }
  } finally {
    rl.close();
  }
}

function bumpVersion(version: string, bumpKind: BumpKind) {
  const [major = 0, minor = 0, patch = 0] = version
    .split(".")
    .map((part) => Number(part));

  if (bumpKind === "major") {
    return `${major + 1}.0.0`;
  }

  if (bumpKind === "minor") {
    return `${major}.${minor + 1}.0`;
  }

  return `${major}.${minor}.${patch + 1}`;
}

function assertTagAvailable(tagName: string) {
  try {
    git(["rev-parse", "-q", "--verify", `refs/tags/${tagName}`]);
    throw new Error(`Tag ${tagName} already exists locally.`);
  } catch (error) {
    if (error instanceof Error && error.message.includes("already exists locally")) {
      throw error;
    }
    // git exits non-zero when the tag is absent, which is the expected path.
  }

  const remoteTag = git(["ls-remote", "--tags", "origin", tagName]);

  if (remoteTag) {
    throw new Error(`Tag ${tagName} already exists on origin.`);
  }
}

function writePackageVersions(packageList: VersionedPackage[], version: string) {
  for (const pkg of packageList) {
    pkg.packageJson.version = version;
    writeFileSync(pkg.file, `${JSON.stringify(pkg.packageJson, null, 2)}\n`);
    console.log(`set ${path.relative(repoRoot, pkg.file)} to ${version}`);
  }
}

function currentBranch() {
  const branchName = git(["symbolic-ref", "--short", "HEAD"]);

  if (!branchName) {
    throw new Error("Release preparation must run on a branch, not detached HEAD.");
  }

  return branchName;
}

function findPackageJsonFiles(root: string): string[] {
  const files: string[] = [];

  for (const entry of readdirSync(root)) {
    if (entry === "node_modules" || entry === ".git") {
      continue;
    }

    const fullPath = path.join(root, entry);
    const stats = statSync(fullPath);

    if (stats.isDirectory()) {
      files.push(...findPackageJsonFiles(fullPath));
      continue;
    }

    if (entry === "package.json") {
      files.push(fullPath);
    }
  }

  return files.toSorted();
}
