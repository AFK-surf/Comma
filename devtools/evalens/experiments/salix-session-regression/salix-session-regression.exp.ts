import { SalixAdapter, type Salix } from "@evalens/adapters/salix";
import { defineExperiment } from "@evalens/core";
import { z } from "zod";

import {
  loadSalixSessionRegressionDataset,
  type SalixSessionRegressionItem,
} from "./dataset";
import {
  trajectoryRegressionEvaluator,
  type SalixSessionRegressionEvaluators,
  type SalixSessionRegressionResult,
} from "./evaluation";

const RunParams = z
  .object({
    datasetName: z.string().min(1),
    datasetDigest: z.string().regex(/^[a-f0-9]{64}$/u),
    timeoutMs: z.number().int().positive().default(120_000),
  })
  .strict();

const EvalParams = z.strictObject({});
const workerRef = "regression-worker";

export default defineExperiment<
  SalixSessionRegressionItem,
  SalixSessionRegressionResult,
  SalixSessionRegressionEvaluators,
  typeof RunParams,
  typeof EvalParams,
  readonly ["salix"],
  readonly []
>({
  name: "salix-session-regression",
  description:
    "Replays Evalens items derived from L2-confirmed Salix results in fresh isolated sessions and checks bounded trajectory health.",
  metadata: {
    tags: ["salix", "session", "regression", "l2", "trajectory", "live"],
  },
  params: { run: RunParams, eval: EvalParams },
  adapters: { run: ["salix"], eval: [] },
  datasetLoader: loadSalixSessionRegressionDataset,
  async runItem(item, context) {
    const salix = new SalixAdapter(context.adapterConfig.salix);
    const template = context.adapterConfig.salix.templateId;
    if (!template) throw new Error("salix.templateId is required");

    const role = item.input.targetRole;
    const agent: NonNullable<Salix.EvalFixture["agents"]>[number] = {
      role,
      template,
      ...(role === "worker" ? { ref: workerRef } : {}),
    };
    const prepared = await salix.runs.prepareRun({
      name: `session-regression-${item.id}`,
      agents: [agent],
    });
    const target = salix.runs.agentSession(
      prepared,
      role === "router" ? { role: "router" } : { role: "worker", workerRef }
    );

    try {
      const entries = salix.transcripts.buildTranscriptSeedEntries(item.input.history, {
        sourcePrefix: `evalens:${item.id}`,
      });
      await salix.transcripts.seedAgentTranscript({
        agentId: target.agentId,
        sessionId: target.sessionId,
        sourceId: `evalens:${item.id}`,
        entries,
      });
      const turn = await salix.sessions.runSessionTurn({
        target,
        turnId: `salix-session-regression:${item.id}`,
        message: item.input.probe.message,
        routerDeliveryMode: "direct_session",
        timeoutMs: context.params.timeoutMs,
        traceLimit: 500,
      });
      return {
        result: {
          answer: turn.answer ?? "",
          timedOut: turn.replyWait.timedOut === true,
          targetRole: role,
        },
        trajectories: [turn.trajectory],
      };
    } finally {
      await salix.runs.cleanupRun(prepared);
    }
  },
  evaluators: [trajectoryRegressionEvaluator],
  aggregator: {
    version: "1",
    aggregate(groups) {
      const results = groups["trajectory-regression"] ?? [];
      if (results.length === 0) {
        return {
          trajectoryRegression: 0,
          reply: 0,
          repeatedToolCalls: 0,
          consecutiveToolErrors: 0,
        };
      }
      return {
        trajectoryRegression:
          results.reduce(
            (total, result) => total + result.score.trajectoryRegression,
            0
          ) / results.length,
        reply:
          results.reduce((total, result) => total + result.score.reply, 0) /
          results.length,
        repeatedToolCalls:
          results.reduce((total, result) => total + result.score.repeatedToolCalls, 0) /
          results.length,
        consecutiveToolErrors:
          results.reduce(
            (total, result) => total + result.score.consecutiveToolErrors,
            0
          ) / results.length,
      };
    },
  },
});
