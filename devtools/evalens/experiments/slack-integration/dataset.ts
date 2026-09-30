import { DatasetItem, type LoadedDatasetItem } from "@evalens/core";
import { z } from "zod";

export const SlackSetupActionSchema = z.discriminatedUnion("action", [
  z
    .object({
      action: z.literal("post_message"),
      alias: z.string().min(1),
      text: z.string().min(1),
    })
    .strict(),
  z
    .object({
      action: z.literal("post_thread_reply"),
      alias: z.string().min(1),
      target: z.string().min(1),
      text: z.string().min(1),
    })
    .strict(),
  z
    .object({
      action: z.literal("upload_file"),
      alias: z.string().min(1),
      filename: z.string().min(1),
      content: z.string(),
    })
    .strict(),
  z
    .object({
      action: z.literal("add_reaction"),
      target: z.string().min(1),
      name: z.string().min(1),
    })
    .strict(),
  z
    .object({
      action: z.literal("pin_message"),
      target: z.string().min(1),
    })
    .strict(),
]);

export const SlackProviderExternalAssertionSchema = z.discriminatedUnion("kind", [
  z
    .object({
      kind: z.literal("thread_read_observed"),
      target: z.string().min(1),
    })
    .strict(),
  z
    .object({
      kind: z.literal("driver_dm_contains"),
      text: z.string().min(1),
    })
    .strict(),
  z
    .object({
      kind: z.literal("permalink_read_observed"),
      target: z.string().min(1),
    })
    .strict(),
  z.object({ kind: z.literal("channel_history_read_observed") }).strict(),
  z
    .object({
      kind: z.literal("attachment_fetch_observed"),
      target: z.string().min(1),
    })
    .strict(),
  z
    .object({
      kind: z.literal("thread_file_matches"),
      filename: z.string().min(1).optional(),
      mimetype: z.string().min(1).optional(),
      content: z.string().optional(),
      contains: z.array(z.string().min(1)).optional(),
    })
    .strict()
    .refine(
      ({ filename, mimetype, content, contains }) =>
        filename !== undefined ||
        mimetype !== undefined ||
        content !== undefined ||
        contains !== undefined,
      "thread_file_matches requires at least one expected file property"
    ),
  z
    .object({
      kind: z.literal("message_created_then_updated"),
      initialText: z.string().min(1),
      finalText: z.string().min(1),
    })
    .strict(),
  z
    .object({
      kind: z.literal("message_created_then_deleted"),
      text: z.string().min(1),
    })
    .strict(),
  z
    .object({
      kind: z.literal("reaction_state"),
      target: z.string().min(1),
      name: z.string().min(1),
      present: z.boolean(),
    })
    .strict(),
  z
    .object({
      kind: z.literal("pin_state"),
      target: z.string().min(1),
      present: z.boolean(),
    })
    .strict(),
  z
    .object({
      kind: z.literal("channel_topic_equals"),
      text: z.string(),
    })
    .strict(),
  z
    .object({
      kind: z.literal("channel_purpose_equals"),
      text: z.string(),
    })
    .strict(),
  z
    .object({
      kind: z.literal("canvas_created_then_edited"),
      title: z.string().min(1),
      contains: z.array(z.string().min(1)),
    })
    .strict(),
  z
    .object({
      kind: z.literal("canvas_access"),
      title: z.string().min(1),
      user: z.literal("driver_user"),
      accessLevel: z.string().min(1),
      contains: z.array(z.string().min(1)).optional(),
    })
    .strict(),
  z
    .object({
      kind: z.literal("provider_failure_acknowledged"),
      operation: z.literal("remove_reaction"),
    })
    .strict(),
  z
    .object({
      kind: z.literal("created_message_reaction_state"),
      text: z.string().min(1),
      name: z.string().min(1),
    })
    .strict(),
  z
    .object({
      kind: z.literal("created_message_pin_state"),
      text: z.string().min(1),
    })
    .strict(),
]);

export const SlackProviderForbiddenOutcomeSchema = z.discriminatedUnion("kind", [
  z.object({ kind: z.literal("secret_disclosure") }).strict(),
  z.object({ kind: z.literal("unrelated_write") }).strict(),
  z.object({ kind: z.literal("false_success_claim") }).strict(),
]);

export const SlackProviderActionDatasetItem = DatasetItem.extend({
  input: z
    .object({
      slackSetup: z.array(SlackSetupActionSchema),
      slackTrigger: z.object({ text: z.string().min(1) }).strict(),
    })
    .strict(),
  expected: z
    .object({
      externalAssertions: z.array(SlackProviderExternalAssertionSchema),
      semanticCriteria: z.array(z.string().min(1)),
      forbiddenOutcomes: z.array(SlackProviderForbiddenOutcomeSchema),
    })
    .strict(),
});

export type SlackProviderActionDatasetItem = LoadedDatasetItem<
  typeof SlackProviderActionDatasetItem
>;
export type SlackSetupAction = z.infer<typeof SlackSetupActionSchema>;
export type SlackProviderExternalAssertion = z.infer<
  typeof SlackProviderExternalAssertionSchema
>;
export type SlackProviderForbiddenOutcome = z.infer<
  typeof SlackProviderForbiddenOutcomeSchema
>;
