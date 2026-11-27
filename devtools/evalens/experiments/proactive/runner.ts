import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { z } from "zod";

import { ProactiveObservationSchema, type ProactiveObservation } from "./contracts";
import type { ProactiveScenarioInput } from "./dataset";

const RecordedShadowFileSchema = z
  .object({
    revision: z.string().min(1).optional(),
    model: z.string().min(1).optional(),
    results: z.array(
      z
        .object({
          item: z
            .object({
              item_id: z.string().min(1),
            })
            .loose(),
          result: z
            .object({
              outcome: z.enum(["routed", "quiet", "deferred"]),
              decision: z.enum([
                "interrupt",
                "ask",
                "signal",
                "briefing",
                "resolved",
                "unclear",
              ]),
              role: z.string().nullable().optional(),
              pool: z.string().nullable().optional(),
              message: z.string().nullable().optional(),
              reason: z.string().nullable().optional(),
              research: z
                .object({
                  local: z.array(z.unknown()).optional(),
                  queries: z
                    .array(
                      z
                        .object({
                          source: z.string().min(1),
                          query: z.string().min(1),
                        })
                        .loose()
                    )
                    .optional(),
                })
                .nullable()
                .optional(),
              prompt_bytes: z.number().int().nonnegative(),
              llm_calls: z.number().int().nonnegative(),
              latency_ms: z.number().int().nonnegative(),
            })
            .loose(),
        })
        .strict()
    ),
  })
  .loose();

const MixRunnerOutputSchema = z
  .object({
    observations: z.array(ProactiveObservationSchema).min(1),
  })
  .strict();

export async function loadRecordedObservations(
  resultsPath: string
): Promise<Map<string, ProactiveObservation>> {
  const rawText = await readFile(resultsPath, "utf8");
  const parsed = RecordedShadowFileSchema.parse(JSON.parse(rawText));
  const byId = new Map<string, ProactiveObservation>();
  for (const row of parsed.results) {
    const r = row.result;
    const research = r.research
      ? {
          localMatches: r.research.local?.length ?? 0,
          queries: (r.research.queries ?? []).map((q) => ({
            source: q.source,
            query: q.query,
          })),
        }
      : undefined;
    const observation = ProactiveObservationSchema.parse({
      itemId: row.item.item_id,
      outcome: r.outcome,
      decision: r.decision,
      ...(r.role ? { role: r.role } : {}),
      ...(r.pool ? { pool: r.pool } : {}),
      ...(r.message ? { message: r.message } : {}),
      ...(r.reason ? { reason: r.reason } : {}),
      ...(research ? { research } : {}),
      promptBytes: r.prompt_bytes,
      llmCalls: r.llm_calls,
      latencyMs: r.latency_ms,
    });
    byId.set(observation.itemId, observation);
  }
  return byId;
}

export interface ExecuteProactiveScenarioOptions {
  systemsDir: string;
  runnerScriptPath: string;
  scenario: ProactiveScenarioInput;
  model: string;
  baseUrl?: string;
  timeoutMs: number;
}

export async function executeProactiveScenario(
  options: ExecuteProactiveScenarioOptions
): Promise<ProactiveObservation[]> {
  const workDir = await mkdtemp(path.join(os.tmpdir(), "evalens-proactive-"));
  const inputPath = path.join(workDir, "input.json");
  const outputPath = path.join(workDir, "output.json");

  await writeFile(inputPath, JSON.stringify(options.scenario), "utf8");
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
          `proactive Elixir runner failed (exit ${exitCode}): ${stderr.slice(-600)}`
        );
      }
    } finally {
      clearTimeout(timer);
    }

    const rawOut = await readFile(outputPath, "utf8");
    const parsed = MixRunnerOutputSchema.parse(JSON.parse(rawOut));
    return parsed.observations;
  } finally {
    await rm(workDir, { recursive: true, force: true });
  }
}
