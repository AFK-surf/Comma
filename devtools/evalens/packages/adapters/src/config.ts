import { z } from "zod";

import type {
  AdapterConfigFor,
  AdapterIdentity,
  AdapterNames,
  DeepReadonly,
} from "@evalens/core/adapter";

const SalixIntegrationIdSchema = z.string().min(1);
const SalixIntegrationProviderSchema = z.string().min(1).toLowerCase();
const SalixOAuthCredentialsSchema = z
  .object({
    type: z.literal("oauth"),
    accessToken: z.string().min(1),
    refreshToken: z.string().min(1).optional(),
    expiresAt: z.number().int().positive().optional(),
    refreshExpiresAt: z.number().int().positive().optional(),
    tokenType: z.string().min(1).optional(),
  })
  .strict();
const SalixOAuthAccountSchema = z
  .object({
    id: z.string().optional(),
    name: z.string().optional(),
  })
  .strict()
  .optional();
const SalixPluginConnectionSchema = z
  .object({
    pluginId: z.string().min(1),
    connectionId: z.string().min(1),
  })
  .strict();

export const SalixIntegrationConfigSchema = z.union([
  z
    .object({
      id: SalixIntegrationIdSchema,
      provider: z.literal("slack"),
      credentials: z
        .object({
          type: z.literal("app"),
          appId: z.string().min(1),
          clientId: z.string().min(1),
          clientSecret: z.string().min(1),
          signingSecret: z.string().min(1),
          botToken: z.string().min(1),
          appName: z.string().min(1).optional(),
        })
        .strict(),
    })
    .strict(),
  z
    .object({
      id: SalixIntegrationIdSchema,
      provider: SalixIntegrationProviderSchema,
      alias: z.string().min(1),
      credentials: SalixOAuthCredentialsSchema,
      scopes: z.array(z.string().min(1)).default([]),
      account: SalixOAuthAccountSchema,
      plugin: SalixPluginConnectionSchema.optional(),
      providerKey: z.string().min(1).optional(),
    })
    .strict(),
]);
export type SalixIntegrationConfig = z.infer<typeof SalixIntegrationConfigSchema>;

export const SalixAdapterConfigSchema = z
  .object({
    baseUrl: z.url(),
    token: z.string().min(1).optional(),
    tenantId: z.string().min(1).default("evalens"),
    templateId: z.string().min(1).optional(),
    integrations: z
      .array(SalixIntegrationConfigSchema)
      .superRefine((integrations, context) => {
        const ids = new Set<string>();
        for (const [index, integration] of integrations.entries()) {
          if (ids.has(integration.id)) {
            context.addIssue({
              code: "custom",
              message: `duplicate Salix integration id: ${integration.id}`,
              path: [index, "id"],
            });
          }
          ids.add(integration.id);
        }
      })
      .optional(),
  })
  .strict();
export type SalixAdapterConfig = z.infer<typeof SalixAdapterConfigSchema>;

export const CodexAdapterConfigSchema = z
  .object({
    command: z.string().min(1).default("codex"),
    profile: z.string().min(1).optional(),
    authJson: z.record(z.string(), z.unknown()).optional(),
    env: z.record(z.string(), z.string()).default({}),
    sandbox: z
      .enum(["read-only", "workspace-write", "danger-full-access"])
      .default("workspace-write"),
    approvalPolicy: z
      .enum(["never", "on-request", "on-failure", "untrusted"])
      .default("never"),
    skipGitRepoCheck: z.boolean().default(true),
  })
  .strict();
export type CodexAdapterConfig = z.infer<typeof CodexAdapterConfigSchema>;

export const SlackAdapterConfigSchema = z
  .object({
    token: z.string().min(1),
    workspaceId: z.string().min(1),
    allowedChannelIds: z.array(z.string().min(1)).min(1),
    expectedUserId: z.string().min(1).optional(),
    otherAppDriver: z
      .object({
        token: z.string().min(1),
        expectedBotUserId: z.string().min(1),
      })
      .strict()
      .optional(),
    pollMs: z.number().int().positive().default(1_000),
  })
  .strict();
export type SlackAdapterConfig = z.infer<typeof SlackAdapterConfigSchema>;

declare module "@evalens/core/adapter" {
  interface AdapterConfigRegistry {
    salix: SalixAdapterConfig;
    codex: CodexAdapterConfig;
    slack: SlackAdapterConfig;
  }
}

export const BuiltInAdapters = {
  salix: {
    version: "1",
    configSchema: SalixAdapterConfigSchema,
  },
  codex: {
    version: "1",
    configSchema: CodexAdapterConfigSchema,
  },
  slack: {
    version: "1",
    configSchema: SlackAdapterConfigSchema,
  },
} as const;

export type BuiltInAdapterName = keyof typeof BuiltInAdapters;

export const BuiltInAdapterConfigSchema = z
  .object({
    salix: SalixAdapterConfigSchema.optional(),
    codex: CodexAdapterConfigSchema.optional(),
    slack: SlackAdapterConfigSchema.optional(),
  })
  .strict()
  .default({});
export type BuiltInAdapterConfig = z.infer<typeof BuiltInAdapterConfigSchema>;

export function selectAdapterConfig<const Names extends AdapterNames>(
  names: Names,
  config: BuiltInAdapterConfig
): DeepReadonly<AdapterConfigFor<Names>> {
  const selected: Record<string, unknown> = {};
  for (const name of names) {
    if (!Object.hasOwn(config, name)) {
      throw new Error(`missing adapter config: ${name}`);
    }
    selected[name] = config[name];
  }
  return selected as DeepReadonly<AdapterConfigFor<Names>>;
}

export function adapterIdentities(names: AdapterNames): AdapterIdentity[] {
  return names.map((name) => ({
    name,
    version: BuiltInAdapters[name].version,
  }));
}
