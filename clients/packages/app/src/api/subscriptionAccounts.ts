import { z } from "zod";

/**
 * A profile: one credential the system may route model requests through,
 * either a signed-in subscription or a provider API key.
 */
export const subscriptionAccountSchema = z.object({
  id: z.string(),
  credential_kind: z.enum(["subscription_oauth", "provider_api_key"]),
  /** Catalog source id, or the provider preset of an API key outside the catalog. */
  source: z.string(),
  provider: z.string().optional(),
  name: z.string().nullable().optional(),
  email: z.string().nullable().optional(),
  key_hint: z.string().nullable().optional(),
  disabled: z.boolean(),
  status: z.string(),
  version: z.string(),
  /** Model ids a Custom endpoint serves, as it listed them when connected. */
  models: z.array(z.string()).max(500).nullable().optional(),
  /** An API key's endpoint; `protocol` is its wire name, such as `openai_responses`. */
  connection: z
    .object({ endpoint: z.string().optional(), protocol: z.string().optional() })
    .nullable()
    .optional(),
  /** A Codex quota reset whose result is not confirmed yet. */
  reset_attempt: z
    .object({ request_id: z.string(), outcome: z.string() })
    .nullable()
    .optional(),
  quota: z
    .object({
      plan_type: z.string().nullable().optional(),
      reset_credits: z
        .object({ available_count: z.number().int().nonnegative() })
        .nullable()
        .optional(),
      windows: z
        .array(
          z.object({
            period: z.string(),
            remaining_percent: z.number().nullable().optional(),
            reset_at: z.string().nullable().optional(),
            /** Set when the window covers one model, as Gemini reports per model. */
            model: z.string().nullable().optional(),
          })
        )
        // One window per model for some plans; the server bounds the list.
        .max(500)
        .optional(),
    })
    .nullable()
    .optional(),
});
export const subscriptionPageSchema = z.object({
  accounts: z.array(subscriptionAccountSchema).max(25),
  next: z.string(),
});
export const subscriptionOAuthSchema = z.object({
  id: z.string(),
  url: z.string().url(),
  expires_at: z.string(),
  mode: z.enum(["device", "callback"]).optional(),
  user_code: z.string().optional(),
  interval: z.number().int().min(5).optional(),
});
export type SubscriptionAccount = z.infer<typeof subscriptionAccountSchema>;
export type SubscriptionPage = z.infer<typeof subscriptionPageSchema>;
export type SubscriptionOAuth = z.infer<typeof subscriptionOAuthSchema>;
/** The catalog source id of a subscription, such as `codex` or `github-copilot`. */
export type SubscriptionProvider = string;

export type ProviderKeyInput = {
  credential_kind: "provider_api_key";
  source: string;
  name?: string;
  /** Absent only for a Custom endpoint that takes no key. */
  api_key?: string;
  base_url?: string;
  /** For a Custom endpoint: its wire protocol and the model ids it serves. */
  protocol?: "anthropic" | "chat_completions" | "responses";
  models?: string[];
};

export const subscriptionResetSchema = z.object({
  outcome: z.enum(["reset", "already_redeemed", "nothing_to_reset", "no_credit"]),
  account: subscriptionAccountSchema,
  quota_refreshed: z.boolean(),
});
export type SubscriptionReset = z.infer<typeof subscriptionResetSchema>;

export type ProfileUpdate = {
  version: string;
  disabled?: boolean;
  name?: string;
  api_key?: string;
};

export const subscriptionOAuthPollSchema = z.union([
  subscriptionAccountSchema,
  z.object({ status: z.literal("pending"), interval: z.number().int().min(5) }),
]);
