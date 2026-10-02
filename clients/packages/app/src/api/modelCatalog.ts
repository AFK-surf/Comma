import { z } from "zod";

export const modelProtocolSchema = z.enum([
  "anthropic",
  "chat_completions",
  "responses",
]);
export type ModelProtocol = z.infer<typeof modelProtocolSchema>;

/**
 * Every model Comma can route, and the request id and protocol each source
 * expects for it. A source is a provider API or a consumer subscription.
 */
export const modelCatalogSchema = z.object({
  sources: z.record(
    z.string(),
    z.object({
      name: z.string(),
      kind: z.enum(["api_key", "subscription"]),
      base_url: z.string().nullable().optional(),
      /** The profile must name its own endpoint, as Azure and custom ones do. */
      endpoint_required: z.boolean().optional(),
      protocols: z.array(modelProtocolSchema).max(3).optional(),
    })
  ),
  models: z
    .array(
      z.object({
        id: z.string(),
        name: z.string(),
        /** The line a model belongs to within its maker, such as "Opus" or "GPT mini". */
        family: z.string().optional(),
        vendor: z.string(),
        efforts: z.array(z.string()).max(16),
        images: z.boolean().optional(),
        context_tokens: z.number().optional(),
        max_tokens: z.number().optional(),
        routes: z.record(
          z.string(),
          z.object({ model: z.string(), protocol: modelProtocolSchema })
        ),
      })
    )
    .max(5000),
});
export type ModelCatalog = z.infer<typeof modelCatalogSchema>;
export type CatalogModel = ModelCatalog["models"][number];

export const agentSelectionSchema = z.discriminatedUnion("kind", [
  z.object({ kind: z.literal("builtin") }),
  z.object({
    kind: z.literal("catalog"),
    model: z.string(),
    reasoning_effort: z.string().nullable(),
    /** May this agent bill API-key profiles once subscriptions run out. */
    allow_paid: z.boolean(),
    /** The one profile this agent keeps to; absent or null lets the system choose. */
    profile_id: z.string().nullable().default(null),
  }),
  /** A private template chosen before the catalog existed. */
  z.object({ kind: z.literal("template"), template_id: z.string() }),
  /**
   * The model a compute runtime runs with its own sign-in, such as Codex on a
   * VM; no profile serves it.
   */
  z.object({
    kind: z.literal("runtime"),
    model: z.string(),
    reasoning_effort: z.string().nullable(),
  }),
]);
export type AgentSelection = z.infer<typeof agentSelectionSchema>;

const settingsAgentSchema = z.object({
  agent_id: z.string(),
  name: z.string(),
  role: z.enum(["router", "worker"]),
  selection: agentSelectionSchema.optional(),
  /** The model in effect, for choices the catalog does not describe. */
  model: z.string().nullable().optional(),
  model_display_name: z.string().nullable().optional(),
  template_name: z.string().nullable().optional(),
  reasoning_effort: z.string().nullable().optional(),
  /** Set for workers that run in an external runtime, such as Codex on a VM. */
  runtime: z
    .object({
      kind: z.string(),
      provider: z.string(),
      protocols: z.array(modelProtocolSchema).max(3).optional(),
    })
    .optional(),
});
export type SettingsAgent = z.infer<typeof settingsAgentSchema>;

export const workerModelsSchema = z.object({
  items: z.array(settingsAgentSchema).max(50),
  next_cursor: z.string().nullable(),
});

export const agentModelsSchema = z.object({
  workspace_id: z.string(),
  agents: z.object({ router: settingsAgentSchema }),
  workers: workerModelsSchema,
});
export type AgentModels = z.infer<typeof agentModelsSchema>;
