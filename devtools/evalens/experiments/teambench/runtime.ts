import { mkdtemp, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

import { type Salix, SalixAdapter } from "@evalens/adapters/salix";

import type { ArchivedFile } from "./shared";
import { writeFiles } from "./shared";

export const TEAM_BENCH_SALIX_ENVIRONMENT_ALIAS = "teambench-runtime";
export const DEFAULT_TEAM_BENCH_RUNTIME_IMAGE = "evalens-teambench-salix:local";
export const DEFAULT_TEAM_BENCH_CONNECTOR_SERVER = "http://host.docker.internal:4000";

export type LocalSalixRuntime = Salix.DockerConnectorRuntime & {
  tempRoot: string;
  workspaceDir: string;
};

export async function prepareLocalSalixRuntime(input: {
  salix: SalixAdapter;
  groupId: string;
  itemId: string;
  workspaceFiles: readonly ArchivedFile[];
  image: string;
  connectorServer: string;
  connectTimeoutMs: number;
}): Promise<LocalSalixRuntime> {
  const tempRoot = await mkdtemp(
    path.join(os.tmpdir(), `evalens-teambench-salix-runtime-${input.itemId}-`)
  );
  const workspaceDir = path.join(tempRoot, "workspace");

  try {
    await writeFiles(workspaceDir, input.workspaceFiles);
    const connector = await input.salix.connectors.docker.start({
      groupId: input.groupId,
      image: input.image,
      name: `TeamBench runtime ${input.itemId}`,
      alias: TEAM_BENCH_SALIX_ENVIRONMENT_ALIAS,
      root: { hostPath: workspaceDir },
      serverUrl: input.connectorServer,
      tokenTtlSeconds: 3_600,
      connectTimeoutMs: input.connectTimeoutMs,
    });
    return {
      ...connector,
      tempRoot,
      workspaceDir,
      stop: once(async () => {
        const stopped = await Promise.allSettled([
          connector.stop(),
          rm(tempRoot, { recursive: true, force: true }),
        ]);
        const errors = stopped.flatMap((result) =>
          result.status === "rejected" ? [result.reason] : []
        );
        if (errors.length > 0) {
          throw new AggregateError(errors, "TeamBench Salix runtime cleanup failed");
        }
      }),
    };
  } catch (error) {
    await rm(tempRoot, { recursive: true, force: true });
    throw error;
  }
}

export async function requireTeamBenchRuntimeImage(image: string): Promise<void> {
  const inspected = await docker(["image", "inspect", image], true);
  if (inspected.exitCode !== 0) {
    throw new Error(
      `TeamBench runtime image is missing: ${image}. ` +
        "Build it with: bun run experiments/teambench/build-salix-runtime.ts"
    );
  }
}

async function docker(
  args: readonly string[],
  allowFailure = false
): Promise<{ exitCode: number; stdout: string; stderr: string }> {
  const child = Bun.spawn(["docker", ...args], {
    stdout: "pipe",
    stderr: "pipe",
    env: process.env,
  });
  const [exitCode, stdout, stderr] = await Promise.all([
    child.exited,
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
  ]);
  if (!allowFailure && exitCode !== 0) {
    throw new Error(`docker ${args[0]} failed (${exitCode}): ${stderr.slice(-4_000)}`);
  }
  return { exitCode, stdout, stderr };
}

function once(callback: () => Promise<void>): () => Promise<void> {
  let result: Promise<void> | undefined;
  return () => (result ??= callback());
}
