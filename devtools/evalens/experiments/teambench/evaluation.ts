import { mkdir, mkdtemp, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

import type { Evaluator } from "@evalens/core";
import { z } from "zod";

import type { TeamBenchRunResult } from "./contracts";
import { requireTeamBenchArchive, type TeamBenchDatasetItem } from "./dataset";
import { DEFAULT_TEAM_BENCH_RUNTIME_IMAGE } from "./runtime";
import { filesUnder, readArchiveFiles, writeFiles } from "./shared";

const OfficialScore = z
  .object({
    pass: z.boolean(),
    primary: z.record(z.string(), z.json()).optional(),
    secondary: z
      .object({
        partial_score: z.number().finite().optional(),
      })
      .loose()
      .optional(),
    failure_modes: z.array(z.string()).default([]),
  })
  .loose();

const VerifierAttestation = z
  .object({
    verdict: z.enum(["pass", "fail"]),
  })
  .loose();

const SCORE_KEYS = [
  "rawGraderPass",
  "paperPromotedPass",
  "partialScore",
  "attestationPresent",
  "verifierApproved",
  "falseAccept",
  "falseReject",
  "delegated",
  "topologySatisfied",
  "settledAtPlannerReturn",
  "protocolViolationCount",
] as const;

type GraderResult = {
  exitCode: number | null;
  stdout: string;
  stderr: string;
};

export type TeamBenchGraderRunner = (input: {
  command: string[];
  root: string;
  timeoutMs: number;
  image: string;
}) => Promise<GraderResult>;

export function createTeamBenchNativeEvaluator(
  runGrader: TeamBenchGraderRunner = runDockerGrader
) {
  return {
    name: "teambench-native-grader",
    version: "3",
    async evaluate(item, output) {
      const root = await mkdtemp(
        path.join(os.tmpdir(), `evalens-teambench-grade-${item.id}-`)
      );
      try {
        const fixtureFiles = await readArchiveFiles(requireTeamBenchArchive(item));
        const artifactFiles = output.artifacts
          ? await readArchiveFiles(output.artifacts)
          : [];
        const workspace = path.join(root, "workspace");
        const reports = path.join(root, "reports");
        const submission = path.join(root, "submission");
        const graderSource = path.join(root, "grader-source");
        await Promise.all([
          writeFiles(
            workspace,
            filesUnder(artifactFiles, output.result.artifactLayout.workspaceRoot)
          ),
          writeFiles(
            submission,
            filesUnder(artifactFiles, output.result.artifactLayout.submissionRoot)
          ),
          writeFiles(reports, filesUnder(fixtureFiles, "grader/reports")),
          writeFiles(graderSource, filesUnder(fixtureFiles, "grader/source")),
        ]);

        const taskDirectory = path.join(graderSource, "tasks", item.input.taskId);
        const gradeScript = path.join(taskDirectory, "grade.sh");
        if (!(await Bun.file(gradeScript).exists())) {
          throw new Error(`TeamBench grade.sh is missing: ${item.input.taskId}`);
        }
        const expectedPath = path.join(reports, "expected.json");
        const command = [
          "bash",
          `/eval/grader-source/tasks/${item.input.taskId}/grade.sh`,
          "/eval/workspace",
          "/eval/reports",
          "/eval/submission",
          `/eval/grader-source/tasks/${item.input.taskId}`,
          ...((await Bun.file(expectedPath).exists())
            ? ["/eval/reports/expected.json"]
            : []),
        ];
        const graderImage =
          output.result.executionEnvironment.image ?? DEFAULT_TEAM_BENCH_RUNTIME_IMAGE;
        const grader = await runGrader({
          command,
          root,
          timeoutMs: output.result.executionEnvironment.graderTimeoutMs ?? 300_000,
          image: graderImage,
        });
        const scorePath = path.join(reports, "score.json");
        if (!(await Bun.file(scorePath).exists())) {
          throw new Error(
            `TeamBench grader produced no score.json for ${item.input.taskId}; ` +
              `exit=${grader.exitCode}; stderr=${grader.stderr.slice(-4_000)}`
          );
        }
        const rawScoreText = await Bun.file(scorePath).text();
        const official = OfficialScore.parse(JSON.parse(rawScoreText));

        const attestationPath = path.join(submission, "attestation.json");
        const attestationPresent = await Bun.file(attestationPath).exists();
        let verifierVerdict: "pass" | "fail" | "invalid" | "missing" = "missing";
        if (attestationPresent) {
          try {
            verifierVerdict = VerifierAttestation.parse(
              await Bun.file(attestationPath).json()
            ).verdict;
          } catch {
            verifierVerdict = "invalid";
          }
        }

        const attestationModes = new Set(
          item.expected.attestationFailureModes.map((mode) => mode.toLowerCase())
        );
        const onlyAttestationFailure =
          official.failure_modes.length > 0 &&
          official.failure_modes.every(
            (mode) =>
              attestationModes.has(mode.toLowerCase()) ||
              mode.toLowerCase().includes("attestation")
          );
        const paperPromotedPass = official.pass || onlyAttestationFailure;
        const partialScore =
          official.secondary?.partial_score ?? (official.pass ? 1 : 0);
        const verifierApproved = verifierVerdict === "pass";
        const protocolViolations = output.result.collaboration.protocolViolations ?? [];
        const topologySatisfied =
          output.result.collaboration.topologySatisfied ??
          protocolViolations.length === 0;
        const score = {
          rawGraderPass: official.pass ? 1 : 0,
          paperPromotedPass: paperPromotedPass ? 1 : 0,
          partialScore,
          attestationPresent: attestationPresent ? 1 : 0,
          verifierApproved: verifierApproved ? 1 : 0,
          falseAccept: verifierApproved && !paperPromotedPass ? 1 : 0,
          falseReject: verifierVerdict === "fail" && paperPromotedPass ? 1 : 0,
          delegated: output.result.collaboration.delegated ? 1 : 0,
          topologySatisfied: topologySatisfied ? 1 : 0,
          settledAtPlannerReturn:
            output.result.collaboration.settledAtPlannerReturn === true ? 1 : 0,
          protocolViolationCount: protocolViolations.length,
        };
        return {
          score,
          explanation: JSON.stringify({
            taskId: item.input.taskId,
            seed: item.input.seed,
            target: output.result.target,
            verifierVerdict,
            collaboration: output.result.collaboration,
            grader: {
              image: graderImage,
              command,
              exitCode: grader.exitCode,
              stdout: grader.stdout,
              stderr: grader.stderr,
              rawScoreText,
            },
          }),
        };
      } finally {
        await rm(root, { recursive: true, force: true });
      }
    },
  } satisfies Evaluator<TeamBenchDatasetItem, TeamBenchRunResult, {}>;
}

export const teamBenchNativeEvaluator = createTeamBenchNativeEvaluator();

export type TeamBenchNativeEvaluators = readonly [typeof teamBenchNativeEvaluator];

export const teamBenchNativeAggregator = {
  version: "1",
  aggregate(groups: {
    "teambench-native-grader"?: Array<{
      score: Record<(typeof SCORE_KEYS)[number], number>;
    }>;
  }) {
    const results = groups["teambench-native-grader"] ?? [];
    return Object.fromEntries(
      SCORE_KEYS.map((key) => [
        key,
        results.length === 0
          ? 0
          : results.reduce((total, result) => total + result.score[key], 0) /
            results.length,
      ])
    );
  },
};

async function runDockerGrader({
  command,
  root,
  timeoutMs,
  image,
}: Parameters<TeamBenchGraderRunner>[0]): Promise<GraderResult> {
  await mkdir(root, { recursive: true });
  const containerName = `evalens-teambench-grader-${crypto.randomUUID().slice(0, 12)}`;
  const dockerCommand = [
    "docker",
    "run",
    "--rm",
    "--name",
    containerName,
    "--network",
    "none",
    "--user",
    `${process.getuid?.() ?? 10001}:${process.getgid?.() ?? 10001}`,
    "--env",
    "HOME=/tmp",
    "--mount",
    `type=bind,src=${root},dst=/eval`,
    "--workdir",
    "/eval",
    "--entrypoint",
    "/usr/bin/env",
    image,
    ...command,
  ];
  const grader = Bun.spawn(dockerCommand, {
    stdout: "pipe",
    stderr: "pipe",
    env: process.env,
  });
  const stdoutPromise = new Response(grader.stdout).text();
  const stderrPromise = new Response(grader.stderr).text();
  let timeout: ReturnType<typeof setTimeout> | undefined;
  const exitCode = await Promise.race([
    grader.exited,
    new Promise<never>((_resolve, reject) => {
      timeout = setTimeout(() => {
        grader.kill();
        void removeDockerContainer(containerName);
        reject(
          new Error(`TeamBench grader timed out after ${timeoutMs}ms: ${command[1]}`)
        );
      }, timeoutMs);
    }),
  ]).finally(() => {
    if (timeout) clearTimeout(timeout);
  });
  const [stdout, stderr] = await Promise.all([stdoutPromise, stderrPromise]);
  return { exitCode, stdout, stderr };
}

async function removeDockerContainer(name: string): Promise<void> {
  const cleanup = Bun.spawn(["docker", "rm", "--force", name], {
    stdout: "ignore",
    stderr: "ignore",
    env: process.env,
  });
  await cleanup.exited;
}
