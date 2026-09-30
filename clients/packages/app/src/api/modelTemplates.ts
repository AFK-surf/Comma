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
  account_pool: z.enum(["codex", "claude"]).nullable().optional(),
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
  account_pool: z.enum(["codex", "claude"]).nullable().optional(),
});

/** Where an agent's effective model comes from: its own choice, or a default it follows. */
export const agentModelSourceSchema = z.enum(["pinned", "platform_default"]);

const agentModelSchema = z.object({
  agent_id: z.string(),
  name: z.string(),
  role: z.enum(["router", "worker"]),
  source: agentModelSourceSchema,
  template_id: z.string(),
  template_name: z.string(),
  model: z.string(),
  model_display_name: z.string().nullable().optional(),
  model_vendor: z.string().nullable().optional(),
  model_icon: z.string().nullable().optional(),
  account_pool: z.enum(["codex", "claude"]).nullable().optional(),
  provider: z.string(),
  reasoning_effort: z.string().nullable().optional(),
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

export const workerModelsSchema = z.object({
  items: z.array(z.union([agentModelSchema, runtimeAgentModelSchema])).max(50),
  next_cursor: z.string().nullable(),
});

export const agentModelsSchema = z.object({
  workspace_id: z.string(),
  agents: z.object({ router: agentModelSchema, worker: agentModelSchema }),
  workers: workerModelsSchema,
  worker_default_template_id: z.string().nullable(),
  /** The Comma-wide default per role, used when the workspace chooses nothing. */
  platform_defaults: z.object({
    router: modelOptionSchema.nullable(),
    worker: modelOptionSchema.nullable(),
  }),
  available_models: z.array(modelOptionSchema).max(100),
});
export { agentModelSchema };
export const deletedModelSchema = z.object({ deleted: z.literal(true) });
export type ModelTemplate = z.infer<typeof modelTemplateSchema>;
export type AgentModels = z.infer<typeof agentModelsSchema>;
export type AgentModel = z.infer<typeof agentModelSchema>;
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
export type SubscriptionModelChoice = {
  account_pool: "codex" | "claude";
  model: string;
  reasoning_effort: string | null;
  model_display_name: string;
  supports_images: boolean;
};
export type ModelDiscoveryInput =
  | { template_id: string }
  | { account_pool: "codex" | "claude" }
  | {
      base_url: string;
      api_key: string;
      protocol?: ModelTemplate["protocol"];
    };
