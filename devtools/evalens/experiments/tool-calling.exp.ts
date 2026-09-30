import { SalixAdapter, type Salix } from "@evalens/adapters/salix";
import { defineExperiment, NoParamsSchema, type Evaluator } from "@evalens/core";
import {
  loadToolCallingDataset,
  type ToolCallingDatasetItem,
} from "./tool-calling.dataset";

type ToolCallingResult = {
  answer: string;
  targetRole: "router" | "worker";
};

const toolCallsEvaluator = {
  name: "tool-calls",
  version: "1",
  evaluate(item, output) {
    const calls =
      output.trajectories?.flatMap((trajectory) =>
        trajectory.steps.filter((step) => step.type === "tool_call")
      ) ?? [];
    const names = calls.map((call) => call.name);
    const required = item.expected.requiredToolCalls;
    const matched = required.filter(
      (expectation) =>
        names.filter((name) => name === expectation.toolName).length >=
        (expectation.minCount ?? 1)
    );
    const forbidden = (item.expected.forbiddenToolCalls ?? []).filter((expectation) =>
      names.includes(expectation.toolName)
    );
    const requiredScore = required.length === 0 ? 1 : matched.length / required.length;
    return {
      score: { toolCalls: forbidden.length === 0 ? requiredScore : 0 },
      explanation: `matched ${matched.length}/${required.length} required calls; observed ${names.join(", ") || "none"}`,
    };
  },
} satisfies Evaluator<ToolCallingDatasetItem, ToolCallingResult, {}>;

type ToolCallingEvaluators = readonly [typeof toolCallsEvaluator];

type EvalAgent = NonNullable<Salix.EvalFixture["agents"]>[number];

export function requireSalixTemplateId(templateId: string | undefined): string {
  if (!templateId) {
    throw new Error("salix.templateId is required for the tool-calling experiment");
  }
  return templateId;
}

export function toolCallingAgent(
  role: "router" | "worker",
  template: string,
  workerRef: string
): EvalAgent {
  return {
    role,
    template,
    ...(role === "worker" ? { ref: workerRef } : {}),
    systemPrompt:
      "Use the available tools exactly as requested and report their results.",
  };
}

export default defineExperiment<
  ToolCallingDatasetItem,
  ToolCallingResult,
  ToolCallingEvaluators,
  typeof NoParamsSchema,
  typeof NoParamsSchema,
  readonly ["salix"],
  readonly []
>({
  name: "salix-tool-calling",
  description: "Checks Salix tool usage through normalized Evalens trajectories.",
  metadata: { tags: ["salix", "tool-calling", "live"] },
  adapters: { run: ["salix"], eval: [] },
  datasetLoader: loadToolCallingDataset,
  async runItem(item, context) {
    const salix = new SalixAdapter(context.adapterConfig.salix);
    const workerRef = "tool-worker";
    const templateId = requireSalixTemplateId(context.adapterConfig.salix.templateId);
    const prepared = await salix.runs.prepareRun({
      name: `tool-calling-${item.id}`,
      agents: [toolCallingAgent(item.input.targetAgentRole, templateId, workerRef)],
    });
    const target = salix.runs.agentSession(
      prepared,
      item.input.targetAgentRole === "router"
        ? { role: "router" }
        : { role: "worker", workerRef }
    );
    try {
      const turn = await salix.sessions.runSessionTurn({
        target,
        turnId: `tool-calling:${item.id}`,
        message: item.input.task,
        context: item.input.context,
        traceLimit: 500,
      });
      return {
        result: {
          answer: turn.answer ?? "",
          targetRole: item.input.targetAgentRole,
        },
        trajectories: [turn.trajectory],
      };
    } finally {
      await salix.runs.cleanupRun(prepared);
    }
  },
  evaluators: [toolCallsEvaluator],
  aggregator: {
    version: "1",
    aggregate: (groups) => {
      const results = groups["tool-calls"] ?? [];
      return {
        toolCalls:
          results.length === 0
            ? 0
            : results.reduce((total, result) => total + result.score.toolCalls, 0) /
              results.length,
      };
    },
  },
});
