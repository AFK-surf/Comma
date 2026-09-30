import { SalixAdapter } from "@evalens/adapters/salix";
import { defineExperiment, NoParamsSchema } from "@evalens/core";
import { codexEvaluator } from "@evalens/evaluators/codex";
import { loadContextCompressionDataset, type ContextCompressionItem } from "./dataset";

type CompactionVariant = "summary" | "openai_responses";
type ContextCompressionResult = {
  answer: string;
  compactStatus: string;
  compactReason: string | null;
};

const retainedFactsEvaluator = codexEvaluator<
  ContextCompressionItem,
  ContextCompressionResult,
  {}
>({
  name: "retained-facts",
  version: "3",
  model: "gpt-5.5",
  rubric: (item) => `Judge semantic retention in result.answer.

Required facts:
${JSON.stringify(item.expected.retainedFacts)}

Forbidden claims:
${JSON.stringify(item.expected.forbiddenClaims ?? [])}

Count a required fact as retained when the answer explicitly states it or an unambiguous paraphrase. Do not require exact wording. The score is retained required facts divided by total required facts; use 1 when there are no required facts. If the answer asserts any forbidden claim as a current fact, set the score to 0. Merely negating, correcting, or identifying a forbidden claim as obsolete does not trigger that penalty. Explain which required facts were retained or missing and whether a forbidden claim was asserted.`,
});

type ContextCompressionEvaluators = readonly [typeof retainedFactsEvaluator];

export function defineSalixContextCompressionExperiment(options: {
  name: string;
  variant: CompactionVariant;
}) {
  return defineExperiment<
    ContextCompressionItem,
    ContextCompressionResult,
    ContextCompressionEvaluators,
    typeof NoParamsSchema,
    typeof NoParamsSchema,
    readonly ["salix"],
    readonly ["codex"]
  >({
    name: options.name,
    description: `Checks retained facts after Salix ${options.variant} compaction.`,
    metadata: {
      tags: ["salix", "router", "context-compression", options.variant],
    },
    adapters: { run: ["salix"], eval: ["codex"] },
    datasetLoader: loadContextCompressionDataset,
    async runItem(item, context) {
      const salix = new SalixAdapter(context.adapterConfig.salix);
      const prepared = await salix.runs.prepareRun({
        name: `${options.name}-${item.id}`,
        agents: [
          {
            role: "router",
            template: context.adapterConfig.salix.templateId,
            systemPrompt:
              "Retain facts from the conversation faithfully. Answer the final probe using only known facts.",
            metadata: { compactionVariant: options.variant },
          },
        ],
      });
      const target = salix.runs.agentSession(prepared, { role: "router" });
      try {
        await salix.transcripts.seedAgentTranscript({
          agentId: target.agentId,
          sessionId: target.sessionId,
          sourceId: `evalens:${item.id}`,
          entries: salix.transcripts.buildTranscriptSeedEntries(item.input.history, {
            sourcePrefix: `evalens:${item.id}:history`,
          }),
        });
        const compact = await salix.transcripts.compactAgentSession({
          agentId: target.agentId,
          sessionId: target.sessionId,
        });
        const turn = await salix.sessions.runSessionTurn({
          target,
          turnId: `context-compression:${item.id}`,
          message: item.input.probe.message,
          traceLimit: 200,
        });
        return {
          result: {
            answer: turn.answer ?? "",
            compactStatus: compact.status ?? "unknown",
            compactReason: compact.reason ?? null,
          },
          trajectories: [turn.trajectory],
        };
      } finally {
        await salix.runs.cleanupRun(prepared);
      }
    },
    evaluators: [retainedFactsEvaluator],
    aggregator: {
      version: "1",
      aggregate: (groups) => {
        const results = groups["retained-facts"] ?? [];
        return {
          retainedFacts:
            results.length === 0
              ? 0
              : results.reduce((total, result) => total + result.score.score, 0) /
                results.length,
        };
      },
    },
  });
}
