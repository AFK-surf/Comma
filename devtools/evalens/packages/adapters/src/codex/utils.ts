import { cp, mkdir, mkdtemp } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { dirname, isAbsolute, join, resolve, sep } from "node:path";
import type { Codex } from "./types";

export function extractCodexThreadId(
  events: readonly Codex.CliEvent[],
  stdout?: string
): string | undefined {
  for (const event of events) {
    if (
      event &&
      typeof event === "object" &&
      !Array.isArray(event) &&
      "thread_id" in event &&
      typeof event.thread_id === "string"
    ) {
      return event.thread_id;
    }
  }

  return stdout?.match(/"thread_id"\s*:\s*"([^"]+)"/u)?.[1];
}

export function extractCodexErrorMessage(
  events: readonly Codex.CliEvent[]
): string | undefined {
  for (const event of events) {
    if (!event || typeof event !== "object" || Array.isArray(event)) {
      continue;
    }
    if (
      "type" in event &&
      event.type === "error" &&
      "message" in event &&
      typeof event.message === "string"
    ) {
      return event.message;
    }
    if (
      "type" in event &&
      event.type === "turn.failed" &&
      "error" in event &&
      event.error &&
      typeof event.error === "object" &&
      !Array.isArray(event.error) &&
      "message" in event.error &&
      typeof event.error.message === "string"
    ) {
      return event.error.message;
    }
  }

  return undefined;
}

export async function findCodexSessionLogPath(
  threadId: string
): Promise<string | undefined> {
  const codexHome = process.env["CODEX_HOME"] || join(homedir(), ".codex");
  for (const root of [
    join(codexHome, "sessions"),
    join(codexHome, "archived_sessions"),
  ]) {
    try {
      for await (const path of new Bun.Glob(`**/*${threadId}*`).scan({
        cwd: root,
        absolute: true,
        onlyFiles: true,
      })) {
        return path;
      }
    } catch {
      // Missing Codex session roots are expected on fresh machines.
    }
  }
  return undefined;
}

export async function prepareWorkspace(input: Codex.TaskInput): Promise<string> {
  const workspaceDir = input.workspaceDir
    ? resolve(input.workspaceDir)
    : await mkdtemp(join(tmpdir(), "evalens-codex-workspace-"));
  if (input.workspaceDir) {
    await mkdir(workspaceDir);
  }

  if (input.fixtureDir) {
    await cp(resolve(input.fixtureDir), workspaceDir, {
      recursive: true,
      force: true,
    });
  }
  if (input.files) {
    await writeInlineFiles(workspaceDir, input.files);
  }

  return workspaceDir;
}

async function writeInlineFiles(
  workspaceDir: string,
  files: Codex.InlineFile[]
): Promise<void> {
  for (const file of files) {
    const target = resolveWorkspacePath(workspaceDir, file.path);
    await mkdir(dirname(target), { recursive: true });
    await Bun.write(target, file.content);
  }
}

function resolveWorkspacePath(workspaceDir: string, path: string): string {
  if (!path || path === "." || isAbsolute(path) || path.includes("\0")) {
    throw new Error(`Invalid workspace file path: ${path}`);
  }

  const root = resolve(workspaceDir);
  const target = resolve(root, path);
  if (target === root || !target.startsWith(`${root}${sep}`)) {
    throw new Error(`Workspace file path escapes workspace: ${path}`);
  }
  return target;
}
