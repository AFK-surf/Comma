import { mkdir } from "node:fs/promises";
import path from "node:path";

import type { DatasetItemArchive } from "@evalens/core";

export type ArchivedFile = {
  path: string;
  data: Uint8Array;
};

export async function readArchiveFiles(
  archive: DatasetItemArchive | Bun.Archive
): Promise<ArchivedFile[]> {
  const files: ArchivedFile[] = [];
  for (const [filePath, file] of await archive.files()) {
    const normalized = normalizedArchivePath(filePath);
    files.push({ path: normalized, data: await file.bytes() });
  }
  return files.sort((left, right) => left.path.localeCompare(right.path));
}

export function requireArchiveFile(
  files: readonly ArchivedFile[],
  filePath: string
): ArchivedFile {
  const normalized = normalizedArchivePath(filePath);
  const file = files.find((candidate) => candidate.path === normalized);
  if (!file) throw new Error(`archive file is missing: ${normalized}`);
  return file;
}

export function filesUnder(
  files: readonly ArchivedFile[],
  root: string
): ArchivedFile[] {
  const normalizedRoot = normalizedArchivePath(root).replace(/\/+$/u, "");
  const prefix = `${normalizedRoot}/`;
  return files
    .filter((file) => file.path.startsWith(prefix))
    .map((file) => ({ path: file.path.slice(prefix.length), data: file.data }));
}

export async function writeFiles(
  root: string,
  files: readonly ArchivedFile[]
): Promise<void> {
  const resolvedRoot = path.resolve(root);
  await mkdir(resolvedRoot, { recursive: true });
  for (const file of files) {
    const relativePath = normalizedArchivePath(file.path);
    const destination = path.resolve(resolvedRoot, ...relativePath.split("/"));
    if (
      destination !== resolvedRoot &&
      !destination.startsWith(`${resolvedRoot}${path.sep}`)
    ) {
      throw new Error(`archive path escapes output root: ${file.path}`);
    }
    await mkdir(path.dirname(destination), { recursive: true });
    await Bun.write(destination, file.data);
  }
}

export async function collectLocalFiles(
  root: string,
  archiveRoot: string
): Promise<ArchivedFile[]> {
  const files: ArchivedFile[] = [];
  const glob = new Bun.Glob("**/*");
  for await (const relativePath of glob.scan({
    cwd: root,
    onlyFiles: true,
    dot: true,
  })) {
    const archivePath = path.posix.join(
      normalizedArchivePath(archiveRoot),
      relativePath.split(path.sep).join(path.posix.sep)
    );
    files.push({
      path: archivePath,
      data: await Bun.file(path.join(root, relativePath)).bytes(),
    });
  }
  return files.sort((left, right) => left.path.localeCompare(right.path));
}

export function archiveFromFiles(
  files: readonly ArchivedFile[]
): Bun.Archive | undefined {
  const entries: Record<string, Uint8Array> = {};
  for (const file of files) {
    const filePath = normalizedArchivePath(file.path);
    if (Object.hasOwn(entries, filePath)) {
      throw new Error(`duplicate artifact path: ${filePath}`);
    }
    entries[filePath] = file.data;
  }
  return Object.keys(entries).length > 0 ? new Bun.Archive(entries) : undefined;
}

export function normalizedArchivePath(filePath: string): string {
  const normalized = filePath.replaceAll("\\", "/").replace(/^\/+/u, "");
  const segments = normalized.split("/");
  if (
    !normalized ||
    normalized.includes("\0") ||
    segments.some((segment) => !segment || segment === "." || segment === "..")
  ) {
    throw new Error(`invalid archive path: ${filePath}`);
  }
  return normalized;
}
