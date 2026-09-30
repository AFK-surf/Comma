import {
  DatasetItem,
  defineDatasetLoader,
  type LoadedDatasetItem,
} from "@evalens/core";
import { z } from "zod";

import {
  SlackProviderExternalAssertionSchema,
  SlackProviderForbiddenOutcomeSchema,
  SlackSetupActionSchema,
} from "./dataset";

export const SlackWorkflowTurnSchema = z.discriminatedUnion("action", [
  z
    .object({
      action: z.literal("post_user_mention"),
      alias: z.string().min(1),
      text: z.string().min(1),
    })
    .strict(),
  z
    .object({
      action: z.literal("post_user_thread_reply"),
      alias: z.string().min(1),
      target: z.string().min(1),
      text: z.string().min(1),
    })
    .strict(),
  z
    .object({
      action: z.literal("post_other_app_mention"),
      alias: z.string().min(1),
      text: z.string().min(1),
    })
    .strict(),
  z
    .object({
      action: z.literal("post_user_message"),
      alias: z.string().min(1),
      text: z.string().min(1),
    })
    .strict(),
]);

const SlackWorkflowSpecificExternalAssertionSchema = z.discriminatedUnion("kind", [
  z.object({ kind: z.literal("no_duplicate_thread_replies") }).strict(),
  z
    .object({
      kind: z.literal("turn_input_observed"),
      target: z.string().min(1),
      value: z.boolean(),
    })
    .strict(),
  z
    .object({
      kind: z.literal("turns_share_thread"),
      targets: z.array(z.string().min(1)).min(2),
    })
    .strict(),
  z
    .object({
      kind: z.literal("trigger_authored_by_bot"),
      target: z.string().min(1),
    })
    .strict(),
  z
    .object({
      kind: z.literal("thread_reply_count"),
      target: z.string().min(1),
      value: z.number().int().nonnegative(),
    })
    .strict(),
]);

const SlackWorkflowSpecificForbiddenOutcomeSchema = z.discriminatedUnion("kind", [
  z.object({ kind: z.literal("duplicate_thread_reply") }).strict(),
  z.object({ kind: z.literal("unsolicited_agent_reply") }).strict(),
]);

export const SlackWorkflowExternalAssertionSchema = z.union([
  SlackProviderExternalAssertionSchema,
  SlackWorkflowSpecificExternalAssertionSchema,
]);

export const SlackWorkflowForbiddenOutcomeSchema = z.union([
  SlackProviderForbiddenOutcomeSchema,
  SlackWorkflowSpecificForbiddenOutcomeSchema,
]);

const Expected = z
  .object({
    externalAssertions: z.array(SlackWorkflowExternalAssertionSchema),
    semanticCriteria: z.array(z.string().min(1)),
    forbiddenOutcomes: z.array(SlackWorkflowForbiddenOutcomeSchema),
  })
  .strict();

const OneShotInput = z
  .object({
    slackSetup: z.array(SlackSetupActionSchema),
    slackTrigger: z.object({ text: z.string().min(1) }).strict(),
  })
  .strict();

const SequenceInput = z
  .object({
    slackSetup: z.array(SlackSetupActionSchema),
    slackTurns: z.array(SlackWorkflowTurnSchema).min(1),
  })
  .strict();

export const SlackWorkflowDatasetItem = DatasetItem.extend({
  input: z.union([OneShotInput, SequenceInput]),
  expected: Expected,
});

export type SlackWorkflowDatasetItem = LoadedDatasetItem<
  typeof SlackWorkflowDatasetItem
>;
export type SlackWorkflowTurn = z.infer<typeof SlackWorkflowTurnSchema>;
export type SlackWorkflowExternalAssertion = z.infer<
  typeof SlackWorkflowExternalAssertionSchema
>;
export type SlackWorkflowForbiddenOutcome = z.infer<
  typeof SlackWorkflowForbiddenOutcomeSchema
>;

export const loadSlackWorkflowDataset = defineDatasetLoader({
  name: "slack-agent-workflows-live",
  digest: "8c8ff9e1d820b590a3c60c56883b8c43dc29f27804b7a53430e8ef1c732e61b3",
  itemSchema: SlackWorkflowDatasetItem,
});
