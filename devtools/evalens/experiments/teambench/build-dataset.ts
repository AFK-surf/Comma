import { mkdir, mkdtemp, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

import { c as createTar } from "tar";
import { z } from "zod";

import { TEAM_BENCH_SOURCE_REVISION, TEAM_BENCH_SOURCE_URL } from "./contracts";
import {
  assertNoSymbolicLinks,
  createGitSourceSnapshot,
  publishDatasetBuild,
  runChecked,
} from "./dataset-build-support";
import { TEAM_BENCH_NATIVE_DATASET_NAME, TeamBenchDatasetItem } from "./dataset";

const LeaderboardManifest = z
  .object({
    version: z.string(),
    n_tasks: z.number().int().positive(),
    tasks: z.array(
      z
        .object({
          task_id: z.string().min(1),
          category: z.string().min(1),
          refined_category: z.string().min(1),
          difficulty: z.string().min(1),
          seed_suffix: z.boolean().optional(),
        })
        .strict()
    ),
  })
  .loose();

const evalensRoot = path.resolve(import.meta.dir, "../..");
const sourceRoot = process.env.TEAMBENCH_SOURCE_ROOT ?? "/tmp/comma-teambench-official";
const download = process.env.EVALENS_DATASET_DOWNLOAD !== "false";
await ensurePinnedSource(sourceRoot, download);
await using sourceSnapshot = await createGitSourceSnapshot(
  sourceRoot,
  TEAM_BENCH_SOURCE_REVISION
);

const manifestPath = path.join(
  sourceSnapshot.root,
  "leaderboard",
  "data",
  "leaderboard_90_tasks.json"
);
const leaderboard = LeaderboardManifest.parse(await Bun.file(manifestPath).json());
if (leaderboard.n_tasks !== 90 || leaderboard.tasks.length !== 90) {
  throw new Error(
    `Pinned TeamBench leaderboard must contain 90 tasks; manifest says ` +
      `${leaderboard.n_tasks} and lists ${leaderboard.tasks.length}`
  );
}

const outputDirectory = path.join(
  evalensRoot,
  "datasets",
  TEAM_BENCH_NATIVE_DATASET_NAME
);
await mkdir(path.dirname(outputDirectory), { recursive: true });
const buildDirectory = await mkdtemp(
  path.join(path.dirname(outputDirectory), `.${TEAM_BENCH_NATIVE_DATASET_NAME}-build-`)
);
const itemArchiveDirectory = path.join(buildDirectory, "items");
await mkdir(itemArchiveDirectory, { recursive: true });

const items = [];
try {
  for (const task of [...leaderboard.tasks].sort((left, right) =>
    left.task_id.localeCompare(right.task_id)
  )) {
    const seed = 0;
    const itemId = `${task.task_id.toLowerCase()}-seed-${seed}`;
    const staging = await mkdtemp(
      path.join(os.tmpdir(), `evalens-teambench-${safeSegment(task.task_id)}-`)
    );
    try {
      await materializeTask(sourceSnapshot.root, task.task_id, seed, staging);
      await assertNoSymbolicLinks(staging);
      const archiveFiles = await collectFiles(staging);
      assertNoGitLfsPointers(task.task_id, archiveFiles);
      if (!("agent/spec.md" in archiveFiles)) {
        throw new Error(`${task.task_id} materialization has no agent/spec.md`);
      }
      if (!("agent/brief.md" in archiveFiles)) {
        throw new Error(`${task.task_id} materialization has no agent/brief.md`);
      }
      if (
        !Object.hasOwn(archiveFiles, `grader/source/tasks/${task.task_id}/grade.sh`)
      ) {
        throw new Error(`${task.task_id} materialization has no grade.sh`);
      }
      await createTar(
        {
          cwd: staging,
          file: path.join(itemArchiveDirectory, `${itemId}.tar`),
          noMtime: true,
          portable: true,
        },
        Object.keys(archiveFiles).sort()
      );

      const expectedPath = "grader/reports/expected.json" as const;
      const item = TeamBenchDatasetItem.parse({
        id: itemId,
        input: {
          taskId: task.task_id,
          seed,
          category: task.category,
          refinedCategory: task.refined_category,
          difficulty: task.difficulty,
          source: {
            repository: TEAM_BENCH_SOURCE_URL,
            revision: TEAM_BENCH_SOURCE_REVISION,
            subset: "leaderboard-90",
          },
          paths: {
            spec: "agent/spec.md",
            brief: "agent/brief.md",
            taskAssets: "agent/task",
            workspace: "agent/workspace",
            graderTask: `grader/source/tasks/${task.task_id}`,
            ...(Object.hasOwn(archiveFiles, expectedPath)
              ? { expected: expectedPath }
              : {}),
          },
        },
        expected: {
          grader: "teambench-grade-sh-v1",
          scorePath: "grader/reports/score.json",
          attestationFailureModes: ["bad_attestation", "attestation_missing"],
        },
      });
      items.push(item);
    } finally {
      await rm(staging, { recursive: true, force: true });
    }
  }

  await Bun.write(
    path.join(buildDirectory, "dataset.json"),
    `${JSON.stringify(
      {
        name: TEAM_BENCH_NATIVE_DATASET_NAME,
        description:
          "Official TeamBench leaderboard-90 tasks materialized once at seed 0 for the Evalens native Planner/Executor/Verifier protocol.",
        items,
      },
      null,
      2
    )}\n`
  );
  await publishDatasetBuild(buildDirectory, outputDirectory);
} finally {
  await rm(buildDirectory, { recursive: true, force: true });
}

const outputPath = path.join(outputDirectory, "dataset.json");

console.log(
  JSON.stringify(
    {
      sourceRoot,
      revision: TEAM_BENCH_SOURCE_REVISION,
      outputPath,
      itemCount: items.length,
      next:
        `bun run cli dataset pack ${TEAM_BENCH_NATIVE_DATASET_NAME} ` +
        "--config ./evalens.local.config.json",
    },
    null,
    2
  )
);

async function ensurePinnedSource(root: string, allowDownload: boolean) {
  if (!(await isGitRepository(root))) {
    if (!allowDownload) {
      throw new Error(
        `Pinned TeamBench checkout is missing at ${root}; ` +
          "set EVALENS_DATASET_DOWNLOAD=true or TEAMBENCH_SOURCE_ROOT"
      );
    }
    const parent = path.dirname(root);
    await mkdir(parent, { recursive: true });
    await runChecked([
      "git",
      "clone",
      "--filter=blob:none",
      TEAM_BENCH_SOURCE_URL,
      root,
    ]);
    await runChecked([
      "git",
      "-C",
      root,
      "checkout",
      "--detach",
      TEAM_BENCH_SOURCE_REVISION,
    ]);
  }

  const revision = (
    await runChecked([
      "git",
      "-C",
      root,
      "rev-parse",
      `${TEAM_BENCH_SOURCE_REVISION}^{commit}`,
    ])
  ).trim();
  if (revision !== TEAM_BENCH_SOURCE_REVISION) {
    throw new Error(
      `TeamBench source does not resolve the required revision at ${root}: ` +
        `expected ${TEAM_BENCH_SOURCE_REVISION}, received ${revision}`
    );
  }
}

async function isGitRepository(root: string): Promise<boolean> {
  try {
    return (
      (
        await runChecked(["git", "-C", root, "rev-parse", "--is-inside-work-tree"])
      ).trim() === "true"
    );
  } catch {
    return false;
  }
}

async function materializeTask(
  root: string,
  taskId: string,
  seed: number,
  output: string
) {
  await runChecked(
    [
      process.env.PYTHON ?? "python3",
      path.join(import.meta.dir, "materialize_task.py"),
      "--source-root",
      root,
      "--task-id",
      taskId,
      "--seed",
      String(seed),
      "--output",
      output,
    ],
    root
  );
}

async function collectFiles(root: string): Promise<Record<string, Uint8Array>> {
  const files: Record<string, Uint8Array> = {};
  const glob = new Bun.Glob("**/*");
  for await (const relativePath of glob.scan({
    cwd: root,
    onlyFiles: true,
    dot: true,
  })) {
    const archivePath = relativePath.split(path.sep).join(path.posix.sep);
    files[archivePath] = await Bun.file(path.join(root, relativePath)).bytes();
  }
  return files;
}

function safeSegment(value: string): string {
  return value.replaceAll(/[^A-Za-z0-9_.-]/g, "_");
}

function assertNoGitLfsPointers(
  taskId: string,
  files: Readonly<Record<string, Uint8Array>>
) {
  const lfsPrefix = "version https://git-lfs.github.com/spec/v1\n";
  for (const [filePath, data] of Object.entries(files)) {
    if (new TextDecoder().decode(data.subarray(0, lfsPrefix.length)) === lfsPrefix) {
      throw new Error(
        `${taskId} contains an unresolved Git LFS pointer at ${filePath}; ` +
          "install Git LFS and populate the pinned checkout before building"
      );
    }
  }
}
