import { chmod, mkdir, mkdtemp, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

import type { CodexAdapterConfig } from "@evalens/adapters/config";
import {
  CodexAppServerAdapter,
  type CodexAppServerThreadRecord,
} from "@evalens/adapters/codex";
import {
  createArtifactArchive,
  SalixAdapter,
  type Salix,
} from "@evalens/adapters/salix";
import type { RunOutput } from "@evalens/core";

import {
  codexExecutorPrompt,
  codexPlannerPrompt,
  codexVerifierPrompt,
  nativeTaskMessage,
  salixNativePrompts,
  type TeamBenchNativeRunParams,
  type TeamBenchNativeResult,
} from "./contracts";
import { requireTeamBenchArchive, type TeamBenchDatasetItem } from "./dataset";
import {
  prepareLocalSalixRuntime,
  requireTeamBenchRuntimeImage,
  type LocalSalixRuntime,
} from "./runtime";
import {
  assertCleanupSucceeded,
  assertObservedModel,
  collectSalixTeamBenchArtifacts,
  dedupeTrajectories,
  salixWorkerState,
  stageSalixTeamBenchFiles,
  waitForSalixWorkerSessionsSettled,
} from "./run-support";
import { codexNativeTopologyViolations, salixNativeTopology } from "./native-topology";
import {
  archiveFromFiles,
  collectLocalFiles,
  filesUnder,
  readArchiveFiles,
  requireArchiveFile,
  writeFiles,
} from "./shared";

export async function runSalixNative(input: {
  item: TeamBenchDatasetItem;
  salix: SalixAdapter;
  template: string;
  params: TeamBenchNativeRunParams;
}): Promise<RunOutput<TeamBenchNativeResult>> {
  const { item, salix, params } = input;
  const prompts = salixNativePrompts(params.promptProfile);
  const fixtureFiles = await readArchiveFiles(requireTeamBenchArchive(item));
  const workspaceFiles = filesUnder(fixtureFiles, item.input.paths.workspace);
  const taskFiles = filesUnder(fixtureFiles, item.input.paths.taskAssets);
  const agents: NonNullable<Salix.EvalFixture["agents"]> = [
    {
      role: "router",
      template: input.template,
      systemPrompt: prompts.planner,
    },
    {
      role: "worker",
      ref: "executor",
      template: input.template,
      sessionMode: "deferred",
      systemPrompt: prompts.executor,
    },
    {
      role: "worker",
      ref: "verifier",
      template: input.template,
      sessionMode: "deferred",
      systemPrompt: prompts.verifier,
    },
  ];
  const prepared = await salix.runs.prepareRun({
    name: `teambench-native-${item.id}`,
    agents,
  });
  const planner = salix.runs.agentSession(prepared, { role: "router" });
  const executorAgentId = prepared.workerAgentIds.executor;
  const verifierAgentId = prepared.workerAgentIds.verifier;
  if (!executorAgentId || !verifierAgentId) {
    throw new Error("Salix Native run is missing Executor or Verifier");
  }
  let runtime: LocalSalixRuntime | undefined;

  try {
    runtime = await prepareLocalSalixRuntime({
      salix,
      groupId: prepared.groupId,
      itemId: item.id,
      workspaceFiles,
      image: params.runtimeImage,
      connectorServer: params.salixConnectorServer,
      connectTimeoutMs: params.salixConnectTimeoutMs,
    });
    const spec = requireArchiveFile(fixtureFiles, item.input.paths.spec);
    const brief = requireArchiveFile(fixtureFiles, item.input.paths.brief);
    await stageSalixTeamBenchFiles({
      salix,
      taskAgentIds: [planner.agentId, executorAgentId, verifierAgentId],
      workspaceAgentIds: [executorAgentId, verifierAgentId],
      spec,
      brief,
      taskFiles,
      workspaceFiles,
    });

    const turn = await salix.sessions.runSessionTurn({
      target: planner,
      turnId: `teambench-native:${item.id}`,
      message: nativeTaskMessage(item.input.taskId),
      routerDeliveryMode: "direct_session",
      replyCompletion: "group_quiescent",
      completionQuiescenceMs: 30_000,
      timeoutMs: params.timeoutMs,
      traceLimit: params.traceLimit,
    });
    const workerSessions = await waitForSalixWorkerSessionsSettled(
      () => salix.sessions.listWorkerSessions({ groupId: prepared.groupId }),
      { timeoutMs: 15_000, pollMs: 250 }
    );
    const {
      workerTrajectories,
      respondingWorkerAgentIds,
      executorFiles,
      verifierFiles,
    } = await collectSalixTeamBenchArtifacts({
      salix,
      workerSessions,
      executorAgentId,
      verifierAgentId,
      traceLimit: params.traceLimit,
      maxArtifactFiles: params.maxArtifactFiles,
      maxArtifactBytes: params.maxArtifactBytes,
    });
    const trajectories = dedupeTrajectories([turn.trajectory, ...workerTrajectories]);
    assertObservedModel(trajectories, params.model);
    const plannerToolNames = [
      ...(turn.trace.execution.tool_calls ?? []).map(
        (call) => call.name?.replaceAll("_", ".") ?? ""
      ),
      ...turn.trajectory.steps.flatMap((step) =>
        step.type === "tool_call" ? [step.name] : []
      ),
    ];
    const workerState = salixWorkerState(workerSessions);
    const taskCreateObserved = plannerToolNames.some((name) =>
      name.endsWith("internal.task.create")
    );
    const topology = salixNativeTopology({
      taskCreateObserved,
      workerSessions,
      respondingAgentIds: respondingWorkerAgentIds,
      executorAgentId,
      verifierAgentId,
      settled: workerState.settled,
    });
    const artifacts = createArtifactArchive([executorFiles, verifierFiles]);
    const usage = turn.trace.execution.usage;
    return {
      result: {
        protocol: "native",
        target: "salix",
        itemId: item.id,
        taskId: item.input.taskId,
        seed: item.input.seed,
        sourceRevision: item.input.source.revision,
        model: params.model,
        reasoningEffort: params.reasoningEffort,
        answer: turn.answer ?? "",
        timedOut: turn.replyWait.timedOut === true,
        agents: [
          {
            role: "planner",
            agentId: planner.agentId,
            sessionIds: [planner.sessionId],
          },
          {
            role: "executor",
            agentId: executorAgentId,
            sessionIds: topology.executorSessionIds,
          },
          {
            role: "verifier",
            agentId: verifierAgentId,
            sessionIds: topology.verifierSessionIds,
          },
        ],
        artifactLayout: {
          workspaceRoot: executorAgentId,
          submissionRoot: verifierAgentId,
        },
        executionEnvironment: {
          kind: "salix-local-docker",
          environmentId: runtime.environment.environmentId,
          deviceId: runtime.environment.deviceId,
          alias: runtime.environment.alias,
          image: params.runtimeImage,
          graderTimeoutMs: params.graderTimeoutMs,
        },
        collaboration: {
          delegated: topology.delegated,
          topologySatisfied: topology.violations.length === 0,
          protocolViolations: topology.violations,
          settledAtPlannerReturn: workerState.settled,
          activeWorkerIds: workerState.active,
          systemErrorWorkerIds: workerState.systemError,
          unknownWorkerStateIds: workerState.unknown,
        },
        usage: {
          scope: "planner",
          inputTokens: usage?.prompt_tokens ?? 0,
          outputTokens: usage?.completion_tokens ?? 0,
          totalTokens: usage?.total_tokens ?? 0,
        },
      },
      ...(artifacts ? { artifacts } : {}),
      trajectories,
    };
  } finally {
    const cleanup = await Promise.allSettled([
      runtime?.stop() ?? Promise.resolve(),
      salix.runs.cleanupRun(prepared),
    ]);
    assertCleanupSucceeded(cleanup, "TeamBench Salix run cleanup failed");
  }
}

export async function runCodexNative(input: {
  item: TeamBenchDatasetItem;
  adapterConfig: CodexAdapterConfig;
  params: TeamBenchNativeRunParams;
}): Promise<RunOutput<TeamBenchNativeResult>> {
  const { item, params } = input;
  await requireTeamBenchRuntimeImage(params.runtimeImage);
  const runRoot = await mkdtemp(
    path.join(os.tmpdir(), `evalens-teambench-codex-${item.id}-`)
  );
  const adapter = new CodexAppServerAdapter({
    ...input.adapterConfig,
    model: params.model,
    sandbox: "danger-full-access",
    approvalPolicy: "never",
    ephemeral: false,
    requestTimeoutMs: params.timeoutMs,
  });
  let rootThreadId: string | undefined;
  try {
    const fixtureFiles = await readArchiveFiles(requireTeamBenchArchive(item));
    await writeFiles(path.join(runRoot, "task"), [
      {
        path: "spec.md",
        data: requireArchiveFile(fixtureFiles, item.input.paths.spec).data,
      },
      {
        path: "brief.md",
        data: requireArchiveFile(fixtureFiles, item.input.paths.brief).data,
      },
      ...filesUnder(fixtureFiles, item.input.paths.taskAssets),
    ]);
    await writeFiles(
      path.join(runRoot, "workspace"),
      filesUnder(fixtureFiles, item.input.paths.workspace)
    );
    await mkdir(path.join(runRoot, "submission"), { recursive: true });
    await writeCodexRuntimeHelper(runRoot, params.runtimeImage);
    await writeCodexRoleConfiguration(runRoot, params);

    const thread = await adapter.startThread({
      workspaceDir: runRoot,
      model: params.model,
      reasoningEffort: params.reasoningEffort,
      baseInstructions: codexPlannerPrompt(),
      developerInstructions:
        "The executor and verifier roles are preconfigured. Use both through native collaboration. Never inspect grader files; none are present.",
      sandbox: "danger-full-access",
      approvalPolicy: "never",
      ephemeral: false,
      configOverrides: {
        web_search: "disabled",
        "features.multi_agent": true,
        "agents.max_threads": 3,
        "agents.max_depth": 1,
        "agents.default_subagent_model": params.model,
        "agents.default_subagent_reasoning_effort": params.reasoningEffort,
      },
    });
    rootThreadId = thread.threadId;
    const turn = await adapter.runTurn({
      threadId: thread.threadId,
      message: nativeTaskMessage(item.input.taskId),
      model: params.model,
      reasoningEffort: params.reasoningEffort,
      timeoutMs: params.timeoutMs,
      returnOnTimeout: true,
    });
    const observation = await adapter.observeThreadTree(thread.threadId, true);
    const trajectories = dedupeTrajectories(observation.trajectories);
    assertObservedModel(trajectories, params.model);
    const artifacts = archiveFromFiles([
      ...(await collectLocalFiles(path.join(runRoot, "workspace"), "workspace")),
      ...(await collectLocalFiles(path.join(runRoot, "submission"), "submission")),
    ]);
    const agents = codexAgentRecords(observation.threads);
    const delegated =
      turn.collaborationEvents.some((event) => event.tool === "spawnAgent") ||
      observation.threads.some((record) => record.parentThreadId === thread.threadId);
    const protocolViolations = codexNativeTopologyViolations({
      threads: observation.threads,
      agents,
      delegated,
      settled: observation.settled,
    });
    return {
      result: {
        protocol: "native",
        target: "codex",
        itemId: item.id,
        taskId: item.input.taskId,
        seed: item.input.seed,
        sourceRevision: item.input.source.revision,
        model: params.model,
        reasoningEffort: params.reasoningEffort,
        answer: turn.answer,
        timedOut: turn.timedOut,
        agents,
        artifactLayout: {
          workspaceRoot: "workspace",
          submissionRoot: "submission",
        },
        executionEnvironment: {
          kind: "codex-local-workspace",
          image: params.runtimeImage,
          graderTimeoutMs: params.graderTimeoutMs,
        },
        collaboration: {
          delegated,
          topologySatisfied: protocolViolations.length === 0,
          protocolViolations,
          settledAtPlannerReturn: observation.settled,
          activeWorkerIds: observation.activeThreadIds.filter(
            (id) => id !== thread.threadId
          ),
          systemErrorWorkerIds: observation.systemErrorThreadIds.filter(
            (id) => id !== thread.threadId
          ),
          unknownWorkerStateIds: observation.unknownStatusThreadIds.filter(
            (id) => id !== thread.threadId
          ),
        },
        usage: {
          scope: "thread_tree",
          inputTokens: turn.aggregateInputTokens,
          outputTokens: turn.aggregateOutputTokens,
          totalTokens: turn.aggregateTotalTokens,
        },
      },
      ...(artifacts ? { artifacts } : {}),
      trajectories,
    };
  } finally {
    const threadCleanup = await Promise.allSettled([
      rootThreadId ? adapter.deleteThread(rootThreadId) : Promise.resolve(),
    ]);
    const processCleanup = await Promise.allSettled([
      adapter.close(),
      rm(runRoot, { recursive: true, force: true }),
    ]);
    assertCleanupSucceeded(
      [...threadCleanup, ...processCleanup],
      "TeamBench Codex run cleanup failed"
    );
  }
}

async function writeCodexRoleConfiguration(
  runRoot: string,
  params: TeamBenchNativeRunParams
) {
  const codexRoot = path.join(runRoot, ".codex");
  const agentsRoot = path.join(codexRoot, "agents");
  await mkdir(agentsRoot, { recursive: true });
  await Bun.write(
    path.join(codexRoot, "config.toml"),
    [
      "[agents]",
      "max_threads = 3",
      "max_depth = 1",
      "",
      "[agents.executor]",
      'description = "Implement the TeamBench task in the shared workspace"',
      'config_file = "./agents/executor.toml"',
      "",
      "[agents.verifier]",
      'description = "Independently verify the completed task and attest it"',
      'config_file = "./agents/verifier.toml"',
      "",
    ].join("\n")
  );
  await Bun.write(
    path.join(agentsRoot, "executor.toml"),
    roleToml(codexExecutorPrompt(), params)
  );
  await Bun.write(
    path.join(agentsRoot, "verifier.toml"),
    roleToml(codexVerifierPrompt(), params)
  );
}

async function writeCodexRuntimeHelper(runRoot: string, image: string): Promise<void> {
  const toolsRoot = path.join(runRoot, "tools");
  const helper = path.join(toolsRoot, "run-in-runtime");
  const workspace = path.join(runRoot, "workspace");
  await mkdir(toolsRoot, { recursive: true });
  await Bun.write(
    helper,
    `#!/usr/bin/env bun
const command = process.argv.slice(2);
if (command.length === 0) {
  console.error("usage: tools/run-in-runtime <command> [args...]");
  process.exit(2);
}
const child = Bun.spawn([
  "docker", "run", "--rm", "--network", "none",
  "--user", ${JSON.stringify(`${process.getuid?.() ?? 10001}:${process.getgid?.() ?? 10001}`)},
  "--env", "HOME=/tmp",
  "--mount", ${JSON.stringify(`type=bind,src=${workspace},dst=/workspace`)},
  "--workdir", "/workspace",
  "--entrypoint", "/usr/bin/env",
  ${JSON.stringify(image)},
  ...command,
], { stdin: "inherit", stdout: "inherit", stderr: "inherit", env: process.env });
process.exit(await child.exited);
`
  );
  await chmod(helper, 0o755);
}

function roleToml(prompt: string, params: TeamBenchNativeRunParams): string {
  return [
    `developer_instructions = ${JSON.stringify(prompt)}`,
    `model = ${JSON.stringify(params.model)}`,
    `model_reasoning_effort = ${JSON.stringify(params.reasoningEffort)}`,
    "",
  ].join("\n");
}

function codexAgentRecords(
  threads: readonly CodexAppServerThreadRecord[]
): TeamBenchNativeResult["agents"] {
  const records: TeamBenchNativeResult["agents"] = [];
  for (const thread of threads) {
    const role =
      thread.parentThreadId === null || thread.parentThreadId === undefined
        ? "planner"
        : thread.agentRole === "executor"
          ? "executor"
          : thread.agentRole === "verifier"
            ? "verifier"
            : undefined;
    if (!role) continue;
    records.push({
      role,
      agentId: thread.id,
      sessionIds: thread.sessionId ? [thread.sessionId] : [],
    });
  }
  return records;
}
