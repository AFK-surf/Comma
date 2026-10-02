import { z } from "zod";

export const modelOptionSchema = z.object({
  template_id: z.string(),
  name: z.string(),
  model: z.string(),
  model_display_name: z.string().nullable().optional(),
  model_vendor: z.string().nullable().optional(),
  supported_protocols: z
    .array(z.enum(["responses", "chat_completions", "anthropic"]))
    .max(3)
    .optional(),
  model_icon: z.string().nullable().optional(),
  // Any subscription plan the backend pools, such as `codex` or `gemini`.
  account_pool: z.string().nullable().optional(),
  reasoning_effort: z.string().nullable().optional(),
  provider: z.string(),
  scope: z.enum(["global", "tenant"]),
});

export const modelTemplateSchema = modelOptionSchema.extend({
  protocol: z.enum(["anthropic", "responses", "chat_completions"]),
  base_url: z.string(),
  has_api_key: z.boolean(),
  max_tokens: z.number(),
  context_tokens: z.number(),
  supports_images: z.boolean(),
  // Any subscription plan the backend pools, such as `codex` or `gemini`.
  account_pool: z.string().nullable().optional(),
});

export const runtimeAgentModelSchema = z.object({
  agent_id: z.string(),
  name: z.string(),
  role: z.literal("worker"),
  source: z.enum(["agent_config", "runtime_default"]),
  model: z.string().nullable(),
  provider: z.string().nullable(),
  reasoning_effort: z.string().nullable(),
  runtime: z.object({
    kind: z.enum(["connected", "compute"]),
    provider: z.string(),
  }),
});

export const deletedModelSchema = z.object({ deleted: z.literal(true) });
export type ModelTemplate = z.infer<typeof modelTemplateSchema>;
export type ModelTemplateInput = Pick<
  ModelTemplate,
  | "name"
  | "model"
  | "provider"
  | "protocol"
  | "base_url"
  | "max_tokens"
  | "context_tokens"
  | "supports_images"
> & {
  account_pool?: "codex" | "claude" | null;
  api_key?: string;
  reasoning_effort?: string | null;
  model_display_name?: string | null;
  model_vendor?: string | null;
};

export const discoveredModelsSchema = z.object({
  base_url: z.string(),
  provider: z.string(),
  protocol: z.enum(["anthropic", "responses", "chat_completions"]),
  truncated: z.boolean(),
  data: z
    .array(
      z.object({
        id: z.string(),
        name: z.string(),
        vendor: z.string().nullable().optional(),
        supports_images: z.boolean(),
        reasoning_efforts: z.array(z.string().min(1).max(64)).max(32).optional(),
        default_reasoning_effort: z.string().nullable().optional(),
      })
    )
    .max(1000),
});
export type DiscoveredModels = z.infer<typeof discoveredModelsSchema>;
export type ModelDiscoveryInput =
  | { template_id: string }
  | { account_pool: "codex" | "claude" }
  | {
      base_url: string;
      /** Absent for an endpoint that takes no key. */
      api_key?: string;
      protocol?: ModelTemplate["protocol"];
    };
