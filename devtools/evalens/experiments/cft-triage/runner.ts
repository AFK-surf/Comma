import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { z } from "zod";

import { CftTriageObservationSchema, type CftTriageObservation } from "./contracts";
import type { CftScenarioPayload } from "./dataset";

const RecordedCftResultsFileSchema = z
  .object({
    revision: z.string().min(1).optional(),
    model: z.string().min(1).optional(),
    observations: z.array(CftTriageObservationSchema).min(1),
  })
  .loose();

const MixCftRunnerOutputSchema = z
  .object({
    observation: CftTriageObservationSchema,
  })
  .strict();

export async function loadRecordedCftObservations(
  resultsPath: string
): Promise<Map<string, CftTriageObservation>> {
  const rawText = await readFile(resultsPath, "utf8");
  const parsed = RecordedCftResultsFileSchema.parse(JSON.parse(rawText));
  const byId = new Map<string, CftTriageObservation>();
  for (const observation of parsed.observations) {
    byId.set(observation.itemId, observation);
  }
  return byId;
}

export interface ExecuteCftScenarioOptions {
  systemsDir: string;
  runnerScriptPath: string;
  payload: CftScenarioPayload;
  model: string;
  baseUrl?: string;
  timeoutMs: number;
}

export async function executeCftScenario(
  options: ExecuteCftScenarioOptions
): Promise<CftTriageObservation> {
  const workDir = await mkdtemp(path.join(os.tmpdir(), "evalens-cft-triage-"));
  const inputPath = path.join(workDir, "input.json");
  const outputPath = path.join(workDir, "output.json");

  await writeFile(inputPath, JSON.stringify(options.payload), "utf8");
  try {
    const args = [
      "mix",
      "run",
      "--no-start",
      "--no-compile",
      options.runnerScriptPath,
      "--input",
      inputPath,
      "--out",
      outputPath,
      "--model",
      options.model,
    ];
    if (options.baseUrl) {
      args.push("--base-url", options.baseUrl);
    }

    const proc = Bun.spawn(args, {
      cwd: options.systemsDir,
      stdout: "pipe",
      stderr: "pipe",
      env: { ...process.env, MIX_ENV: process.env.MIX_ENV ?? "test" },
    });

    const timer = setTimeout(() => {
      proc.kill();
    }, options.timeoutMs);

    try {
      const [exitCode, stderr] = await Promise.all([
        proc.exited,
        new Response(proc.stderr).text(),
      ]);
      if (exitCode !== 0) {
        throw new Error(
          `cft-triage Elixir runner failed (exit ${exitCode}): ${stderr.slice(-600)}`
        );
      }
    } finally {
      clearTimeout(timer);
    }

    const rawOut = await readFile(outputPath, "utf8");
    const parsed = MixCftRunnerOutputSchema.parse(JSON.parse(rawOut));
    return parsed.observation;
  } finally {
    await rm(workDir, { recursive: true, force: true });
  }
}
