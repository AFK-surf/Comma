import path from "node:path";
import { createArtifactArchive, SalixAdapter } from "@evalens/adapters/salix";
import {
  defineExperiment,
  type DatasetItemArchive,
  NoParamsSchema,
  type Evaluator,
} from "@evalens/core";
import { loadTaskCompletionDataset, type TaskDatasetItem } from "./dataset";

export type FixtureFile = { path: string; content: Uint8Array };
export type TaskCompletionResult = {
  answer: string;
  replied: boolean;
  exitCode?: number | null;
  workspaceFileCount?: number;
};

export const taskCompletionEvaluator = {
  name: "task-completed",
  version: "1",
  evaluate(item, output) {
    const score =
      output.result.replied && output.result.answer.trim().length > 0 ? 1 : 0;
    return {
      score: { taskCompleted: score },
      explanation: `${item.expected.successCriteria.length} success criteria; answer length=${output.result.answer.length}`,
    };
  },
} satisfies Evaluator<TaskDatasetItem, TaskCompletionResult, {}>;

export type TaskCompletionEvaluators = readonly [typeof taskCompletionEvaluator];

export async function collectFixtureFiles(
  archive: DatasetItemArchive
): Promise<FixtureFile[]> {
  const files: FixtureFile[] = [];
  for (const [filePath, file] of await archive.files()) {
    files.push({ path: filePath, content: await file.bytes() });
  }
  return files;
}

export async function collectDirectoryFiles(root: string): Promise<FixtureFile[]> {
  const files: FixtureFile[] = [];
  const glob = new Bun.Glob("**/*");
  for await (const filePath of glob.scan({ cwd: root, onlyFiles: true })) {
    files.push({
      path: filePath,
      content: await Bun.file(path.join(root, filePath)).bytes(),
    });
  }
  return files;
}

export function requireFixtureArchive(item: TaskDatasetItem): DatasetItemArchive {
  if (!item.archive) {
    throw new Error(`dataset item archive is missing: ${item.id}`);
  }
  return item.archive;
}

export function taskMessage(item: TaskDatasetItem): string {
  return `${item.input.task}\n\nThe fixture workspace is already available. Complete the task and report the created or modified files.`;
}

export function defineSalixTaskExperiment(options: {
  name: string;
  role: "router" | "worker";
}) {
  return defineExperiment<
    TaskDatasetItem,
    TaskCompletionResult,
    TaskCompletionEvaluators,
    typeof NoParamsSchema,
    typeof NoParamsSchema,
    readonly ["salix"],
    readonly []
  >({
    name: options.name,
    description: `Runs task-completion fixtures through a Salix ${options.role} agent.`,
    metadata: { tags: ["salix", options.role, "task-completion", "live"] },
    adapters: { run: ["salix"], eval: [] },
    datasetLoader: loadTaskCompletionDataset,
    async runItem(item, context) {
      const salix = new SalixAdapter(context.adapterConfig.salix);
      const ref = "task-worker";
      const prepared = await salix.runs.prepareRun({
        name: `${options.name}-${item.id}`,
        agents: [
          {
            role: options.role,
            template: context.adapterConfig.salix.templateId,
            ...(options.role === "worker" ? { ref } : {}),
            systemPrompt:
              "Complete the requested task in /workspace. Inspect existing files, make the required changes, and report what you changed.",
          },
        ],
      });
      const target = salix.runs.agentSession(
        prepared,
        options.role === "router"
          ? { role: "router" }
          : { role: "worker", workerRef: ref }
      );
      try {
        const fixtureFiles = await collectFixtureFiles(requireFixtureArchive(item));
        await Promise.all(
          fixtureFiles.map((file) =>
            salix.files.writeAgentFile({
              agentId: target.agentId,
              path: `/workspace/${file.path}`,
              data: file.content,
            })
          )
        );
        const turn = await salix.sessions.runSessionTurn({
          target,
          turnId: `task-completion:${item.id}`,
          message: taskMessage(item),
          traceLimit: 500,
        });
        const artifacts = createArtifactArchive([
          await salix.files.downloadAgentFiles({ agentId: target.agentId }),
        ]);
        return {
          result: {
            answer: turn.answer ?? "",
            replied: true,
          },
          ...(artifacts ? { artifacts } : {}),
          trajectories: [turn.trajectory],
        };
      } finally {
        await salix.runs.cleanupRun(prepared);
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
              : results.reduce(
                  (total, result) => total + result.score.taskCompleted,
                  0
                ) / results.length,
        };
      },
    },
  });
}
