import { z } from "zod";

import { AdapterIdentities } from "@evalens/core/adapter";

import {
  DatasetName,
  Digest,
  EvalId,
  EvaluatorIdentities,
  ExperimentName,
  Identifier,
  ItemId,
  LifecycleStatus,
  NonEmptyScore,
  Params,
  type ParamValue,
  RunId,
  Score,
  Tags,
  Timing,
} from "@evalens/core/schemas";

export const RunManifestMetadata = z
  .object({
    formatVersion: z.literal(2),
    runId: RunId,
    sourceRunId: RunId.optional(),
    experimentName: ExperimentName,
    description: z.string().optional(),
    datasetName: DatasetName,
    datasetDigest: Digest,
    datasetSelectionDigest: Digest,
    selectedItemIds: z.array(ItemId).min(1),
    targetItemCount: z.number().int().positive(),
    status: LifecycleStatus,
    params: Params,
    paramsDigest: Digest,
    tags: Tags,
    createdAt: z.coerce.date(),
    finishedAt: z.coerce.date().optional(),
    adapters: AdapterIdentities,
  })
  .strict()
  .superRefine(({ selectedItemIds, targetItemCount }, context) => {
    if (new Set(selectedItemIds).size !== selectedItemIds.length) {
      context.addIssue({
        code: "custom",
        path: ["selectedItemIds"],
        message: "selected item ids must be unique",
      });
    }
    if (selectedItemIds.length !== targetItemCount) {
      context.addIssue({
        code: "custom",
        path: ["targetItemCount"],
        message: "target item count must match selected item ids",
      });
    }
  });
export type ParsedRunManifestMetadata = z.output<typeof RunManifestMetadata>;
export type RunManifestMetadata = ParsedRunManifestMetadata;

export const RunItemCommitMetadata = z.discriminatedUnion("status", [
  z
    .object({
      runId: RunId,
      itemId: ItemId,
      itemDigest: Digest,
      status: z.literal("completed"),
      timing: Timing,
    })
    .strict(),
  z
    .object({
      runId: RunId,
      itemId: ItemId,
      itemDigest: Digest,
      status: z.literal("error"),
      error: z.string(),
      timing: Timing,
    })
    .strict(),
]);
export type RunItemCommitMetadata = z.infer<typeof RunItemCommitMetadata>;

export const EvalManifestMetadata = z
  .object({
    formatVersion: z.literal(1),
    evalId: EvalId,
    runId: RunId,
    status: LifecycleStatus,
    error: z.string().optional(),
    params: Params,
    paramsDigest: Digest,
    aggregatorVersion: Identifier,
    evaluators: EvaluatorIdentities,
    createdAt: z.coerce.date(),
    finishedAt: z.coerce.date().optional(),
    adapters: AdapterIdentities,
  })
  .strict();
export type ParsedEvalManifestMetadata = z.output<typeof EvalManifestMetadata>;
export type EvalManifestMetadata = ParsedEvalManifestMetadata;

const CompletedEvaluatorResult = z
  .object({
    evaluatorName: Identifier,
    status: z.literal("completed"),
    score: NonEmptyScore,
    explanation: z.string().optional(),
    timing: Timing,
  })
  .strict();

const ErrorEvaluatorResult = z
  .object({
    evaluatorName: Identifier,
    status: z.literal("error"),
    error: z.string(),
    timing: Timing,
  })
  .strict();

const SkippedEvaluatorResult = z
  .object({
    evaluatorName: Identifier,
    status: z.literal("skipped"),
    reason: z.string(),
  })
  .strict();

export const EvalItemCommitMetadata = z
  .object({
    evalId: EvalId,
    runId: RunId,
    itemId: ItemId,
    results: z
      .array(
        z.discriminatedUnion("status", [
          CompletedEvaluatorResult,
          ErrorEvaluatorResult,
          SkippedEvaluatorResult,
        ])
      )
      .min(1)
      .refine(
        (results) =>
          new Set(results.map((result) => result.evaluatorName)).size === results.length
      ),
  })
  .strict();
export type EvalItemCommitMetadata = z.infer<typeof EvalItemCommitMetadata>;

export const AggregateScoresMetadata = z
  .object({
    evalId: EvalId,
    scores: Score,
  })
  .strict();
export type AggregateScoresMetadata = z.infer<typeof AggregateScoresMetadata>;

export type MetadataRepairToken = {
  scopeKey: string;
  scopeType: "all" | "experiment" | "run" | "eval";
  leaseId: string;
};

export class MetadataRepairLeaseLostError extends Error {
  constructor(readonly token: MetadataRepairToken) {
    super(`metadata repair lease is no longer current: ${token.scopeKey}`);
    this.name = "MetadataRepairLeaseLostError";
  }
}

export type MetadataWriteOptions = {
  repair?: MetadataRepairToken;
};

export interface MetadataWriter {
  upsertRunManifest(
    metadata: RunManifestMetadata,
    options?: MetadataWriteOptions
  ): Promise<void>;
  commitRunItem(
    metadata: RunItemCommitMetadata,
    options?: MetadataWriteOptions
  ): Promise<void>;
  upsertEvalManifest(
    metadata: EvalManifestMetadata,
    options?: MetadataWriteOptions
  ): Promise<void>;
  commitEvalItem(
    metadata: EvalItemCommitMetadata,
    options?: MetadataWriteOptions
  ): Promise<void>;
  replaceAggregateScores(
    metadata: AggregateScoresMetadata,
    options?: MetadataWriteOptions
  ): Promise<void>;
}

export class NoopMetadataWriter implements MetadataWriter {
  upsertRunManifest(_metadata: RunManifestMetadata): Promise<void> {
    return Promise.resolve();
  }

  commitRunItem(_metadata: RunItemCommitMetadata): Promise<void> {
    return Promise.resolve();
  }

  upsertEvalManifest(_metadata: EvalManifestMetadata): Promise<void> {
    return Promise.resolve();
  }

  commitEvalItem(_metadata: EvalItemCommitMetadata): Promise<void> {
    return Promise.resolve();
  }

  replaceAggregateScores(_metadata: AggregateScoresMetadata): Promise<void> {
    return Promise.resolve();
  }
}

export type ParamProjection = {
  key: string;
  valueType: "null" | "string" | "number" | "boolean" | "array";
  valueJson: string;
  textValue: string | null;
  numberValue: number | null;
  booleanValue: boolean | null;
};

export function projectParams(
  params: Readonly<Record<string, ParamValue>>
): ParamProjection[] {
  return Object.entries(params).map(([key, value]) => ({
    key,
    valueType: getParamValueType(value),
    valueJson: JSON.stringify(value),
    textValue: typeof value === "string" ? value : null,
    numberValue: typeof value === "number" ? value : null,
    booleanValue: typeof value === "boolean" ? value : null,
  }));
}

function getParamValueType(value: ParamValue): ParamProjection["valueType"] {
  if (value === null) return "null";
  if (Array.isArray(value)) return "array";
  switch (typeof value) {
    case "string":
      return "string";
    case "number":
      return "number";
    case "boolean":
      return "boolean";
  }
}
