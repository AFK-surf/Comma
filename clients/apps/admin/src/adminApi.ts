import { runtimeAgentModelSchema } from "@comma/app/api";
import type { CommaApiSessionTransport } from "@comma/app/auth";
import { z } from "zod";

const adminLoginMethodSchema = z.discriminatedUnion("method", [
  z.object({ method: z.literal("ssh_public_key") }),
  z
    .object({
      method: z.literal("email_otp"),
      email: z.string(),
    })
    .passthrough(),
  z
    .object({
      method: z.literal("google"),
      email_snapshot: z.string(),
      email_verified: z.boolean(),
      linked_at: z.number().nullable().optional(),
      last_authenticated_at: z.number().nullable().optional(),
    })
    .passthrough(),
]);

const adminUserSchema = z
  .object({
    id: z.string(),
    email: z.string().nullable().optional(),
    name: z.string().nullable().optional(),
    status: z.string().nullable().optional(),
    created_at: z.number().nullable().optional(),
    updated_at: z.number().nullable().optional(),
    login_methods: z.array(adminLoginMethodSchema).optional(),
    admin_access: z
      .object({
        allowed: z.boolean(),
        decision: z.enum(["allow", "deny"]).nullable(),
        source: z.enum([
          "disabled",
          "domain_default",
          "explicit_allow",
          "explicit_deny",
          "none",
        ]),
      })
      .optional(),
  })
  .passthrough();

const adminUserPageSchema = z
  .object({
    data: z.array(adminUserSchema),
    has_more: z.boolean(),
    next_cursor: z.string().nullable(),
  })
  .passthrough();

const adminSessionSchema = z.strictObject({
  id: z.string(),
  auth_method: z.enum(["email_otp", "google", "ssh_public_key"]).nullable(),
  session_source: z.enum(["user_login", "ops_api"]),
  authenticated_at: z.number().nullable(),
  expires_at: z.number(),
  last_seen_at: z.number().nullable(),
  revoked_at: z.number().nullable(),
  client_kind: z.enum(["web", "electron", "android", "api", "ssh"]).nullable(),
  device_label: z.string().nullable(),
  restricted: z.boolean(),
});

const adminSessionPageSchema = z.strictObject({
  data: z.array(adminSessionSchema),
  has_more: z.boolean(),
  next_cursor: z.string().nullable(),
});

const adminWorkspaceVmSchema = z.strictObject({
  workspace_id: z.string(),
  enabled: z.boolean(),
  convergence_status: z.string().nullable(),
});

const adminSignalAccountSchema = z
  .object({
    e164: z.string().nullish(),
    state: z.string().nullish(),
    scope: z.string().nullish(),
  })
  .strip();

const adminWorkspaceSignalNumberSchema = z
  .object({
    workspace_id: z.string().optional(),
    override: adminSignalAccountSchema.nullish(),
    platform: adminSignalAccountSchema.nullish(),
    effective: adminSignalAccountSchema.nullish(),
  })
  .strip();
export type AdminWorkspaceSignalNumber = z.infer<
  typeof adminWorkspaceSignalNumberSchema
>;

const adminWorkspaceBillingSchema = z.strictObject({
  workspace: z
    .strictObject({
      id: z.string(),
      name: z.string().nullable(),
      status: z.enum(["provisioning", "ready", "failed", "suspended"]),
      tenant_id: z.string(),
      group_id: z.string(),
      billing_account_id: z.string(),
      cloud_vm: adminWorkspaceVmSchema.optional(),
      created_at: z.number(),
      updated_at: z.number(),
    })
    .nullable(),
  billing: z
    .strictObject({
      account_id: z.string(),
      account_status: z.enum(["active", "inactive", "missing", "identity_mismatch"]),
      current_credits: z.number().nonnegative(),
      active_grants: z.array(
        z.strictObject({
          id: z.string(),
          package_code: z.string().nullable(),
          package_version: z.string().nullable(),
          remaining_credits: z.number().nonnegative(),
          valid_from: z.string(),
          expires_at: z.string().nullable(),
          source_type: z.string(),
          source_id: z.string().nullable(),
        })
      ),
      has_more: z.boolean(),
    })
    .nullable(),
});

const adminWorkspaceAgentRoleSchema = z.enum(["router", "worker"]);

const adminWorkspaceAgentModelSchema = z.object({
  agent_id: z.string(),
  name: z.string().optional(),
  scope: z.enum(["global", "tenant"]).optional(),
  role: adminWorkspaceAgentRoleSchema,
  // Whether the agent chose this template or follows a default.
  source: z.enum(["pinned", "tenant_default", "platform_default"]).optional(),
  template_id: z.string(),
  template_name: z.string(),
  model: z.string(),
  model_display_name: z.string().nullable().optional(),
  model_vendor: z.string().nullable().optional(),
  model_icon: z.string().nullable().optional(),
  account_pool: z.enum(["codex", "claude"]).nullable().optional(),
  reasoning_effort: z.string().nullable().optional(),
  provider: z.string(),
});

const adminWorkspaceModelOptionSchema = z.object({
  template_id: z.string(),
  name: z.string(),
  model: z.string(),
  model_display_name: z.string().nullable().optional(),
  model_vendor: z.string().nullable().optional(),
  model_icon: z.string().nullable().optional(),
  account_pool: z.enum(["codex", "claude"]).nullable().optional(),
  reasoning_effort: z.string().nullable().optional(),
  provider: z.string(),
  scope: z.enum(["global", "tenant"]),
});

const adminWorkspaceAgentModelsSchema = z.object({
  workspace_id: z.string(),
  workers: z
    .object({
      items: z
        .array(z.union([adminWorkspaceAgentModelSchema, runtimeAgentModelSchema]))
        .max(50),
      next_cursor: z.string().nullable(),
    })
    .optional(),
  worker_default_template_id: z.string().nullable().optional(),
  agents: z.object({
    router: adminWorkspaceAgentModelSchema,
    worker: adminWorkspaceAgentModelSchema,
  }),
  platform_defaults: z
    .object({
      router: adminWorkspaceModelOptionSchema.nullable(),
      worker: adminWorkspaceModelOptionSchema.nullable(),
    })
    .optional(),
  available_models: z.array(adminWorkspaceModelOptionSchema).max(100),
});

const adminAuditEventSchema = z.strictObject({
  id: z.string(),
  action: z.string().min(1),
  outcome: z.enum(["started", "succeeded", "failed", "rejected"]),
  actor: z.strictObject({
    type: z.enum(["comma_user", "ops"]),
    user_id: z.string().nullable(),
    email: z.string().nullable(),
  }),
  target: z.strictObject({
    type: z.string(),
    id: z.string(),
  }),
  reason: z.string(),
  error_code: z.string().nullable(),
  created_at: z.number(),
  updated_at: z.number(),
});

const adminAuditEventPageSchema = z.strictObject({
  data: z.array(adminAuditEventSchema),
  has_more: z.boolean(),
  next_cursor: z.string().nullable(),
});

const adminOauthClientShape = {
  id: z.string(),
  name: z.string(),
  confidential: z.boolean(),
  redirect_uris: z.array(z.string()),
  disabled_at: z.string().nullable(),
  created_at: z.string().nullable(),
};

const adminOauthClientSchema = z.strictObject(adminOauthClientShape);

const adminOauthClientCreationSchema = z.union([
  z.strictObject({
    ...adminOauthClientShape,
    confidential: z.literal(true),
    client_secret: z.string().min(1),
  }),
  z.strictObject({
    ...adminOauthClientShape,
    confidential: z.literal(false),
  }),
]);

const adminOauthClientSecretSchema = z.strictObject({
  ...adminOauthClientShape,
  confidential: z.literal(true),
  client_secret: z.string().min(1),
});

const revokeSessionResultSchema = z.strictObject({
  revoked: z.literal(true),
  session_id: z.string(),
});

const revokeAllSessionsResultSchema = z.strictObject({
  revoked_count: z.number().int().nonnegative(),
});

const packageVersionSchema = z
  .object({
    id: z.string(),
    package_code: z.string(),
    package_name: z.string().nullable().optional(),
    version: z.string(),
    surface: z.string(),
    kind: z.string(),
    billing_period: z.string().nullable().optional(),
    grant_credits: z.number(),
    grant_period: z.string(),
    currency: z.string().nullable().optional(),
    amount_minor: z.number().nullable().optional(),
    effective_at: z.string().nullable().optional(),
    expires_at: z.string().nullable().optional(),
    status: z.string(),
  })
  .passthrough();

const redeemCodeSchema = z.object({
  id: z.string(),
  display_prefix: z.string().nullable().optional(),
  package_code: z.string(),
  package_version: z.string(),
  code_type: z.string().nullable().optional(),
  surface: z.string().nullable().optional(),
  scope_product_owner_type: z.string().nullable().optional(),
  scope_product_owner_id: z.string().nullable().optional(),
  status: z.string().nullable().optional(),
  max_redemptions: z.number().nullable().optional(),
  per_account_limit: z.number().nullable().optional(),
  valid_from: z.string().nullable().optional(),
  expires_at: z.string().nullable().optional(),
  metadata: z.unknown().optional(),
  code: z.string().optional(),
});

const redemptionSchema = z.object({
  id: z.string(),
  redeem_code_id: z.string(),
  billing_account_id: z.string(),
  surface: z.string().nullable().optional(),
  product_owner_type: z.string().nullable().optional(),
  product_owner_id: z.string().nullable().optional(),
  source_type: z.string().nullable().optional(),
  source_id: z.string().nullable().optional(),
  source_event_id: z.string().nullable().optional(),
  idempotency_key: z.string().nullable().optional(),
  operator_snapshot: z.unknown().optional(),
  status: z.string().nullable().optional(),
  metadata: z.unknown().optional(),
});

const dataPage = <T extends z.ZodType>(item: T) =>
  z
    .object({
      data: z.array(item),
    })
    .passthrough();

const supportSessionSchema = z
  .object({
    id: z.string(),
    token: z.string(),
    expires_at: z.number(),
    restricted: z.literal(true),
    interaction_budget_remaining: z.number().nullable().optional(),
    tool_allowlist: z.array(z.string()).optional(),
    workspace_id: z.string().nullable().optional(),
    conversation_id: z.string().nullable().optional(),
  })
  .passthrough();

const workspaceResultSchema = z
  .object({
    status: z.enum(["provisioning", "ready"]),
    retry_after_seconds: z.number().optional(),
    workspace: z
      .object({
        id: z.string(),
        status: z.string(),
      })
      .passthrough(),
  })
  .passthrough();

const redemptionResultSchema = z.object({
  redemption: redemptionSchema,
  idempotent: z.boolean(),
});

const manualGrantResultSchema = z.strictObject({
  manual_grant: z.strictObject({
    id: z.string(),
    billing_account_id: z.string(),
    package_code: z.string(),
    package_version: z.string(),
    source_type: z.string(),
    source_id: z.string(),
    source_event_id: z.string(),
    operator_snapshot: z.strictObject({
      id: z.string(),
      type: z.string(),
      reason: z.string().nullable(),
    }),
    valid_from: z.string(),
    expires_at: z.string(),
    credit_grant_id: z.string(),
    status: z.string(),
  }),
  grant: z
    .strictObject({
      id: z.string(),
      billing_account_id: z.string(),
      package_code: z.string().optional(),
      package_version: z.string().optional(),
      initial_credits: z.number().nonnegative().optional(),
      remaining_credits: z.number().nonnegative(),
      valid_from: z.string().optional(),
      expires_at: z.string().nullable().optional(),
      source_type: z.string().optional(),
      source_id: z.string().optional(),
      source_event_id: z.string().optional(),
      status: z.string(),
    })
    .nullable(),
  idempotent: z.boolean(),
});

const agentVmmOverviewSchema = z
  .object({
    total: z.number().int().nonnegative(),
    ready: z.number().int().nonnegative(),
    needs_attention: z.number().int().nonnegative(),
    disabled: z.number().int().nonnegative(),
    revoked: z.number().int().nonnegative(),
    enrolling: z.number().int().nonnegative(),
    draining: z.number().int().nonnegative(),
    disconnected_or_stale: z.number().int().nonnegative(),
    lease_expiring: z.number().int().nonnegative(),
    unknown_outcome: z.number().int().nonnegative(),
  })
  .passthrough();

const agentVmmEnvironmentSchema = z
  .object({
    id: z.string(),
    owner_type: z.string(),
    owner_id: z.string(),
    desired_state: z.string(),
    observed_state: z.string(),
    generation: z.number().int(),
    revision: z.number().int().nonnegative(),
    binding_status: z.string(),
    allocations: z.number().int().nonnegative(),
    workloads: z.number().int().nonnegative(),
    runtimes: z.number().int().nonnegative(),
    updated_at: z.string(),
  })
  .passthrough();

const agentVmmNodeSchema = z
  .object({
    id: z.string(),
    device_id: z.string().nullable(),
    group_id: z.string(),
    status: z.string(),
    issue: z.string().nullable(),
    updated_at: z.string(),
    registration: z
      .object({
        status: z.string(),
        desired_enabled: z.boolean(),
        revision: z.number().int().nonnegative(),
      })
      .passthrough(),
    installation: z
      .object({
        id: z.string(),
        revision: z.number().int().nonnegative(),
        status: z.string(),
        error_code: z.string().nullable(),
        retryable: z.boolean(),
      })
      .passthrough()
      .nullable(),
    connection: z
      .object({
        status: z.string(),
        last_observed_at: z.string().nullable(),
        binding_count: z.number().int().nonnegative(),
      })
      .passthrough(),
    work: z.record(z.string(), z.unknown()),
    operations: z.record(z.string(), z.unknown()),
    environments: z.array(agentVmmEnvironmentSchema).optional(),
  })
  .passthrough();

const agentVmmNodePageSchema = z.strictObject({
  data: z.array(agentVmmNodeSchema),
  has_more: z.boolean(),
  next_cursor: z.string().nullable(),
});

const agentVmmCommandResultSchema = z.strictObject({
  accepted: z.literal(true),
  action: z.string(),
  target: z.string(),
  result_revision: z.number().int().nonnegative(),
});

const errorBodySchema = z
  .object({
    error: z
      .union([z.string(), z.object({ code: z.string() }).passthrough()])
      .optional(),
  })
  .passthrough();

export type AdminUser = z.output<typeof adminUserSchema>;
export type AdminLoginMethod = z.output<typeof adminLoginMethodSchema>;
export type AdminSession = z.output<typeof adminSessionSchema>;
export type AdminAuditEvent = z.output<typeof adminAuditEventSchema>;
export type AdminPackageVersion = z.output<typeof packageVersionSchema>;
export type AdminRedeemCode = z.output<typeof redeemCodeSchema>;
export type AdminRedemption = z.output<typeof redemptionSchema>;
export type AdminSupportSession = z.output<typeof supportSessionSchema>;
export type AdminWorkspaceResult = z.output<typeof workspaceResultSchema>;
export type AdminWorkspaceVm = z.output<typeof adminWorkspaceVmSchema>;
export type AdminWorkspaceBilling = z.output<typeof adminWorkspaceBillingSchema>;
export type AdminWorkspaceAgentRole = z.output<typeof adminWorkspaceAgentRoleSchema>;
export type AdminWorkspaceAgentModel = z.output<typeof adminWorkspaceAgentModelSchema>;
export type AdminWorkspaceModelOption = z.output<
  typeof adminWorkspaceModelOptionSchema
>;
export type AdminWorkspaceAgentModels = z.output<
  typeof adminWorkspaceAgentModelsSchema
>;
export type AdminRedemptionResult = z.output<typeof redemptionResultSchema>;
export type AdminManualGrantResult = z.output<typeof manualGrantResultSchema>;
export type AdminOauthClient = z.output<typeof adminOauthClientSchema>;
export type AdminOauthClientCreation = z.output<typeof adminOauthClientCreationSchema>;
export type AdminOauthClientSecret = z.output<typeof adminOauthClientSecretSchema>;
export type AgentVmmOverview = z.output<typeof agentVmmOverviewSchema>;
export type AgentVmmNode = z.output<typeof agentVmmNodeSchema>;
export type AgentVmmEnvironment = z.output<typeof agentVmmEnvironmentSchema>;
export type AgentVmmCommandResult = z.output<typeof agentVmmCommandResultSchema>;
export type AgentVmmAction =
  | "retry_agent_vmm_install"
  | "enable_agent_vmm_registration"
  | "disable_agent_vmm_registration"
  | "revoke_agent_vmm_registration"
  | "drain_compute_environment"
  | "revoke_compute_environment"
  | "create_shell_workload";
export type AdminRedeemCodeCreation =
  | {
      kind: "created";
      record: AdminRedeemCode & { code: string };
    }
  | {
      kind: "recovered_redacted";
      record: AdminRedeemCode;
    };

export interface AdminCommandMetadata {
  confirmation: string;
  idempotencyKey: string;
  reason: string;
}

export interface CreateAdminUserInput extends AdminCommandMetadata {
  adminAccess?: "allow" | "deny";
  email: string;
  name?: string;
  status?: "active" | "disabled";
}

export interface UpdateAdminUserInput extends AdminCommandMetadata {
  name?: string;
  status?: "active" | "disabled";
}

export interface CreateSupportSessionInput extends AdminCommandMetadata {
  budget: number;
  conversationId?: string;
  expiresInSeconds: number;
  toolAllowlist?: string[];
  workspaceId?: string;
}

export interface CreateRedeemCodeInput extends AdminCommandMetadata {
  code?: string;
  expiresAt?: string;
  maxRedemptions?: number;
  packageCode: string;
  packageVersion: string;
  perAccountLimit?: number;
}

export interface ApplyRedeemCodeInput extends AdminCommandMetadata {
  billingAccountId: string;
  codeId: string;
  productOwnerId: string;
  productOwnerType: "workspace";
}

export interface IssueWorkspaceCreditsInput extends AdminCommandMetadata {
  expiresAt: string;
  packageCode: string;
  packageVersion: string;
}

export interface CreateOauthClientInput extends AdminCommandMetadata {
  confidential: boolean;
  name: string;
  redirectUris: string[];
}

export interface UpdateWorkspaceAgentModelInput extends AdminCommandMetadata {
  templateId: string | null;
}

export interface AdminRedeemTarget {
  billingAccountId: string;
  productOwnerId: string;
  productOwnerType: "workspace";
  workspaceName?: string;
}

const freeRouterPolicySchema = z.object({
  revision: z.number().int().nonnegative(),
  models: z.array(z.object({ provider: z.string(), sku: z.string() })).max(100),
});
export type FreeRouterPolicy = z.infer<typeof freeRouterPolicySchema>;

const modelSelectionPolicySchema = z.object({
  mode: z.enum(["all", "selected"]),
  allowed_template_ids: z.array(z.string()).max(100),
  revision: z.number().int().nonnegative(),
});
export type ModelSelectionPolicy = z.infer<typeof modelSelectionPolicySchema>;

const platformTemplateSchema = z.object({
  template_id: z.string(),
  name: z.string(),
  model: z.string(),
  model_display_name: z.string().nullable().optional(),
  model_vendor: z.string().nullable().optional(),
  provider: z.string(),
});
export type PlatformTemplate = z.infer<typeof platformTemplateSchema>;

export interface AdminApi {
  getModelSelectionPolicy(options?: RequestOptions): Promise<ModelSelectionPolicy>;
  listPlatformTemplates(options?: RequestOptions): Promise<PlatformTemplate[]>;
  updateModelSelectionPolicy(
    policy: ModelSelectionPolicy,
    metadata: AdminCommandMetadata
  ): Promise<ModelSelectionPolicy>;
  getFreeRouterModels(options?: RequestOptions): Promise<FreeRouterPolicy>;
  updateFreeRouterModels(
    policy: FreeRouterPolicy,
    metadata: AdminCommandMetadata
  ): Promise<FreeRouterPolicy>;
  executeAgentVmmCommand(
    tenantId: string,
    action: AgentVmmAction,
    targetId: string,
    expectedRevision: number,
    metadata: AdminCommandMetadata
  ): Promise<AgentVmmCommandResult>;
  getAgentVmmNode(
    tenantId: string,
    registrationId: string,
    options?: RequestOptions
  ): Promise<AgentVmmNode>;
  getAgentVmmOverview(
    tenantId: string,
    options?: RequestOptions
  ): Promise<AgentVmmOverview>;
  listAgentVmmNodes(
    tenantId: string,
    options?: RequestOptions & { cursor?: string; limit?: number }
  ): Promise<{ data: AgentVmmNode[]; hasMore: boolean; nextCursor?: string }>;
  applyRedeemCode(input: ApplyRedeemCodeInput): Promise<AdminRedemptionResult>;
  createOauthClient(input: CreateOauthClientInput): Promise<AdminOauthClientCreation>;
  createRedeemCode(input: CreateRedeemCodeInput): Promise<AdminRedeemCodeCreation>;
  createSupportSession(
    userId: string,
    input: CreateSupportSessionInput
  ): Promise<AdminSupportSession>;
  createUser(input: CreateAdminUserInput): Promise<AdminUser>;
  disableOauthClient(
    id: string,
    metadata: AdminCommandMetadata
  ): Promise<AdminOauthClient>;
  disableRedeemCode(
    id: string,
    metadata: AdminCommandMetadata
  ): Promise<AdminRedeemCode>;
  ensureDefaultWorkspace(
    userId: string,
    metadata: AdminCommandMetadata
  ): Promise<AdminWorkspaceResult>;
  getUser(id: string, options?: RequestOptions): Promise<AdminUser>;
  getUserWorkspaceBilling(
    id: string,
    options?: RequestOptions
  ): Promise<AdminWorkspaceBilling>;
  updateUserWorkspaceVm(
    userId: string,
    workspaceId: string,
    input: AdminCommandMetadata & { enabled: boolean }
  ): Promise<AdminWorkspaceVm>;
  getUserWorkspaceSignalNumber(
    userId: string,
    options?: RequestOptions
  ): Promise<AdminWorkspaceSignalNumber>;
  /** Sets the Workspace's own Signal number; an empty `number` uses the platform number. */
  updateUserWorkspaceSignalNumber(
    userId: string,
    input: AdminCommandMetadata & { number: string }
  ): Promise<AdminWorkspaceSignalNumber>;
  getUserWorkspaceAgentModels(
    id: string,
    options?: RequestOptions
  ): Promise<AdminWorkspaceAgentModels>;
  issueUserWorkspaceCredits(
    userId: string,
    input: IssueWorkspaceCreditsInput
  ): Promise<AdminManualGrantResult>;
  updateUserWorkspaceAgentModel(
    userId: string,
    role: AdminWorkspaceAgentRole,
    input: UpdateWorkspaceAgentModelInput
  ): Promise<AdminWorkspaceAgentModel>;
  listAuditEvents(
    options?: RequestOptions & { cursor?: string; limit?: number }
  ): Promise<{
    data: AdminAuditEvent[];
    hasMore: boolean;
    nextCursor?: string;
  }>;
  listOauthClients(options?: RequestOptions): Promise<AdminOauthClient[]>;
  listPackageVersions(options?: RequestOptions): Promise<AdminPackageVersion[]>;
  listRedeemCodes(
    options?: RequestOptions & { limit?: number }
  ): Promise<AdminRedeemCode[]>;
  listRedemptions(
    options: RequestOptions & { limit?: number; redeemCodeId: string }
  ): Promise<AdminRedemption[]>;
  listUserSessions(
    userId: string,
    options?: RequestOptions & { cursor?: string; limit?: number }
  ): Promise<{
    data: AdminSession[];
    hasMore: boolean;
    nextCursor?: string;
  }>;
  listUsers(
    options?: RequestOptions & {
      cursor?: string;
      email?: string;
      limit?: number;
    }
  ): Promise<{
    data: AdminUser[];
    hasMore: boolean;
    nextCursor?: string;
  }>;
  setAdminAccess(
    userId: string,
    decision: "allow" | "deny",
    metadata: AdminCommandMetadata
  ): Promise<AdminUser>;
  revokeAllUserSessions(
    userId: string,
    metadata: AdminCommandMetadata
  ): Promise<{ revoked_count: number }>;
  rotateOauthClientSecret(
    id: string,
    metadata: AdminCommandMetadata
  ): Promise<AdminOauthClientSecret>;
  revokeUserSession(
    userId: string,
    sessionId: string,
    metadata: AdminCommandMetadata
  ): Promise<{ revoked: true; session_id: string }>;
  enableOauthClient(
    id: string,
    metadata: AdminCommandMetadata
  ): Promise<AdminOauthClient>;
  updateUser(userId: string, input: UpdateAdminUserInput): Promise<AdminUser>;
}

interface RequestOptions {
  signal?: AbortSignal;
}

export class AdminApiError extends Error {
  readonly code: string | undefined;
  readonly status: number;

  constructor(status: number, message: string, code?: string) {
    super(message);
    this.name = "AdminApiError";
    this.status = status;
    this.code = code;
  }
}

export function createAdminApi({
  baseUrl,
  fetch: fetchImpl = fetch,
  sessionTransport,
}: {
  baseUrl: string;
  fetch?: typeof fetch;
  sessionTransport: CommaApiSessionTransport;
}): AdminApi {
  const normalizedBaseUrl = baseUrl.replace(/\/+$/, "");

  async function request<T extends z.ZodType>(
    path: string,
    schema: T,
    options: {
      body?: unknown;
      method?: "GET" | "PATCH" | "POST" | "PUT";
      signal?: AbortSignal;
    } = {}
  ): Promise<z.output<T>> {
    const headers: Record<string, string> = {
      accept: "application/json",
    };
    if (options.body !== undefined) {
      headers["content-type"] = "application/json";
    }
    sessionTransport.applyHeaders(headers);

    const response = await fetchImpl(`${normalizedBaseUrl}${path}`, {
      credentials: sessionTransport.credentials,
      headers,
      method: options.method ?? "GET",
      ...(options.body !== undefined ? { body: JSON.stringify(options.body) } : {}),
      signal: combineSignals(options.signal, sessionTransport.signal),
    });
    const value = await readJson(response);

    if (!response.ok) {
      const error = apiError(response, value);

      if (response.status === 401) {
        sessionTransport.reportSessionRejection(401);
      } else if (response.status === 409 && isSessionChanged(value)) {
        sessionTransport.reportSessionRejection(409);
      }

      throw error;
    }

    return schema.parse(value);
  }

  return {
    executeAgentVmmCommand(tenantId, action, targetId, expectedRevision, metadata) {
      return request(
        `/v1/comma/admin/compute/agent-vmm/commands/${encodeURIComponent(action)}/${encodeURIComponent(targetId)}`,
        agentVmmCommandResultSchema,
        {
          body: {
            ...commandBody(metadata),
            expected_revision: expectedRevision,
            tenant_id: tenantId,
          },
          method: "POST",
        }
      );
    },

    getAgentVmmNode(tenantId, registrationId, options = {}) {
      const query = queryString({ tenant_id: tenantId });
      return request(
        `/v1/comma/admin/compute/agent-vmm/nodes/${encodeURIComponent(registrationId)}${query}`,
        agentVmmNodeSchema,
        options
      );
    },

    getAgentVmmOverview(tenantId, options = {}) {
      const query = queryString({ tenant_id: tenantId });
      return request(
        `/v1/comma/admin/compute/agent-vmm/overview${query}`,
        agentVmmOverviewSchema,
        options
      );
    },

    async listAgentVmmNodes(tenantId, options = {}) {
      const query = queryString({
        cursor: options.cursor,
        limit: options.limit,
        tenant_id: tenantId,
      });
      const page = await request(
        `/v1/comma/admin/compute/agent-vmm/nodes${query}`,
        agentVmmNodePageSchema,
        options
      );
      return {
        data: page.data,
        hasMore: page.has_more,
        ...(page.next_cursor ? { nextCursor: page.next_cursor } : {}),
      };
    },

    applyRedeemCode(input) {
      return request(
        "/v1/comma/admin/billing/redeem-codes/apply",
        redemptionResultSchema,
        {
          body: {
            billing_account_id: input.billingAccountId,
            confirmation: input.confirmation,
            id: input.codeId,
            idempotency_key: input.idempotencyKey,
            product_owner_id: input.productOwnerId,
            product_owner_type: input.productOwnerType,
            reason: input.reason,
          },
          method: "POST",
        }
      );
    },

    createOauthClient(input) {
      return request("/v1/comma/admin/oauth-clients", adminOauthClientCreationSchema, {
        body: {
          ...commandBody(input),
          confidential: input.confidential,
          name: input.name,
          redirect_uris: input.redirectUris,
        },
        method: "POST",
      });
    },

    async createRedeemCode(input) {
      const record = await request(
        "/v1/comma/admin/billing/redeem-codes",
        redeemCodeSchema,
        {
          body: {
            ...(input.code ? { code: input.code } : {}),
            confirmation: input.confirmation,
            ...(input.expiresAt ? { expires_at: input.expiresAt } : {}),
            idempotency_key: input.idempotencyKey,
            ...(input.maxRedemptions !== undefined
              ? { max_redemptions: input.maxRedemptions }
              : {}),
            package_code: input.packageCode,
            package_version: input.packageVersion,
            ...(input.perAccountLimit !== undefined
              ? { per_account_limit: input.perAccountLimit }
              : {}),
            reason: input.reason,
          },
          method: "POST",
        }
      );

      return typeof record.code === "string"
        ? {
            kind: "created" as const,
            record: record as AdminRedeemCode & { code: string },
          }
        : { kind: "recovered_redacted" as const, record };
    },

    createSupportSession(userId, input) {
      return request(
        `/v1/comma/admin/users/${encodeURIComponent(userId)}/support-sessions`,
        supportSessionSchema,
        {
          body: {
            budget: input.budget,
            confirmation: input.confirmation,
            ...(input.conversationId ? { conversation_id: input.conversationId } : {}),
            expires_in_seconds: input.expiresInSeconds,
            idempotency_key: input.idempotencyKey,
            reason: input.reason,
            ...(input.toolAllowlist ? { tool_allowlist: input.toolAllowlist } : {}),
            ...(input.workspaceId ? { workspace_id: input.workspaceId } : {}),
          },
          method: "POST",
        }
      );
    },

    createUser(input) {
      return request("/v1/comma/admin/users", adminUserSchema, {
        body: {
          ...(input.adminAccess ? { admin_access: input.adminAccess } : {}),
          confirmation: input.confirmation,
          email: input.email,
          idempotency_key: input.idempotencyKey,
          ...(input.name ? { name: input.name } : {}),
          reason: input.reason,
          ...(input.status ? { status: input.status } : {}),
        },
        method: "POST",
      });
    },

    disableOauthClient(id, metadata) {
      return request(
        `/v1/comma/admin/oauth-clients/${encodeURIComponent(id)}/disable`,
        adminOauthClientSchema,
        {
          body: commandBody(metadata),
          method: "POST",
        }
      );
    },

    disableRedeemCode(id, metadata) {
      return request(
        `/v1/comma/admin/billing/redeem-codes/${encodeURIComponent(id)}/disable`,
        redeemCodeSchema,
        {
          body: commandBody(metadata),
          method: "POST",
        }
      );
    },

    ensureDefaultWorkspace(userId, metadata) {
      return request(
        `/v1/comma/admin/users/${encodeURIComponent(userId)}/workspaces`,
        workspaceResultSchema,
        {
          body: commandBody(metadata),
          method: "POST",
        }
      );
    },

    getUser(id, options = {}) {
      return request(
        `/v1/comma/admin/users/${encodeURIComponent(id)}`,
        adminUserSchema,
        options
      );
    },

    getUserWorkspaceBilling(id, options = {}) {
      return request(
        `/v1/comma/admin/users/${encodeURIComponent(id)}/workspaces`,
        adminWorkspaceBillingSchema,
        options
      );
    },

    updateUserWorkspaceVm(userId, workspaceId, input) {
      return request(
        `/v1/comma/admin/users/${encodeURIComponent(userId)}/workspaces/${encodeURIComponent(workspaceId)}/vm`,
        adminWorkspaceVmSchema,
        {
          body: { ...commandBody(input), enabled: input.enabled },
          method: "PUT",
        }
      );
    },

    getUserWorkspaceSignalNumber(userId, options = {}) {
      return request(
        `/v1/comma/admin/users/${encodeURIComponent(userId)}/workspaces/signal-number`,
        adminWorkspaceSignalNumberSchema,
        options
      );
    },

    updateUserWorkspaceSignalNumber(userId, input) {
      return request(
        `/v1/comma/admin/users/${encodeURIComponent(userId)}/workspaces/signal-number`,
        adminWorkspaceSignalNumberSchema,
        {
          body: { ...commandBody(input), number: input.number },
          method: "PUT",
        }
      );
    },

    getUserWorkspaceAgentModels(id, options = {}) {
      return request(
        `/v1/comma/admin/users/${encodeURIComponent(id)}/workspaces/agent-models`,
        adminWorkspaceAgentModelsSchema,
        options
      );
    },

    issueUserWorkspaceCredits(userId, input) {
      return request(
        `/v1/comma/admin/users/${encodeURIComponent(userId)}/workspace-credits`,
        manualGrantResultSchema,
        {
          body: {
            confirmation: input.confirmation,
            expires_at: input.expiresAt,
            idempotency_key: input.idempotencyKey,
            package_code: input.packageCode,
            package_version: input.packageVersion,
            reason: input.reason,
          },
          method: "POST",
        }
      );
    },

    updateUserWorkspaceAgentModel(userId, role, input) {
      return request(
        `/v1/comma/admin/users/${encodeURIComponent(userId)}/workspaces/agent-models/${role}`,
        adminWorkspaceAgentModelSchema,
        {
          body: {
            ...commandBody(input),
            template_id: input.templateId,
          },
          method: "PUT",
        }
      );
    },

    async listAuditEvents(options = {}) {
      const query = queryString({
        cursor: options.cursor,
        limit: options.limit,
      });
      const page = await request(
        `/v1/comma/admin/audit-events${query}`,
        adminAuditEventPageSchema,
        options
      );

      return {
        data: page.data,
        hasMore: page.has_more,
        ...(page.next_cursor ? { nextCursor: page.next_cursor } : {}),
      };
    },

    async listOauthClients(options = {}) {
      const page = await request(
        "/v1/comma/admin/oauth-clients",
        dataPage(adminOauthClientSchema),
        options
      );
      return page.data;
    },

    getFreeRouterModels(options = {}) {
      return request(
        "/v1/comma/admin/billing/free-router-models",
        freeRouterPolicySchema,
        options
      );
    },
    getModelSelectionPolicy(options = {}) {
      return request(
        "/v1/comma/admin/model-selection-policy",
        modelSelectionPolicySchema,
        options
      );
    },
    async listPlatformTemplates(options = {}) {
      const page = await request(
        "/v1/comma/admin/model-selection-policy/templates",
        z.object({ data: z.array(platformTemplateSchema).max(100) }),
        options
      );
      return page.data;
    },
    updateModelSelectionPolicy(policy, metadata) {
      return request(
        "/v1/comma/admin/model-selection-policy",
        modelSelectionPolicySchema,
        {
          method: "PUT",
          body: { ...policy, ...commandBody(metadata) },
        }
      );
    },
    updateFreeRouterModels(policy, metadata) {
      return request(
        "/v1/comma/admin/billing/free-router-models",
        freeRouterPolicySchema,
        {
          method: "PUT",
          body: { ...policy, ...commandBody(metadata) },
        }
      );
    },

    async listPackageVersions(options = {}) {
      const page = await request(
        "/v1/comma/admin/billing/package-versions?surface=comma",
        dataPage(packageVersionSchema),
        options
      );
      return page.data;
    },

    async listRedeemCodes(options = {}) {
      const query = queryString({ limit: options.limit });
      const page = await request(
        `/v1/comma/admin/billing/redeem-codes${query}`,
        dataPage(redeemCodeSchema),
        options
      );
      return page.data;
    },

    async listRedemptions(options) {
      const query = queryString({
        redeem_code_id: options.redeemCodeId,
        limit: options.limit,
      });
      const page = await request(
        `/v1/comma/admin/billing/redemptions${query}`,
        dataPage(redemptionSchema),
        options
      );
      return page.data;
    },

    async listUserSessions(userId, options = {}) {
      const query = queryString({
        cursor: options.cursor,
        limit: options.limit,
      });
      const page = await request(
        `/v1/comma/admin/users/${encodeURIComponent(userId)}/sessions${query}`,
        adminSessionPageSchema,
        options
      );

      return {
        data: page.data,
        hasMore: page.has_more,
        ...(page.next_cursor ? { nextCursor: page.next_cursor } : {}),
      };
    },

    async listUsers(options = {}) {
      const query = queryString({
        cursor: options.cursor,
        email: options.email,
        limit: options.limit,
      });
      const page = await request(
        `/v1/comma/admin/users${query}`,
        adminUserPageSchema,
        options
      );

      return {
        data: page.data,
        hasMore: page.has_more,
        ...(page.next_cursor ? { nextCursor: page.next_cursor } : {}),
      };
    },

    setAdminAccess(userId, decision, metadata) {
      return request(
        `/v1/comma/admin/users/${encodeURIComponent(userId)}/admin-access`,
        adminUserSchema,
        {
          body: {
            ...commandBody(metadata),
            decision,
          },
          method: "PUT",
        }
      );
    },

    revokeAllUserSessions(userId, metadata) {
      return request(
        `/v1/comma/admin/users/${encodeURIComponent(userId)}/sessions/revoke-all`,
        revokeAllSessionsResultSchema,
        {
          body: commandBody(metadata),
          method: "POST",
        }
      );
    },

    rotateOauthClientSecret(id, metadata) {
      return request(
        `/v1/comma/admin/oauth-clients/${encodeURIComponent(id)}/rotate-secret`,
        adminOauthClientSecretSchema,
        {
          body: commandBody(metadata),
          method: "POST",
        }
      );
    },

    revokeUserSession(userId, sessionId, metadata) {
      return request(
        `/v1/comma/admin/users/${encodeURIComponent(userId)}/sessions/${encodeURIComponent(sessionId)}/revoke`,
        revokeSessionResultSchema,
        {
          body: commandBody(metadata),
          method: "POST",
        }
      );
    },

    enableOauthClient(id, metadata) {
      return request(
        `/v1/comma/admin/oauth-clients/${encodeURIComponent(id)}/enable`,
        adminOauthClientSchema,
        {
          body: commandBody(metadata),
          method: "POST",
        }
      );
    },

    updateUser(userId, input) {
      return request(
        `/v1/comma/admin/users/${encodeURIComponent(userId)}`,
        adminUserSchema,
        {
          body: {
            confirmation: input.confirmation,
            idempotency_key: input.idempotencyKey,
            ...(input.name !== undefined ? { name: input.name } : {}),
            reason: input.reason,
            ...(input.status ? { status: input.status } : {}),
          },
          method: "PATCH",
        }
      );
    },
  };
}

export function createIdempotencyKey(prefix: string) {
  return `${prefix}:${crypto.randomUUID()}`;
}

export function isAdminAccessDenied(error: unknown) {
  return (
    error instanceof AdminApiError && error.status === 403 && error.code === "forbidden"
  );
}

export function isAdminSessionRejection(error: unknown) {
  return (
    error instanceof AdminApiError &&
    (error.status === 401 ||
      (error.status === 409 &&
        (error.code === "session_changed" ||
          error.code === "session_product_lease_unavailable")))
  );
}

function queryString(values: Record<string, string | number | undefined>) {
  const query = new URLSearchParams();

  for (const [key, value] of Object.entries(values)) {
    if (value !== undefined && value !== "") {
      query.set(key, String(value));
    }
  }

  const encoded = query.toString();
  return encoded ? `?${encoded}` : "";
}

function commandBody(metadata: AdminCommandMetadata) {
  return {
    confirmation: metadata.confirmation,
    idempotency_key: metadata.idempotencyKey,
    reason: metadata.reason,
  };
}

function combineSignals(
  requestSignal: AbortSignal | undefined,
  sessionSignal: AbortSignal
) {
  if (!requestSignal || requestSignal === sessionSignal) {
    return requestSignal ?? sessionSignal;
  }
  return AbortSignal.any([requestSignal, sessionSignal]);
}

async function readJson(response: Response): Promise<unknown> {
  try {
    return await response.json();
  } catch {
    return undefined;
  }
}

function apiError(response: Response, value: unknown) {
  const parsed = errorBodySchema.safeParse(value);
  const bodyError = parsed.success ? parsed.data.error : undefined;
  const code =
    typeof bodyError === "string"
      ? bodyError
      : bodyError && typeof bodyError.code === "string"
        ? bodyError.code
        : undefined;

  return new AdminApiError(
    response.status,
    code || `${response.status} ${response.statusText}`,
    code
  );
}

function isSessionChanged(value: unknown) {
  const parsed = errorBodySchema.safeParse(value);
  if (!parsed.success) {
    return false;
  }

  const error = parsed.data.error;
  return (
    error === "session_changed" ||
    (typeof error === "object" && error?.code === "session_product_lease_unavailable")
  );
}
