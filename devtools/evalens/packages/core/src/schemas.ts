import { z } from "zod";

import { utf8ByteLength } from "@evalens/utils";

const boundedUtf8String = (maxBytes: number) =>
  z
    .string()
    .min(1)
    .refine((value) => utf8ByteLength(value) <= maxBytes);

export const ExperimentName = z
  .string()
  .max(128)
  .regex(/^[a-z0-9][a-z0-9._-]*$/)
  .refine((name) => name !== "." && name !== "..");

export const RunId = z.uuidv7();
export const EvalId = z.uuidv7();
export const Identifier = boundedUtf8String(128);
export const ParamKey = boundedUtf8String(256);
export const ItemId = boundedUtf8String(240).regex(
  /^[a-z0-9][a-z0-9._-]*$/,
  "item id must be portable lowercase ASCII and cannot start with a dot"
);
export const Tag = boundedUtf8String(128);
export const Digest = z.string().min(1);
export const DatasetName = z
  .string()
  .max(128)
  .regex(/^[a-z0-9][a-z0-9._-]*$/)
  .refine((name) => name !== "." && name !== "..");
export const LifecycleStatus = z.enum(["running", "finished", "error"]);
export const ParamScalar = z.union([
  z.string(),
  z.number().finite(),
  z.boolean(),
  z.null(),
]);
export type ParamScalar = z.infer<typeof ParamScalar>;
export const ParamValue = z.union([ParamScalar, z.array(ParamScalar)]);
export type ParamValue = z.infer<typeof ParamValue>;
export const Params = z.record(ParamKey, ParamValue);
export type Params = z.infer<typeof Params>;
export const Score = z.record(Identifier, z.number().finite());
export const NonEmptyScore = Score.refine((score) => Object.keys(score).length > 0);

export const Timing = z
  .object({
    startedAt: z.coerce.date(),
    finishedAt: z.coerce.date(),
    durationMs: z.number().int().nonnegative(),
  })
  .strict();
export type Timing = z.infer<typeof Timing>;

export const EvaluatorIdentity = z
  .object({
    name: Identifier,
    version: Identifier,
  })
  .strict();

export const EvaluatorIdentities = z
  .array(EvaluatorIdentity)
  .min(1)
  .refine(
    (evaluators) =>
      new Set(evaluators.map((evaluator) => evaluator.name)).size === evaluators.length
  );

export const Tags = z.array(Tag).refine((tags) => new Set(tags).size === tags.length);
