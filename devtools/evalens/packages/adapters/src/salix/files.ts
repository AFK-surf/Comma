import { mkdir } from "node:fs/promises";
import { dirname, resolve, sep } from "node:path";
import { isHttpMiss, type SalixClient } from "./client";
import { salixAgentWorkspaceFileListSchema, salixJsonSchema } from "./protocol";
import type { Salix } from "./types";
const DEFAULT_DOWNLOAD_MAX_FILES = 500,
  DEFAULT_DOWNLOAD_MAX_DEPTH = 16,
  DEFAULT_DOWNLOAD_MAX_TOTAL_BYTES = 64 * 1024 * 1024;
export class SalixFilesService {
  constructor(private readonly client: SalixClient) {}
  async writeAgentFile(
    input: Salix.AgentFileWriteInput
  ): Promise<Salix.AgentFileWriteArtifact> {
    const path = input.path;
    const response = await this.client.fetchImpl(
      this.client.urlFor(agentFilesRoute(input.agentId, path)),
      {
        method: "PUT",
        headers: this.client.headers({
          accept: "application/json",
        }),
        body: agentFileBody(input.data),
      }
    );

    if (!response.ok) {
      const body = await response.text();
      throw new Error(`Salix HTTP ${response.status} PUT agent file ${path}: ${body}`);
    }

    salixJsonSchema.parse(await response.json());
    return {
      agentId: input.agentId,
      path,
    };
  }

  async listAgentFiles(
    input: Salix.AgentFileListInput
  ): Promise<Salix.AgentWorkspaceFileEntry[]> {
    const path = input.path ?? "/";
    const files = await this.client.request(agentFilesRoute(input.agentId, path), {
      allowStatuses: [404],
      schema: salixAgentWorkspaceFileListSchema,
    });

    if (isHttpMiss(files)) {
      return [];
    }
    return files;
  }

  async readAgentFile(
    input: Salix.AgentFileReadInput
  ): Promise<Salix.AgentFileReadArtifact> {
    const path = input.path;
    const response = await this.client.fetchImpl(
      this.client.urlFor(agentFilesRoute(input.agentId, path)),
      {
        method: "GET",
        headers: this.client.headers({ accept: "*/*" }),
      }
    );

    if (!response.ok) {
      const body = await response.text();
      throw new Error(`Salix HTTP ${response.status} GET agent file ${path}: ${body}`);
    }

    return {
      agentId: input.agentId,
      path,
      data: new Uint8Array(await response.arrayBuffer()),
      contentType: response.headers.get("content-type") ?? undefined,
    };
  }

  async downloadAgentFiles(
    input: Salix.AgentFilesDownloadInput
  ): Promise<Salix.AgentFilesDownloadArtifact> {
    const rootPath = input.path ?? "/";
    assertAgentFilePath(rootPath);
    const maxFiles = input.maxFiles ?? DEFAULT_DOWNLOAD_MAX_FILES;
    const maxDepth = input.maxDepth ?? DEFAULT_DOWNLOAD_MAX_DEPTH;
    const maxTotalBytes = input.maxTotalBytes ?? DEFAULT_DOWNLOAD_MAX_TOTAL_BYTES;
    const queue: Array<{ path: string; depth: number }> = [
      { path: rootPath, depth: 0 },
    ];
    const seenDirectories = new Set<string>();
    const directories: Salix.AgentFilesDownloadArtifact["directories"] = [];
    const files: Salix.AgentFilesDownloadArtifact["files"] = [];
    const errors: Salix.AgentFilesDownloadError[] = [];
    let totalBytes = 0;
    let truncated = false;

    while (queue.length > 0) {
      const current = queue.shift()!;
      if (seenDirectories.has(current.path)) {
        continue;
      }
      seenDirectories.add(current.path);

      let entries: Salix.AgentWorkspaceFileEntry[];
      try {
        entries = await this.listAgentFiles({
          agentId: input.agentId,
          path: current.path,
        });
      } catch (error) {
        errors.push({
          path: current.path,
          message: error instanceof Error ? error.message : String(error),
        });
        continue;
      }

      for (const entry of entries) {
        let entryPath: string;
        try {
          entryPath =
            entry.kind === "dir" ? normalizeAgentDirectoryPath(entry.path) : entry.path;
          assertAgentFilePath(entryPath);
        } catch (error) {
          errors.push({
            path: entry.path,
            message: error instanceof Error ? error.message : String(error),
            source: entry,
          });
          continue;
        }

        if (entry.kind === "dir") {
          directories.push({
            agentId: input.agentId,
            path: entryPath,
            relativePath: relativeAgentFilePath(rootPath, entryPath),
            kind: "dir",
            source: entry,
          });
          if (current.depth >= maxDepth) {
            truncated = true;
            errors.push({
              path: entryPath,
              message: `maxDepth ${maxDepth} reached`,
              source: entry,
            });
            continue;
          }
          queue.push({ path: entryPath, depth: current.depth + 1 });
          continue;
        }

        if (entry.kind !== "file") {
          errors.push({
            path: entryPath,
            message: `unsupported agent file kind: ${entry.kind}`,
            source: entry,
          });
          continue;
        }

        if (files.length >= maxFiles) {
          truncated = true;
          errors.push({
            path: entryPath,
            message: `maxFiles ${maxFiles} reached`,
            source: entry,
          });
          continue;
        }

        try {
          const file = await this.readAgentFile({
            agentId: input.agentId,
            path: entryPath,
          });
          if (totalBytes + file.data.byteLength > maxTotalBytes) {
            truncated = true;
            errors.push({
              path: entryPath,
              message: `maxTotalBytes ${maxTotalBytes} reached`,
              source: entry,
            });
            continue;
          }

          totalBytes += file.data.byteLength;
          files.push({
            agentId: input.agentId,
            path: entryPath,
            relativePath: relativeAgentFilePath(rootPath, entryPath),
            kind: "file",
            data: file.data,
            size: file.data.byteLength,
            contentType: file.contentType,
            source: entry,
          });
        } catch (error) {
          errors.push({
            path: entryPath,
            message: error instanceof Error ? error.message : String(error),
            source: entry,
          });
        }
      }
    }

    return {
      agentId: input.agentId,
      rootPath,
      files,
      directories,
      errors,
      totalBytes,
      truncated,
    };
  }

  async downloadAgentFilesToDirectory(
    input: Salix.AgentFilesDownloadToDirectoryInput
  ): Promise<Salix.AgentFilesDownloadToDirectoryArtifact> {
    const downloaded = await this.downloadAgentFiles(input);
    const outputDir = resolve(input.outputDir);
    const files: Salix.AgentDownloadedLocalFile[] = [];

    await mkdir(outputDir, { recursive: true });
    for (const file of downloaded.files) {
      const localPath = localOutputPath(outputDir, file.relativePath);
      await mkdir(dirname(localPath), { recursive: true });
      await Bun.write(localPath, file.data);
      const { data: _data, ...metadata } = file;
      files.push({
        ...metadata,
        localPath,
      });
    }

    return {
      ...downloaded,
      outputDir,
      files,
    };
  }
}
function agentFileBody(data: Salix.AgentFileWriteInput["data"]) {
  if (typeof data === "string") {
    return data;
  }
  if (data instanceof ArrayBuffer) {
    return new Blob([data]);
  }
  return new Blob([Uint8Array.from(data).buffer]);
}

function agentFilesRoute(agentId: string, path: string): string {
  assertAgentFilePath(path);
  const base = `/v1/runtime/agents/${encodeURIComponent(agentId)}/files`;
  if (path === "/") {
    return base;
  }
  const encodedPath = path.slice(1).split("/").map(encodeURIComponent).join("/");
  return `${base}/${encodedPath}`;
}

function assertAgentFilePath(path: string): void {
  if (path === "/") {
    return;
  }

  const parts = path.split("/");
  const invalid =
    !path.startsWith("/") ||
    path.endsWith("/") ||
    path.includes("\0") ||
    parts.some((part, index) => {
      if (index === 0) {
        return part !== "";
      }
      return !part || part === "." || part === "..";
    });

  if (invalid) {
    throw new Error(`invalid Salix agent file path: ${path}`);
  }
}

function normalizeAgentDirectoryPath(path: string): string {
  if (path === "/") {
    return path;
  }
  return path.replace(/\/+$/u, "");
}

function relativeAgentFilePath(rootPath: string, path: string): string {
  if (rootPath === "/") {
    return path.slice(1);
  }

  if (path === rootPath) {
    const fallback = rootPath.split("/").findLast(Boolean);
    if (!fallback) {
      throw new Error(`cannot derive relative path for ${path}`);
    }
    return fallback;
  }

  const prefix = `${rootPath}/`;
  if (!path.startsWith(prefix)) {
    throw new Error(`agent file path ${path} is outside download root ${rootPath}`);
  }
  return path.slice(prefix.length);
}

function localOutputPath(outputDir: string, relativePath: string): string {
  if (
    !relativePath ||
    relativePath.includes("\0") ||
    relativePath.split("/").some((part) => part === "." || part === "..")
  ) {
    throw new Error(`invalid downloaded relative path: ${relativePath}`);
  }

  const root = resolve(outputDir);
  const target = resolve(root, relativePath);
  if (target === root || !target.startsWith(`${root}${sep}`)) {
    throw new Error(`downloaded file path escapes output directory: ${relativePath}`);
  }
  return target;
}
