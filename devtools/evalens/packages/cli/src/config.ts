import path from "node:path";
import { z } from "zod";

import "@evalens/adapters/config";
import { BuiltInAdapterConfigSchema } from "@evalens/adapters/config";
import { DEFAULT_RUN_RETRY_OPTIONS, type RunRetryOptions } from "@evalens/core/run";

const RunRetryConfigSchema = z
  .object({
    maxRetries: z.number().int().min(0).default(DEFAULT_RUN_RETRY_OPTIONS.maxRetries),
  })
  .strict();

const BaseConfigSchema = z.object({
  $schema: z.string().optional(),
  concurrency: z.number().int().positive().default(1),
  retry: RunRetryConfigSchema.optional(),
  adapters: BuiltInAdapterConfigSchema.optional(),
});

export const R2ConfigSchema = z
  .object({
    accountId: z.string().min(1),
    bucket: z.string().min(1),
    accessKeyId: z.string().min(1),
    secretAccessKey: z.string().min(1),
  })
  .strict();

const LocalConfigSchema = BaseConfigSchema.extend({
  local: z.object({ outputDir: z.string().min(1) }).strict(),
}).strict();

const RemoteConfigSchema = BaseConfigSchema.extend({
  remote: z
    .object({
      url: z.url(),
      access: z
        .object({
          clientId: z.string().min(1),
          clientSecret: z.string().min(1),
        })
        .strict(),
      r2: R2ConfigSchema,
    })
    .strict(),
}).strict();

export const EvalensConfigSchema = z.union([LocalConfigSchema, RemoteConfigSchema]);
export type EvalensConfig = z.infer<typeof EvalensConfigSchema>;
export type RunRetryConfig = z.infer<typeof RunRetryConfigSchema>;
export type R2Config = z.infer<typeof R2ConfigSchema>;

export function resolveRunRetryOptions(
  config: RunRetryConfig | undefined
): RunRetryOptions | undefined {
  return config === undefined
    ? undefined
    : {
        ...DEFAULT_RUN_RETRY_OPTIONS,
        maxRetries: config.maxRetries,
      };
}

export async function loadEvalensConfig(configPath: string): Promise<EvalensConfig> {
  const resolvedPath = path.resolve(configPath);
  const config = await EvalensConfigSchema.parseAsync(
    await Bun.file(resolvedPath).json()
  );
  if ("local" in config) {
    return {
      ...config,
      local: {
        outputDir: path.resolve(path.dirname(resolvedPath), config.local.outputDir),
      },
    };
  }
  return config;
}
