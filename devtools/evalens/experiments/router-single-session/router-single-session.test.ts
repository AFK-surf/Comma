import { afterEach, describe, expect, test } from "bun:test";
import { chmod, mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

import type { DatasetSource } from "@evalens/core";

import {
  AgentLongBenchTier,
  loadAgentLongBenchDataset,
  type RouterSingleSessionItem,
} from "./dataset";
import salixAgentLongBenchExperiment from "./agentlongbench-salix.exp";
import {
  answerRetentionScore,
  answerScore,
  buildCodexJudgeTask,
  claimScore,
  normalizeAnswer,
  parseCodexJudgement,
  pollutionScore,
  routerSingleSessionEvaluator,
} from "./evaluation";
import {
  codexHistoryForPhase,
  codexWindowedHistoryForPhase,
  hydrateAgentLongBenchArchive,
  officialAgentLongBenchHistory,
  salixWindowedHistoryForPhase,
} from "./history";
import {
  ROUTER_SINGLE_SESSION_PHASES,
  SalixAgentLongBenchRunParams,
  runParallelBranches,
  transcriptSourcePrefix,
  type RouterSingleSessionBranchResult,
  type RouterSingleSessionResult,
} from "./contracts";
import { retimeSalixBranchTrajectory } from "./salix-runtime";

const temporaryDirectories: string[] = [];

afterEach(async () => {
  await Promise.all(
    temporaryDirectories
      .splice(0)
      .map((directory) => rm(directory, { recursive: true, force: true }))
  );
});

const item = {
  id: "longmemeval-v2-01307e07",
  input: {
    currentHistory: [{ role: "user", content: "current" }],
    priorHistory: [{ role: "user", content: "prior" }],
    probe: { message: "Which labels?" },
  },
  expected: {
    match: "phrase_set",
    answer: "Incident Mobile, Incident Portal, My Open Incidents",
    requiredClaims: ["Incident Mobile", "Incident Portal", "My Open Incidents"],
    forbiddenClaims: ["Active Incidents without Universal Request"],
  },
  source: {
    dataset: "longmemeval-v2",
    revision: "revision",
    itemId: "01307e07",
    url: "https://example.com",
    evaluator: "norm_phrase_set_match",
  },
  metadata: {
    questionType: "dynamic-environment",
    historyMode: "fixture",
  },
} as RouterSingleSessionItem;

function branch(
  answer: string,
  phase: RouterSingleSessionBranchResult["phase"]
): RouterSingleSessionBranchResult {
  return {
    phase,
    isolationId: `isolation-${phase}`,
    answer,
    answerSource: "router_conversation",
    deliveredMessageId: "prompt-message",
    replyMessageId: "reply-message",
    timedOut: false,
    replyFailureReason: null,
    branchError: null,
    delegated: false,
    workerCreated: false,
    workerCount: 1,
    promptTokens: 1,
    completionTokens: 1,
    totalTokens: 2,
    seededMessageCount: 2,
    finalMessageCount: 3,
    compactedThrough: phase === "compacted" ? 2 : null,
    compactionStatus: phase === "compacted" ? "completed" : null,
    compactionReason: null,
    compactionApplied: phase === "compacted",
    seedHash: "digest",
    durationMs: 10,
  };
}

function result(answer: string): RouterSingleSessionResult {
  return {
    itemId: item.id,
    sourceDataset: "longmemeval-v2",
    target: "salix_router",
    topology: "router_worker",
    branches: {
      fresh: branch(answer, "fresh"),
      accumulated: branch(answer, "accumulated"),
      compacted: branch(answer, "compacted"),
    },
    audit: {
      isolated: true,
      isolationCount: 3,
      accumulatedSeedMatchesCompacted: true,
      onlyCompactedBranchCompacted: true,
      routerIsEvaluationTarget: true,
    },
  };
}

describe("router single-session deterministic scoring", () => {
  test("selects the AgentLongBench dataset from the parsed tier param", async () => {
    const source: DatasetSource = {
      async load(reference) {
        return {
          name: reference.name,
          digest: reference.digest,
          items: [],
        };
      },
    };
    const expectedNames = {
      "32k": "agentlongbench-32k-raw-v1",
      "256k": "agentlongbench-256k-raw-v1",
      "1m": "agentlongbench-1m-raw-v1",
    } as const;

    for (const tier of AgentLongBenchTier.options) {
      const dataset = await loadAgentLongBenchDataset[tier](source);
      expect(dataset.name).toBe(expectedNames[tier]);
    }

    const params = SalixAgentLongBenchRunParams.parse({ tier: "256k" });
    expect(
      (await salixAgentLongBenchExperiment.datasetLoader(source, params)).name
    ).toBe("agentlongbench-256k-raw-v1");
  });

  test("normalizes punctuation, case, and hyphens", () => {
    expect(normalizeAnswer("  My—Open, INCIDENTS! ")).toBe("my open incidents");
  });

  test("scores required and forbidden claims deterministically", () => {
    const answer = "\\boxed{Incident Portal; My Open Incidents; Incident Mobile}";
    expect(claimScore(answer, item.expected.requiredClaims)).toBe(1);
    expect(pollutionScore(answer, item.expected.forbiddenClaims)).toBe(0);
    expect(answerScore(item, answer)).toBe(1);
    expect(answerScore(item, "Incident Portal; My Open Incidents")).toBe(0);
    expect(answerRetentionScore(item, "Incident Portal; My Open Incidents")).toBe(
      2 / 3
    );
    expect(
      answerScore(item, `${answer}; Active Incidents without Universal Request`)
    ).toBe(0);
  });

  test("mirrors AgentLongBench deterministic score families", () => {
    const source = {
      dataset: "agentlongbench",
      revision: "revision",
      itemId: "item",
      url: "https://example.com",
      evaluator: "official",
    } as const;
    const metadata = {
      questionType: "fixture",
      historyMode: "fixture",
      knowledgeMode: "knowledge_intensive",
    };
    const fixture = (expected: RouterSingleSessionItem["expected"]) =>
      ({ id: "fixture", expected, source, metadata }) as RouterSingleSessionItem;

    expect(
      answerScore(
        fixture({
          match: "boolean",
          answer: "true",
          requiredClaims: ["true"],
          forbiddenClaims: [],
        }),
        "<answer>yes, it appears in both</answer>"
      )
    ).toBe(1);
    const pair = fixture({
      match: "ordered_pair",
      answer: "Gholdengo, Gible",
      requiredClaims: ["Gholdengo", "Gible"],
      forbiddenClaims: [],
    });
    expect(answerScore(pair, "<answer>Gholdengo and Gible</answer>")).toBe(1);
    expect(answerScore(pair, "<answer>Gholdengo</answer>")).toBe(0.5);
    const set = fixture({
      match: "token_set_f1",
      answer: "A, B",
      requiredClaims: ["A", "B"],
      forbiddenClaims: [],
    });
    expect(answerScore(set, '<answer>["A", "C"]</answer>')).toBe(0.5);
    expect(answerRetentionScore(set, '<answer>["A", "C"]</answer>')).toBe(0.5);
    expect(
      answerScore(
        fixture({
          match: "number",
          answer: "1000",
          requiredClaims: ["1000"],
          forbiddenClaims: [],
        }),
        "<answer>1,000.0</answer>"
      )
    ).toBe(1);
  });

  test("mirrors all LongMemEval-V2 deterministic evaluator families", () => {
    const fixture = (
      match: RouterSingleSessionItem["expected"]["match"],
      answer: string,
      requiredClaims: string[]
    ) =>
      ({
        ...item,
        expected: {
          match,
          answer,
          requiredClaims,
          forbiddenClaims: [],
        },
      }) as RouterSingleSessionItem;

    const ordered = fixture(
      "phrase_set_ordered",
      "Incident Mobile, Incident Portal, My Open Incidents",
      ["Incident Mobile", "Incident Portal", "My Open Incidents"]
    );
    expect(
      answerScore(
        ordered,
        "\\boxed{Incident Mobile, Incident Portal, My Open Incidents}"
      )
    ).toBe(1);
    expect(
      answerScore(
        ordered,
        "\\boxed{Incident Portal, Incident Mobile, My Open Incidents}"
      )
    ).toBe(0);

    expect(
      answerScore(
        fixture("mc_choice", "B", ["B"]),
        "The evidence points elsewhere. Final: \\boxed{Option B.}"
      )
    ).toBe(1);
    expect(
      answerScore(fixture("mc_choice", "false", ["false"]), "\\boxed{\\text{False}}")
    ).toBe(1);
    expect(
      answerScore(
        fixture("mc_choice_set", "A,C", ["A,C"]),
        "\\boxed{Final choices: C and A}"
      )
    ).toBe(1);
    expect(answerScore(fixture("mc_choice_set", "A,C", ["A,C"]), "\\boxed{A, B}")).toBe(
      0
    );
  });

  test("returns all branch metrics and derived metrics in one evaluation", async () => {
    const output = {
      result: result("Incident Mobile, Incident Portal, My Open Incidents"),
      trajectories: [],
    };
    const context = {
      params: {},
      adapterConfig: {
        codex: {
          command: "codex",
          env: {},
          sandbox: "read-only" as const,
          approvalPolicy: "never" as const,
          skipGitRepoCheck: true,
        },
      },
      logger: {} as never,
    };
    const first = await routerSingleSessionEvaluator.evaluate(item, output, context);
    const second = await routerSingleSessionEvaluator.evaluate(item, output, context);
    expect(first).toEqual(second);
    for (const phase of ROUTER_SINGLE_SESSION_PHASES) {
      expect(first.score[`task_${phase}`]).toBe(1);
      expect(first.score[`retention_${phase}`]).toBe(1);
    }
    expect(first.score.accumulation_loss).toBe(0);
    expect(first.score.compaction_gain).toBe(0);
    expect(first.score.residual_loss).toBe(0);
    expect(first.score.branch_isolation).toBe(1);
    expect(first.score.seed_match).toBe(1);
    expect(first.score.compaction_protocol).toBe(1);
  });

  test("uses identical transcript source ids for accumulated and compacted experiments", () => {
    expect(transcriptSourcePrefix(item.id, "accumulated")).toBe(
      transcriptSourcePrefix(item.id, "compacted")
    );
    expect(transcriptSourcePrefix(item.id, "fresh")).not.toBe(
      transcriptSourcePrefix(item.id, "compacted")
    );
  });

  test("maps every official AgentLongBench message at the adapter boundary", () => {
    const rawItem = {
      ...item,
      source: { ...item.source, dataset: "agentlongbench" },
      input: {
        ...item.input,
        officialEpisodes: {
          current: {
            id: "current",
            question: "Current question",
            messages: [
              { role: "system", content: "original system" },
              {
                role: "assistant",
                content: "calling",
                tool_calls: [
                  {
                    id: "call-1",
                    type: "function",
                    function: { name: "query", arguments: '{"key":"value"}' },
                  },
                ],
              },
              {
                role: "tool",
                tool_call_id: "call-1",
                name: "query",
                content: '{"answer":1}',
              },
              { role: "user", content: "original user" },
            ],
          },
          prior: {
            id: "prior",
            question: "Prior question",
            messages: [{ role: "user", content: "prior user" }],
          },
        },
      },
    } as RouterSingleSessionItem;

    const fresh = officialAgentLongBenchHistory(rawItem, "fresh");
    expect(fresh).toHaveLength(4);
    expect(fresh[0]).toMatchObject({
      role: "runtime",
      type: "agentlongbench.system",
      content: "original system",
    });
    expect(fresh[1]?.toolCalls?.[0]).toEqual({
      id: "call-1",
      name: "query",
      args: { key: "value" },
    });
    expect(fresh[2]).toMatchObject({
      role: "tool",
      toolCallId: "call-1",
      toolName: "query",
      content: '{"answer":1}',
    });
    expect(officialAgentLongBenchHistory(rawItem, "accumulated")).toHaveLength(5);
    expect(codexHistoryForPhase(rawItem, "fresh")).toHaveLength(5);
    expect(codexHistoryForPhase(rawItem, "accumulated")).toHaveLength(6);
    expect(codexHistoryForPhase(rawItem, "accumulated")).toEqual(
      codexHistoryForPhase(rawItem, "compacted")
    );
  });

  test("truncates the oldest Codex history without orphaning tool exchanges", () => {
    const rawItem = {
      ...item,
      source: { ...item.source, dataset: "agentlongbench" },
      input: {
        ...item.input,
        officialEpisodes: {
          current: {
            id: "current",
            question: "Current question",
            messages: [
              { role: "system", content: "old ".repeat(10_000) },
              {
                role: "assistant",
                content: "calling",
                tool_calls: [
                  {
                    id: "call-1",
                    type: "function",
                    function: { name: "query", arguments: '{"key":"value"}' },
                  },
                ],
              },
              {
                role: "tool",
                tool_call_id: "call-1",
                name: "query",
                content: '{"answer":1}',
              },
              { role: "user", content: "recent question" },
            ],
          },
          prior: {
            id: "prior",
            question: "Prior question",
            messages: [{ role: "user", content: "older prior" }],
          },
        },
      },
    } as RouterSingleSessionItem;

    const windowed = codexWindowedHistoryForPhase(rawItem, "fresh", 1_000);
    expect(windowed.stats.truncatedMessageGroupCount).toBe(1);
    expect(windowed.stats.retainedMessageGroupCount).toBe(2);
    expect(windowed.items.map((historyItem) => historyItem.type)).toEqual([
      "message",
      "function_call",
      "function_call_output",
      "message",
    ]);
    expect(windowed.stats.retainedEstimatedTokens).toBeLessThanOrEqual(1_000);
    expect(windowed.stats.truncatedEstimatedTokens).toBeGreaterThan(0);
  });

  test("uses the Codex window selection for matched Salix long branches", () => {
    const rawItem = {
      ...item,
      source: { ...item.source, dataset: "agentlongbench" },
      input: {
        ...item.input,
        officialEpisodes: {
          current: {
            id: "current",
            question: "Current question",
            messages: [
              { role: "system", content: "old ".repeat(10_000) },
              {
                role: "assistant",
                content: "calling",
                tool_calls: [
                  {
                    id: "call-1",
                    type: "function",
                    function: { name: "query", arguments: '{"key":"value"}' },
                  },
                ],
              },
              {
                role: "tool",
                tool_call_id: "call-1",
                name: "query",
                content: '{"answer":1}',
              },
              { role: "user", content: "recent question" },
            ],
          },
          prior: {
            id: "prior",
            question: "Prior question",
            messages: [{ role: "user", content: "older prior" }],
          },
        },
      },
    } as RouterSingleSessionItem;

    const codex = codexWindowedHistoryForPhase(rawItem, "accumulated", 1_000);
    const salix = salixWindowedHistoryForPhase(rawItem, "accumulated", 1_000);

    expect(salix.stats).toEqual(codex.stats);
    expect(salix.entries.map((entry) => entry.content)).toEqual([
      "calling",
      '{"answer":1}',
      "recent question",
    ]);
    expect(salix.entries.map((entry) => entry.sourceRefs?.source_index)).toEqual([
      1, 2, 3,
    ]);
  });

  test("hydrates byte-verified official episodes from an item archive", async () => {
    const directory = await mkdtemp(path.join(os.tmpdir(), "evalens-agentlong-"));
    temporaryDirectories.push(directory);
    const current = JSON.stringify({
      id: "current",
      question: "current question",
      messages: [{ role: "system", content: "current system" }],
    });
    const prior = JSON.stringify({
      id: "prior",
      question: "prior question",
      messages: [{ role: "user", content: "prior message" }],
    });
    const archivePath = path.join(directory, "episodes.tar");
    await Bun.Archive.write(archivePath, {
      "current.json": current,
      "prior.json": prior,
    });
    const archivedItem = {
      ...item,
      id: "agentlongbench-archive",
      input: {
        currentHistory: [],
        priorHistory: [],
        probe: { message: "probe" },
        officialEpisodeArchive: {
          format: "agentlongbench-official-episodes-v1" as const,
          currentPath: "current.json" as const,
          priorPath: "prior.json" as const,
          currentSha256: sha256ForTest(current),
          priorSha256: sha256ForTest(prior),
        },
      },
      source: { ...item.source, dataset: "agentlongbench" as const },
      archive: new Bun.Archive(await Bun.file(archivePath).bytes()),
    } satisfies RouterSingleSessionItem;

    const hydrated = await hydrateAgentLongBenchArchive(archivedItem);
    expect(hydrated.input.officialEpisodeArchive).toBeUndefined();
    expect(hydrated.input.officialEpisodes?.current.id).toBe("current");
    expect(hydrated.input.officialEpisodes?.prior.id).toBe("prior");
  });

  test("starts every isolated branch before waiting for any branch", async () => {
    const started: string[] = [];
    const completed: string[] = [];
    let release!: () => void;
    const gate = new Promise<void>((resolve) => {
      release = resolve;
    });
    const pending = runParallelBranches(
      ["fresh", "accumulated", "compacted"].map((phase) => async () => {
        started.push(phase);
        await gate;
        completed.push(phase);
        return phase;
      })
    );

    expect(started).toEqual(["fresh", "accumulated", "compacted"]);
    expect(completed).toEqual([]);
    release();
    expect(await pending).toEqual(["fresh", "accumulated", "compacted"]);
  });

  test("anchors Salix seed, probe, and answer to the real branch lifecycle", () => {
    const collectedAt = new Date("2026-07-23T12:23:20.000Z");
    const branchStartedAt = new Date("2026-07-23T12:22:43.000Z");
    const turnStartedAt = new Date("2026-07-23T12:23:10.000Z");
    const turnFinishedAt = new Date("2026-07-23T12:23:19.000Z");
    const trajectory = retimeSalixBranchTrajectory({
      trajectory: {
        id: "salix-trace",
        steps: [
          { type: "system", content: "seed", timestamp: collectedAt },
          { type: "user", content: "probe", timestamp: collectedAt },
          { type: "system", content: "migration", timestamp: collectedAt },
          { type: "assistant", content: "answer", timestamp: collectedAt },
          {
            type: "tool_call",
            id: "call-1",
            name: "query",
            arguments: null,
            timestamp: new Date("2026-07-23T12:22:42.000Z"),
          },
        ],
      },
      probe: "probe",
      answer: "answer",
      branchStartedAt,
      turnStartedAt,
      turnFinishedAt,
    });

    expect(trajectory.steps.map((step) => step.timestamp)).toEqual([
      branchStartedAt,
      branchStartedAt,
      turnStartedAt,
      turnStartedAt,
      turnFinishedAt,
    ]);
  });

  test("parses strict Codex binary judgements", () => {
    expect(parseCodexJudgement('```json\n{"label":1,"reason":"matches"}\n```')).toEqual(
      { label: 1, reason: "matches" }
    );
    expect(() => parseCodexJudgement('{"label":0.5,"reason":"partial"}')).toThrow();
  });

  test("uses Codex for semantic LongMemEval scoring", async () => {
    const fakeCodex = await createFakeCodex();
    const semanticItem = {
      ...item,
      input: {
        currentHistory: [{ role: "user", content: "evidence" }],
        priorHistory: [{ role: "user", content: "prior" }],
        probe: { message: "Why did the update fail?" },
      },
      expected: {
        match: "llm_gotchas",
        answer: "The field becomes read-only after approval.",
        requiredClaims: ["field becomes read-only"],
        forbiddenClaims: [],
      },
      source: {
        dataset: "longmemeval-v2",
        revision: "revision",
        itemId: "gotcha-1",
        url: "https://example.com",
        evaluator: "llm_gotchas_checker",
      },
      metadata: {
        questionType: "gotchas",
        historyMode: "fixture",
      },
    } as RouterSingleSessionItem;
    expect(buildCodexJudgeTask(semanticItem, "It is read-only now.")).toContain(
      "gotchas-style insight"
    );

    const evaluation = await routerSingleSessionEvaluator.evaluate(
      semanticItem,
      {
        result: result("It is read-only now."),
        trajectories: [],
      },
      {
        params: {},
        adapterConfig: {
          codex: {
            command: fakeCodex.command,
            env: fakeCodex.env,
            sandbox: "read-only",
            approvalPolicy: "never",
            skipGitRepoCheck: true,
          },
        },
        logger: {} as never,
      }
    );

    expect(evaluation.score.task_fresh).toBe(1);
    expect(evaluation.score.retention_fresh).toBe(1);
    expect(JSON.parse(evaluation.explanation ?? "{}")).toMatchObject({
      branches: {
        fresh: {
          judge: {
            scoringMethod: "codex-llm-judge",
            label: 1,
            reason: "matches reference insight",
          },
        },
      },
    });
  });
});

function sha256ForTest(content: string): string {
  return new Bun.CryptoHasher("sha256").update(content).digest("hex");
}

async function createFakeCodex(): Promise<{
  command: string;
  env: Record<string, string>;
}> {
  const directory = await mkdtemp(path.join(os.tmpdir(), "evalens-judge-codex-"));
  temporaryDirectories.push(directory);
  const commandPath = path.join(directory, "fake-codex");
  await writeFile(
    commandPath,
    `#!/bin/sh
set -eu
out=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--output-last-message" ]; then
    shift
    out="\${1:-}"
  fi
  shift || true
done
printf '%s' '{"label":1,"reason":"matches reference insight"}' > "$out"
printf '%s\n' '{"type":"done"}'
`,
    "utf8"
  );
  await chmod(commandPath, 0o755);
  return {
    command: "fake-codex",
    env: { PATH: `${directory}:${process.env["PATH"] ?? ""}` },
  };
}
