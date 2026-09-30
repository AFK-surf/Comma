import { z } from "zod";

export const subscriptionAccountSchema = z.object({
  id: z.string(),
  provider: z.enum(["codex", "claude"]),
  email: z.string().nullable().optional(),
  disabled: z.boolean(),
  status: z.string(),
  version: z.string(),
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
      observed_at: z.string().optional(),
      windows: z
        .array(
          z.object({
            period: z.string(),
            remaining_percent: z.number().nullable().optional(),
            reset_at: z.string().nullable().optional(),
          })
        )
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
export type SubscriptionProvider = SubscriptionAccount["provider"];

export const subscriptionResetSchema = z.object({
  outcome: z.enum(["reset", "already_redeemed", "nothing_to_reset", "no_credit"]),
  account: subscriptionAccountSchema,
  quota_refreshed: z.boolean(),
});
export type SubscriptionReset = z.infer<typeof subscriptionResetSchema>;

export const subscriptionOAuthPollSchema = z.union([
  subscriptionAccountSchema,
  z.object({ status: z.literal("pending"), interval: z.number().int().min(5) }),
]);
