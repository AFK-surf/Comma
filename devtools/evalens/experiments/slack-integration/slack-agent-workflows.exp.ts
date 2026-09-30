import { CodexCliAdapter } from "@evalens/adapters/codex";
import type { CodexAdapterConfig } from "@evalens/adapters/config";
import { type Salix, SalixAdapter } from "@evalens/adapters/salix";
import { createSlackEvaluationTools } from "@evalens/adapters/slack";
import { defineExperiment, type Evaluator } from "@evalens/core";
import { mean, ratio } from "@evalens/utils/math";
import { z } from "zod";

import {
  SlackProviderExternalAssertionSchema,
  type SlackProviderExternalAssertion,
} from "./dataset";
import {
  evaluateExternalAssertion,
  evaluateForbiddenOutcome,
} from "./provider-action-evaluation";
import {
  loadSlackWorkflowDataset,
  type SlackWorkflowDatasetItem,
  type SlackWorkflowExternalAssertion,
  type SlackWorkflowForbiddenOutcome,
} from "./workflow-dataset";
import { runSlackWorkflowItem, type SlackWorkflowResult } from "./workflow-shared";

const RunParamsSchema = z
  .object({
    channelId: z.string().min(1),
    agentTimeoutMs: z.number().int().positive().default(180_000),
    slackSettleMs: z.number().int().nonnegative().default(2_000),
    silenceObservationMs: z.number().int().positive().default(5_000),
  })
  .strict();

const EvalParamsSchema = z
  .object({ semanticThreshold: z.number().min(0).max(1).default(0.8) })
  .strict();

type EvalParams = z.output<typeof EvalParamsSchema>;
type EvalAdapterConfig = { codex: CodexAdapterConfig };
type DeterministicScore = {
  delivery: number;
  external_assertions: number;
  safety: number;
};
type SemanticScore = { semantic: number; semantic_pass: number };

const deterministicEvaluator = {
  name: "slack-workflow-deterministic",
  version: "1",
  evaluate(item, output) {
    const external = item.expected.externalAssertions.map((assertion) => ({
      assertion,
      passed: evaluateWorkflowAssertion(assertion, output.result),
    }));
    const forbidden = item.expected.forbiddenOutcomes.map((assertion) => ({
      assertion,
      occurred: evaluateWorkflowForbidden(
        assertion,
        output.result,
        item.expected.externalAssertions
      ),
    }));
    const addressedTurns = output.result.turns.filter(
      (turn) => turn.action !== "post_user_message"
    );
    const delivery = workflowExpectsOnlySilence(item)
      ? output.result.threadReplies.length === 0
      : addressedTurns.length > 0 &&
        addressedTurns.every((turn) => turn.inputObserved && turn.replies.length > 0);
    return {
      score: {
        delivery: delivery ? 1 : 0,
        external_assertions: ratio(external.map((entry) => entry.passed)),
        safety: ratio(forbidden.map((entry) => !entry.occurred)),
      },
      explanation: JSON.stringify({
        failedAssertions: external
          .filter((entry) => !entry.passed)
          .map((entry) => entry.assertion),
        forbiddenOutcomes: forbidden
          .filter((entry) => entry.occurred)
          .map((entry) => entry.assertion),
        turns: output.result.turns.map((turn) => ({
          alias: turn.alias,
          action: turn.action,
          inputObserved: turn.inputObserved,
          replyCount: turn.replies.length,
        })),
      }),
    };
  },
} satisfies Evaluator<
  SlackWorkflowDatasetItem,
  SlackWorkflowResult,
  EvalParams,
  EvalAdapterConfig
>;

const SemanticResult = z
  .object({
    score: z.number().min(0).max(1),
    explanation: z.string().optional(),
  })
  .strict();

const semanticEvaluator = {
  name: "slack-workflow-semantic",
  version: "1",
  async evaluate(item, output, context) {
    if (workflowExpectsOnlySilence(item)) {
      return {
        score: { semantic: 1, semantic_pass: 1 },
        explanation: "Silence scenario is scored by deterministic observation.",
      };
    }
    if (output.result.threadReplies.length === 0) {
      return {
        score: { semantic: 0, semantic_pass: 0 },
        explanation: "No Agent reply in the workflow thread.",
      };
    }
    const adapter = new CodexCliAdapter(context.adapterConfig.codex);
    const result = await adapter.runTask({
      task: [
        "Judge only content actually delivered to the user in the Slack workflow thread.",
        "Treat earlier and later turn replies as one ordered interaction.",
        'Return only JSON: {"score": number from 0 to 1, "explanation": optional string}.',
        `Criteria: ${JSON.stringify(item.expected.semanticCriteria)}`,
        `Workflow turns: ${JSON.stringify(
          output.result.turns.map((turn) => ({
            alias: turn.alias,
            action: turn.action,
          }))
        )}`,
        `Final delivered replies: ${JSON.stringify(
          output.result.threadReplies.map((reply) => reply.text)
        )}`,
        `Delivered files: ${JSON.stringify(
          output.result.threadFiles.map((file) => ({
            name: file.name,
            mimetype: file.mimetype,
            content: file.content,
          }))
        )}`,
      ].join("\n\n"),
    });
    if (result.exitCode !== 0) {
      throw new Error(result.codexErrorMessage ?? "Codex semantic evaluator failed");
    }
    const parsed = SemanticResult.parse(JSON.parse(result.finalAnswer));
    return {
      score: {
        semantic: parsed.score,
        semantic_pass: parsed.score >= context.params.semanticThreshold ? 1 : 0,
      },
      ...(parsed.explanation ? { explanation: parsed.explanation } : {}),
    };
  },
} satisfies Evaluator<
  SlackWorkflowDatasetItem,
  SlackWorkflowResult,
  EvalParams,
  EvalAdapterConfig
>;

type WorkflowEvaluators = readonly [
  typeof deterministicEvaluator,
  typeof semanticEvaluator,
];

export default defineExperiment<
  SlackWorkflowDatasetItem,
  SlackWorkflowResult,
  WorkflowEvaluators,
  typeof RunParamsSchema,
  typeof EvalParamsSchema,
  readonly ["salix", "slack"],
  readonly ["codex"]
>({
  name: "slack-agent-workflows-live",
  description:
    "Evaluates real Slack Agent workflows including multi-turn correction, bot-authored delegation, duplicate-safe delivery, and unaddressed-message silence.",
  metadata: { tags: ["salix", "slack", "agent", "workflow", "live"] },
  params: { run: RunParamsSchema, eval: EvalParamsSchema },
  adapters: {
    run: ["salix", "slack"],
    eval: ["codex"],
  },
  datasetLoader: loadSlackWorkflowDataset,
  async runItem(item, context) {
    const salix = new SalixAdapter(context.adapterConfig.salix);
    const slack = createSlackEvaluationTools(context.adapterConfig.slack);
    const otherAppDriverConfig = context.adapterConfig.slack.otherAppDriver;
    const { otherAppDriver: _otherAppDriver, ...sharedSlackConfig } =
      context.adapterConfig.slack;
    const otherAppDriver = otherAppDriverConfig
      ? createSlackEvaluationTools({
          ...sharedSlackConfig,
          token: otherAppDriverConfig.token,
          expectedUserId: otherAppDriverConfig.expectedBotUserId,
        })
      : undefined;
    const slackConnectFixture = salix.integrations.requireFixture({
      id: "slack",
    });
    if (slackConnectFixture.credentials.type !== "app") {
      throw new Error("Salix integration 'slack' must use app credentials");
    }
    const slackAppFixture = slackConnectFixture as Readonly<Salix.AppIntegrationConfig>;
    const prepared = await salix.runs.prepareRun({
      name: `slack-agent-workflows-live-${item.id}`,
      agents: [
        {
          role: "router",
          template: context.adapterConfig.salix.templateId,
          metadata: { evalensRunId: context.id, datasetItemId: item.id },
        },
      ],
    });
    try {
      const run = await runSlackWorkflowItem({
        item,
        salix,
        slack,
        otherAppDriver,
        prepared,
        channelId: context.params.channelId,
        agentTimeoutMs: context.params.agentTimeoutMs,
        slackSettleMs: context.params.slackSettleMs,
        silenceObservationMs: context.params.silenceObservationMs,
        slackConnectFixture: slackAppFixture,
        logger: context.logger,
      });
      return {
        result: run.result,
        artifacts: run.artifacts,
        trajectories: [run.trajectory],
      };
    } finally {
      try {
        await salix.runs.cleanupRun(prepared);
      } catch (error) {
        context.logger.error(
          `Salix cleanup failed: ${error instanceof Error ? error.message : String(error)}`
        );
      }
    }
  },
  evaluators: [deterministicEvaluator, semanticEvaluator] as const,
  aggregator: {
    version: "1",
    aggregate(groups) {
      const deterministic = new Map<string, DeterministicScore>(
        (groups["slack-workflow-deterministic"] ?? []).map((entry) => [
          entry.itemId,
          entry.score as DeterministicScore,
        ])
      );
      const semantic = new Map<string, SemanticScore>(
        (groups["slack-workflow-semantic"] ?? []).map((entry) => [
          entry.itemId,
          entry.score as SemanticScore,
        ])
      );
      const itemIds = [...new Set([...deterministic.keys(), ...semantic.keys()])];
      if (itemIds.length === 0) {
        return {
          workflow_success_rate: 0,
          delivery_rate: 0,
          external_assertions_mean: 0,
          safety_mean: 0,
          semantic_mean: 0,
        };
      }
      const completed = itemIds.map((itemId) => ({
        exact: deterministic.get(itemId) ?? {
          delivery: 0,
          external_assertions: 0,
          safety: 0,
        },
        meaning: semantic.get(itemId) ?? { semantic: 0, semantic_pass: 0 },
      }));
      return {
        workflow_success_rate: ratio(
          completed.map(
            ({ exact, meaning }) =>
              exact.delivery === 1 &&
              exact.external_assertions === 1 &&
              exact.safety === 1 &&
              meaning.semantic_pass === 1
          )
        ),
        delivery_rate: mean(completed.map(({ exact }) => exact.delivery)),
        external_assertions_mean: mean(
          completed.map(({ exact }) => exact.external_assertions)
        ),
        safety_mean: mean(completed.map(({ exact }) => exact.safety)),
        semantic_mean: mean(completed.map(({ meaning }) => meaning.semantic)),
      };
    },
  },
});

export function evaluateWorkflowAssertion(
  assertion: SlackWorkflowExternalAssertion,
  result: SlackWorkflowResult
): boolean {
  if (assertion.kind === "no_duplicate_thread_replies") {
    return !hasDuplicateReplies(result.threadReplies);
  }
  if (assertion.kind === "turn_input_observed") {
    const turn = result.turns.find((candidate) => candidate.alias === assertion.target);
    return turn !== undefined && turn.inputObserved === assertion.value;
  }
  if (assertion.kind === "turns_share_thread") {
    const turns = assertion.targets.flatMap((target) =>
      result.turns.filter((turn) => turn.alias === target)
    );
    return (
      turns.length === assertion.targets.length &&
      new Set(turns.map((turn) => turn.threadTs)).size === 1
    );
  }
  if (assertion.kind === "trigger_authored_by_bot") {
    const turn = result.turns.find((candidate) => candidate.alias === assertion.target);
    return Boolean(
      turn?.source === "other_app_bot" &&
      turn.authorBotId &&
      result.triggerObserved?.botId === turn.authorBotId
    );
  }
  if (assertion.kind === "thread_reply_count") {
    const turn = result.turns.find((candidate) => candidate.alias === assertion.target);
    return turn !== undefined && turn.replies.length === assertion.value;
  }
  return evaluateExternalAssertion(assertion, result);
}

export function evaluateWorkflowForbidden(
  assertion: SlackWorkflowForbiddenOutcome,
  result: SlackWorkflowResult,
  expected: SlackWorkflowExternalAssertion[]
): boolean {
  if (assertion.kind === "duplicate_thread_reply") {
    return hasDuplicateReplies(result.threadReplies);
  }
  if (assertion.kind === "unsolicited_agent_reply") {
    return result.threadReplies.length > 0;
  }
  const providerAssertions = expected.filter(
    (candidate): candidate is SlackProviderExternalAssertion =>
      SlackProviderExternalAssertionSchema.safeParse(candidate).success
  );
  return evaluateForbiddenOutcome(assertion, result, providerAssertions);
}

export function workflowExpectsOnlySilence(item: SlackWorkflowDatasetItem): boolean {
  if (!("slackTurns" in item.input)) return false;
  const zeroReplyTargets = new Set(
    item.expected.externalAssertions.flatMap((assertion) =>
      assertion.kind === "thread_reply_count" && assertion.value === 0
        ? [assertion.target]
        : []
    )
  );
  return item.input.slackTurns.every((turn) => zeroReplyTargets.has(turn.alias));
}

function hasDuplicateReplies(replies: SlackWorkflowResult["threadReplies"]): boolean {
  const keys = replies.map((reply) =>
    JSON.stringify({
      threadTs: reply.threadTs ?? "",
      text: reply.text.replace(/\s+/gu, " ").trim(),
      files: reply.files.map((file) => [file.name ?? "", file.mimetype ?? ""]),
    })
  );
  return new Set(keys).size !== keys.length;
}
