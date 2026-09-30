import { rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { CodexCliAdapter } from "@evalens/adapters/codex";
import { defineExperiment, NoParamsSchema } from "@evalens/core";
import { loadTaskCompletionDataset, type TaskDatasetItem } from "./dataset";
import {
  collectDirectoryFiles,
  requireFixtureArchive,
  taskCompletionEvaluator,
  type TaskCompletionEvaluators,
  type TaskCompletionResult,
  taskMessage,
} from "./shared";

export default defineExperiment<
  TaskDatasetItem,
  TaskCompletionResult,
  TaskCompletionEvaluators,
  typeof NoParamsSchema,
  typeof NoParamsSchema,
  readonly ["codex"],
  readonly []
>({
  name: "codex-task-completion",
  description: "Runs task-completion fixtures through Codex CLI.",
  metadata: { tags: ["codex", "task-completion", "live"] },
  adapters: { run: ["codex"], eval: [] },
  datasetLoader: loadTaskCompletionDataset,
  async runItem(item, context) {
    const codex = new CodexCliAdapter({
      ...context.adapterConfig.codex,
      configOverrides: ['model_reasoning_effort="medium"'],
    });
    const fixtureDir = path.join(
      os.tmpdir(),
      "evalens",
      `task-fixture-${Bun.randomUUIDv7()}`
    );
    await requireFixtureArchive(item).extract(fixtureDir);
    try {
      const result = await codex.runTask({
        task: taskMessage(item),
        fixtureDir,
        model: "gpt-5.5",
        metadata: { evalensRunId: context.id, datasetItemId: item.id },
      });
      const files = await collectDirectoryFiles(result.workspaceDir);
      return {
        result: {
          answer: result.finalAnswer,
          replied: result.exitCode === 0,
          exitCode: result.exitCode,
          workspaceFileCount: files.length,
        },
        trajectories: [],
        ...(files.length > 0
          ? {
              artifacts: new Bun.Archive(
                Object.fromEntries(files.map((file) => [file.path, file.content]))
              ),
            }
          : {}),
      };
    } finally {
      await rm(fixtureDir, { recursive: true, force: true });
    }
  },
  evaluators: [taskCompletionEvaluator],
  aggregator: {
    version: "1",
    aggregate: (groups) => {
      const results = groups["task-completed"] ?? [];
      return {
        taskCompleted:
          results.length === 0
            ? 0
            : results.reduce((total, result) => total + result.score.taskCompleted, 0) /
              results.length,
      };
    },
  },
});
