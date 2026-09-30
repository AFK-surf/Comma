import path from "node:path";

import { describe, expect, test } from "bun:test";
import type { CodexAppServerThreadRecord } from "@evalens/adapters/codex";

import {
  EXECUTOR_PROMPT,
  FULL_EXECUTOR_PROMPT,
  FULL_PLANNER_PROMPT,
  FULL_VERIFIER_PROMPT,
  codexExecutorPrompt,
  codexVerifierPrompt,
  PLANNER_PROMPT,
  TEAM_BENCH_MODEL,
  TEAM_BENCH_NATIVE_FULL_PROMPT_PROFILE,
  TEAM_BENCH_NATIVE_PROMPT_PROFILE,
  TEAM_BENCH_REASONING_EFFORT,
  TEAM_BENCH_SOURCE_REVISION,
  TEAM_BENCH_SOURCE_URL,
  TeamBenchNativeRunParams,
  type TeamBenchNativeResult,
  VERIFIER_PROMPT,
  salixNativePrompts,
} from "./contracts";
import {
  TeamBenchDatasetItem,
  type TeamBenchDatasetItem as TeamBenchDatasetItemType,
} from "./dataset";
import {
  createTeamBenchNativeEvaluator,
  type TeamBenchGraderRunner,
} from "./evaluation";
import { codexNativeTopologyViolations, salixNativeTopology } from "./native-topology";
import { assertObservedModel, waitForSalixWorkerSessionsSettled } from "./run-support";
import { filesUnder, normalizedArchivePath } from "./shared";

describe("TeamBench native protocol", () => {
  test("keeps reproducible defaults and accepts explicit model run params", () => {
    expect(TeamBenchNativeRunParams.parse({})).toMatchObject({
      model: TEAM_BENCH_MODEL,
      reasoningEffort: TEAM_BENCH_REASONING_EFFORT,
      promptProfile: TEAM_BENCH_NATIVE_PROMPT_PROFILE,
    });
    expect(
      TeamBenchNativeRunParams.parse({
        model: "deepseek-v4-flash",
        reasoningEffort: "high",
      })
    ).toMatchObject({
      model: "deepseek-v4-flash",
      reasoningEffort: "high",
    });
  });

  test("keeps Salix role prompts model-neutral and leaves completion detection to Evalens", () => {
    expect(PLANNER_PROMPT).toContain("task-specific, actionable delegation");
    expect(PLANNER_PROMPT).toContain("exact input and output");
    expect(PLANNER_PROMPT).toContain("task-specific validation plan");
    expect(PLANNER_PROMPT).not.toContain("CRITICAL COMPLETION CONTRACT");
    expect(PLANNER_PROMPT).not.toContain("every plain assistant response ends");
    expect(PLANNER_PROMPT).not.toContain("Use this exact Executor content string");
    expect(PLANNER_PROMPT).not.toContain(
      "Read /task/spec.md and /task/brief.md. Implement the task"
    );
  });

  test("selects the recorded full and semantic-only Salix prompt profiles", () => {
    expect(
      TeamBenchNativeRunParams.parse({
        promptProfile: TEAM_BENCH_NATIVE_FULL_PROMPT_PROFILE,
      }).promptProfile
    ).toBe(TEAM_BENCH_NATIVE_FULL_PROMPT_PROFILE);
    expect(salixNativePrompts(TEAM_BENCH_NATIVE_FULL_PROMPT_PROFILE)).toEqual({
      planner: FULL_PLANNER_PROMPT,
      executor: FULL_EXECUTOR_PROMPT,
      verifier: FULL_VERIFIER_PROMPT,
    });
    expect(salixNativePrompts(TEAM_BENCH_NATIVE_PROMPT_PROFILE)).toEqual({
      planner: PLANNER_PROMPT,
      executor: EXECUTOR_PROMPT,
      verifier: VERIFIER_PROMPT,
    });
    expect(FULL_PLANNER_PROMPT).toContain('"tool":"im_api.internal.task.create"');
    expect(FULL_PLANNER_PROMPT).toContain('"connect_id":"internal"');
    expect(FULL_EXECUTOR_PROMPT).toContain("description must be at most 19 characters");
    expect(PLANNER_PROMPT).not.toContain('"tool":"im_api.internal.task.create"');
    expect(PLANNER_PROMPT).toContain('connect_id="internal"');
  });

  test("waits through Salix worker status propagation before scoring topology", async () => {
    const observations = [
      [{ agentId: "executor", sessionId: "session-1", status: "running" }],
      [{ agentId: "executor", sessionId: "session-1", status: "idle" }],
    ];
    let reads = 0;
    let sleeps = 0;

    const sessions = await waitForSalixWorkerSessionsSettled(
      async () => observations[Math.min(reads++, observations.length - 1)]!,
      {
        timeoutMs: 1_000,
        pollMs: 1,
        sleep: async () => {
          sleeps += 1;
        },
      }
    );

    expect(reads).toBe(2);
    expect(sleeps).toBe(1);
    expect(sessions[0]?.status).toBe("idle");
  });

  test("requires observed work from both Salix roles", () => {
    const topology = salixNativeTopology({
      taskCreateObserved: true,
      workerSessions: [
        { agentId: "executor", sessionId: "executor-session", status: "idle" },
        { agentId: "verifier", sessionId: "verifier-session", status: "idle" },
      ],
      respondingAgentIds: ["executor"],
      executorAgentId: "executor",
      verifierAgentId: "verifier",
      settled: true,
    });

    expect(topology.delegated).toBe(true);
    expect(topology.violations).toEqual(["verifier_reply_not_observed"]);
  });

  test("rejects a Codex Verifier spawned before Executor completion", () => {
    const threads = [
      codexThread("planner", undefined, 1, 30),
      codexThread("executor", "executor", 2, 20),
      codexThread("verifier", "verifier", 10, 25),
    ];
    const agents: TeamBenchNativeResult["agents"] = [
      { role: "planner", agentId: "planner", sessionIds: [] },
      { role: "executor", agentId: "executor", sessionIds: [] },
      { role: "verifier", agentId: "verifier", sessionIds: [] },
    ];

    expect(
      codexNativeTopologyViolations({
        threads,
        agents,
        delegated: true,
        settled: true,
      })
    ).toContain("verifier_started_before_executor_completed");
  });

  test("fails closed when Codex cannot prove Executor completion", () => {
    const executor = codexThread("executor", "executor", 2, 20);
    executor.turns![0] = { ...executor.turns![0]!, completedAt: undefined };
    const threads = [
      codexThread("planner", undefined, 1, 30),
      executor,
      codexThread("verifier", "verifier", 21, 25),
    ];
    const agents: TeamBenchNativeResult["agents"] = [
      { role: "planner", agentId: "planner", sessionIds: [] },
      { role: "executor", agentId: "executor", sessionIds: [] },
      { role: "verifier", agentId: "verifier", sessionIds: [] },
    ];

    expect(
      codexNativeTopologyViolations({
        threads,
        agents,
        delegated: true,
        settled: true,
      })
    ).toContain("executor_completion_not_observed");
  });

  test("requires model evidence before accepting a native run", () => {
    expect(() => assertObservedModel([], "gpt-5.5")).toThrow(
      "did not expose any assistant model evidence"
    );
    expect(() =>
      assertObservedModel(
        [
          {
            id: "worker",
            steps: [
              {
                type: "assistant",
                content: "done",
                timestamp: new Date(0),
              },
            ],
          },
        ],
        "gpt-5.5"
      )
    ).toThrow("without model evidence");
    expect(() =>
      assertObservedModel(
        [
          {
            id: "worker",
            steps: [
              {
                type: "assistant",
                content: "done",
                model: "gpt-5.5",
                timestamp: new Date(0),
              },
            ],
          },
        ],
        "gpt-5.5"
      )
    ).not.toThrow();
  });

  test("describes the Salix connector workflow without embedding tool schemas", () => {
    for (const prompt of [EXECUTOR_PROMPT, VERIFIER_PROMPT]) {
      expect(prompt).toContain('alias is "teambench-runtime"');
      expect(prompt).toContain("use device.list");
      expect(prompt).toContain("device.get");
      expect(prompt).toContain("Use env.copy");
      expect(prompt).toContain("use env.exec");
      expect(prompt).not.toContain("src_environment");
      expect(prompt).not.toContain("dst_environment");
      expect(prompt).not.toContain('working_dir="/workspace"');
      expect(prompt).not.toContain("description must be at most 19 characters");
      expect(prompt).not.toContain('guidance_reason="repair_required"');
      expect(prompt).toContain(
        "Project files and supporting documents named by the spec are under /workspace"
      );
      expect(prompt).toContain("Use fs.list_files to resolve a path before reading it");
    }
  });

  test("every Salix worker profile retains the owning device for remote operations", () => {
    for (const prompt of [
      EXECUTOR_PROMPT,
      VERIFIER_PROMPT,
      FULL_EXECUTOR_PROMPT,
      FULL_VERIFIER_PROMPT,
    ]) {
      expect(prompt).toContain("device.list");
      expect(prompt).toContain("device.get");
      expect(prompt).toContain("device_id");
      expect(prompt).toContain("environment_id");
      expect(prompt).not.toContain("env.list");
    }
  });

  test("keeps connector-only instructions out of Codex worker prompts", () => {
    for (const prompt of [codexExecutorPrompt(), codexVerifierPrompt()]) {
      expect(prompt).not.toContain("env.list");
      expect(prompt).not.toContain("env.exec");
      expect(prompt).not.toContain("teambench-runtime");
      expect(prompt).toContain("./tools/run-in-runtime");
      expect(prompt).toContain("standard offline TeamBench environment");
    }
  });

  test("rejects unsafe archive paths and selects an explicit artifact root", () => {
    expect(() => normalizedArchivePath("../grader/expected.json")).toThrow();
    expect(
      filesUnder(
        [
          { path: "executor/main.py", data: new Uint8Array([1]) },
          { path: "verifier/attestation.json", data: new Uint8Array([2]) },
        ],
        "executor"
      )
    ).toEqual([{ path: "main.py", data: new Uint8Array([1]) }]);
  });

  test("runs the frozen grader command and preserves the attestation promotion", async () => {
    const item = fixtureItem({
      "grader/source/tasks/FIXTURE/grade.sh": `#!/usr/bin/env bash
set -eu
WORKSPACE="$1"
REPORTS="$2"
SUBMISSION="$3"
test -f "$WORKSPACE/result.txt"
mkdir -p "$REPORTS"
if test -f "$SUBMISSION/attestation.json"; then
  PASS=true
  FAILURES='[]'
  PARTIAL=1
else
  PASS=false
  FAILURES='["bad_attestation"]'
  PARTIAL=0.9
fi
cat > "$REPORTS/score.json" <<JSON
{"pass":$PASS,"primary":{"success":0},"secondary":{"partial_score":$PARTIAL},"failure_modes":$FAILURES}
JSON
`,
    });
    const result = fixtureResult();
    const evaluated = await fixtureEvaluator.evaluate(item, {
      result,
      trajectories: [],
      artifacts: new Bun.Archive({
        "workspace/result.txt": "done",
      }),
    });

    expect(evaluated.score).toEqual({
      rawGraderPass: 0,
      paperPromotedPass: 1,
      partialScore: 0.9,
      attestationPresent: 0,
      verifierApproved: 0,
      falseAccept: 0,
      falseReject: 0,
      delegated: 1,
      topologySatisfied: 1,
      settledAtPlannerReturn: 1,
      protocolViolationCount: 0,
    });
    expect(JSON.parse(evaluated.explanation ?? "{}")).toMatchObject({
      taskId: "FIXTURE",
      verifierVerdict: "missing",
      grader: {
        exitCode: 0,
        rawScoreText: expect.stringContaining('"bad_attestation"'),
      },
    });
  }, 30_000);

  test("scores verifier acceptance separately from task outcome", async () => {
    const item = fixtureItem({
      "grader/source/tasks/FIXTURE/grade.sh": `#!/usr/bin/env bash
set -eu
REPORTS="$2"
mkdir -p "$REPORTS"
cat > "$REPORTS/score.json" <<JSON
{"pass":false,"primary":{"success":0},"secondary":{"partial_score":0.25},"failure_modes":["implementation_wrong"]}
JSON
`,
    });
    const evaluated = await fixtureEvaluator.evaluate(item, {
      result: fixtureResult(),
      trajectories: [],
      artifacts: new Bun.Archive({
        "workspace/result.txt": "wrong",
        "submission/attestation.json": JSON.stringify({
          verdict: "pass",
          summary: "accepted",
        }),
      }),
    });

    expect(evaluated.score).toMatchObject({
      rawGraderPass: 0,
      paperPromotedPass: 0,
      partialScore: 0.25,
      attestationPresent: 1,
      verifierApproved: 1,
      falseAccept: 1,
      falseReject: 0,
    });
  }, 30_000);
});

const runFixtureGrader: TeamBenchGraderRunner = async ({ command, root }) => {
  const localCommand = command.map((argument) => localEvalPath(argument, root));
  const child = Bun.spawn(localCommand, {
    cwd: root,
    stdout: "pipe",
    stderr: "pipe",
    env: process.env,
  });
  const [exitCode, stdout, stderr] = await Promise.all([
    child.exited,
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
  ]);
  return { exitCode, stdout, stderr };
};

const fixtureEvaluator = createTeamBenchNativeEvaluator(runFixtureGrader);

function localEvalPath(argument: string, root: string): string {
  if (argument === "/eval") return root;
  const prefix = "/eval/";
  return argument.startsWith(prefix)
    ? path.join(root, argument.slice(prefix.length))
    : argument;
}

function codexThread(
  id: string,
  role: string | undefined,
  createdAt: number,
  completedAt: number
): CodexAppServerThreadRecord {
  return {
    id,
    parentThreadId: role ? "planner" : null,
    agentRole: role,
    createdAt,
    status: { type: "idle" },
    turns: [
      {
        id: `${id}-turn`,
        items: [],
        status: "completed",
        startedAt: createdAt,
        completedAt,
      },
    ],
  };
}

function fixtureItem(
  extraArchiveFiles: Record<string, string>
): TeamBenchDatasetItemType {
  const parsed = TeamBenchDatasetItem.parse({
    id: "fixture-seed-0",
    input: {
      taskId: "FIXTURE",
      seed: 0,
      category: "Testing",
      refinedCategory: "Testing",
      difficulty: "medium",
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
        graderTask: "grader/source/tasks/FIXTURE",
      },
    },
    expected: {
      grader: "teambench-grade-sh-v1",
      scorePath: "grader/reports/score.json",
      attestationFailureModes: ["bad_attestation", "attestation_missing"],
    },
  });
  return {
    ...parsed,
    archive: new Bun.Archive({
      "agent/spec.md": "spec",
      "agent/brief.md": "brief",
      "agent/task/corpus/input.txt": "public input",
      "agent/workspace/input.txt": "input",
      ...extraArchiveFiles,
    }),
  };
}

function fixtureResult(): TeamBenchNativeResult {
  return {
    protocol: "native",
    target: "codex",
    itemId: "fixture-seed-0",
    taskId: "FIXTURE",
    seed: 0,
    sourceRevision: TEAM_BENCH_SOURCE_REVISION,
    model: TEAM_BENCH_MODEL,
    reasoningEffort: TEAM_BENCH_REASONING_EFFORT,
    answer: "complete",
    timedOut: false,
    agents: [],
    artifactLayout: {
      workspaceRoot: "workspace",
      submissionRoot: "submission",
    },
    executionEnvironment: {
      kind: "codex-local-workspace",
    },
    collaboration: {
      delegated: true,
      topologySatisfied: true,
      protocolViolations: [],
      settledAtPlannerReturn: true,
      activeWorkerIds: [],
      systemErrorWorkerIds: [],
      unknownWorkerStateIds: [],
    },
    usage: {
      scope: "thread_tree",
      inputTokens: 1,
      outputTokens: 1,
      totalTokens: 2,
    },
  };
}
