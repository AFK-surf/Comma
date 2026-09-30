import { lstat, mkdir, mkdtemp, readdir, rename, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

import { x as extractTar } from "tar";

export type TemporarySourceSnapshot = {
  root: string;
  [Symbol.asyncDispose](): Promise<void>;
};

export async function createGitSourceSnapshot(
  repository: string,
  revision: string
): Promise<TemporarySourceSnapshot> {
  const temporaryRoot = await mkdtemp(
    path.join(os.tmpdir(), "evalens-teambench-source-")
  );
  const archivePath = path.join(temporaryRoot, "source.tar");
  const snapshotRoot = path.join(temporaryRoot, "source");
  try {
    await mkdir(snapshotRoot);
    await runChecked([
      "git",
      "-C",
      repository,
      "archive",
      "--format=tar",
      `--output=${archivePath}`,
      revision,
    ]);
    await extractTar({ cwd: snapshotRoot, file: archivePath, strict: true });
    await assertNoSymbolicLinks(snapshotRoot);
  } catch (error) {
    await rm(temporaryRoot, { recursive: true, force: true });
    throw error;
  }

  return {
    root: snapshotRoot,
    async [Symbol.asyncDispose]() {
      await rm(temporaryRoot, { recursive: true, force: true });
    },
  };
}

export async function assertNoSymbolicLinks(root: string): Promise<void> {
  for (const entry of await readdir(root, { withFileTypes: true })) {
    const entryPath = path.join(root, entry.name);
    if (entry.isSymbolicLink()) {
      throw new Error(`TeamBench build input contains a symbolic link: ${entryPath}`);
    }
    if (entry.isDirectory()) await assertNoSymbolicLinks(entryPath);
  }
}

export async function publishDatasetBuild(
  stagedDirectory: string,
  outputDirectory: string
): Promise<void> {
  const outputParent = path.dirname(outputDirectory);
  await mkdir(outputParent, { recursive: true });
  const backupRoot = await mkdtemp(
    path.join(outputParent, `.${path.basename(outputDirectory)}-previous-`)
  );
  await mkdir(outputDirectory, { recursive: true });

  const replacements = ["items", "dataset.json"] as const;
  const movedExisting: string[] = [];
  const installed: string[] = [];
  try {
    for (const name of replacements) {
      const destination = path.join(outputDirectory, name);
      if (await pathExists(destination)) {
        await rename(destination, path.join(backupRoot, name));
        movedExisting.push(name);
      }
      await rename(path.join(stagedDirectory, name), destination);
      installed.push(name);
    }
  } catch (error) {
    for (const name of installed.reverse()) {
      await rm(path.join(outputDirectory, name), { recursive: true, force: true });
    }
    for (const name of movedExisting.reverse()) {
      await rename(path.join(backupRoot, name), path.join(outputDirectory, name));
    }
    throw error;
  } finally {
    await rm(backupRoot, { recursive: true, force: true });
  }
}

export async function runChecked(command: string[], cwd?: string): Promise<string> {
  const child = Bun.spawn(command, {
    cwd,
    stdout: "pipe",
    stderr: "pipe",
    env: process.env,
  });
  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
    child.exited,
  ]);
  if (exitCode !== 0) {
    throw new Error(
      `${command[0]} failed (${exitCode}): ${stderr.trim() || stdout.trim()}`
    );
  }
  return stdout;
}

async function pathExists(filePath: string): Promise<boolean> {
  try {
    await lstat(filePath);
    return true;
  } catch (error) {
    if (error instanceof Error && "code" in error && error.code === "ENOENT") {
      return false;
    }
    throw error;
  }
}
