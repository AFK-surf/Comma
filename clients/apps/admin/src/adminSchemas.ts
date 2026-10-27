// What the Admin API answers, as Effect Schemas. Each endpoint decodes in one of two modes (adminApi.ts): a strict
// endpoint rejects any field it does not declare (`onExcessProperty: "error"`, applied through the whole answer), and
// a lenient one drops them. A projection that keeps undeclared fields (`passthrough`) is a struct with a rest record,
// so it keeps them in either mode.
import { Schema } from "effect";

const Passthrough = [Schema.Record(Schema.String, Schema.Unknown)] as const;

/** A struct that keeps the fields it does not declare. */
function passthrough<const Fields extends Schema.Struct.Fields>(fields: Fields) {
  return Schema.StructWithRest(Schema.Struct(fields), Passthrough);
}

const nullish = <S extends Schema.Top>(schema: S) =>
  Schema.optional(Schema.NullOr(schema));
const NonNegative = Schema.Finite.check(Schema.isGreaterThanOrEqualTo(0));
const WholeNonNegative = Schema.Finite.check(
  Schema.isInt(),
  Schema.isGreaterThanOrEqualTo(0)
);
const WholePositive = Schema.Finite.check(Schema.isInt(), Schema.isGreaterThan(0));
const Whole = Schema.Finite.check(Schema.isInt());
const NonEmpty = Schema.String.check(Schema.isMinLength(1));

const AdminLoginMethod = Schema.Union([
  Schema.Struct({ method: Schema.Literal("ssh_public_key") }),
  passthrough({
    method: Schema.Literals(["email_otp", "review_code"]),
    email: Schema.String,
  }),
  passthrough({
    method: Schema.Literal("google"),
    email_snapshot: Schema.String,
    email_verified: Schema.Boolean,
    linked_at: nullish(Schema.Finite),
    last_authenticated_at: nullish(Schema.Finite),
  }),
]);

export const AdminUser = passthrough({
  id: Schema.String,
  email: nullish(Schema.String),
  name: nullish(Schema.String),
  status: nullish(Schema.String),
  created_at: nullish(Schema.Finite),
  updated_at: nullish(Schema.Finite),
  review_login_configured: Schema.optional(Schema.Boolean),
  login_methods: Schema.optional(Schema.Array(AdminLoginMethod)),
  admin_access: Schema.optional(
    Schema.Struct({
      allowed: Schema.Boolean,
      decision: Schema.NullOr(Schema.Literals(["allow", "deny"])),
      source: Schema.Literals([
        "disabled",
        "domain_default",
        "explicit_allow",
        "explicit_deny",
        "none",
      ]),
    })
  ),
});

export const AdminUserPage = passthrough({
  data: Schema.Array(AdminUser),
  has_more: Schema.Boolean,
  next_cursor: Schema.NullOr(Schema.String),
});

export const AdminSession = Schema.Struct({
  id: Schema.String,
  auth_method: Schema.NullOr(
    Schema.Literals([
      "email_otp",
      "review_code",
      "google",
      "apple",
      "watch_pairing",
      "ssh_public_key",
    ])
  ),
  session_source: Schema.Literals(["user_login", "ops_api"]),
  authenticated_at: Schema.NullOr(Schema.Finite),
  expires_at: Schema.Finite,
  last_seen_at: Schema.NullOr(Schema.Finite),
  revoked_at: Schema.NullOr(Schema.Finite),
  client_kind: Schema.NullOr(
    Schema.Literals(["web", "electron", "android", "ios", "watch", "api", "ssh"])
  ),
  device_label: Schema.NullOr(Schema.String),
  restricted: Schema.Boolean,
});

export const AdminSessionPage = Schema.Struct({
  data: Schema.Array(AdminSession),
  has_more: Schema.Boolean,
  next_cursor: Schema.NullOr(Schema.String),
});

export const AdminWorkspaceVm = Schema.Struct({
  workspace_id: Schema.String,
  enabled: Schema.Boolean,
  convergence_status: Schema.NullOr(Schema.String),
});

const AdminSignalAccount = Schema.Struct({
  e164: nullish(Schema.String),
  state: nullish(Schema.String),
  scope: nullish(Schema.String),
});

export const AdminWorkspaceSignalNumber = Schema.Struct({
  workspace_id: Schema.optional(Schema.String),
  override: nullish(AdminSignalAccount),
  platform: nullish(AdminSignalAccount),
  effective: nullish(AdminSignalAccount),
});

export const AdminWorkspaceSandboxLimit = Schema.Struct({
  workspace_id: Schema.optional(Schema.String),
  override: nullish(Schema.Int),
  default: nullish(Schema.Int),
  effective: nullish(Schema.Int),
});

export const AdminWorkspaceBilling = Schema.Struct({
  workspace: Schema.NullOr(
    Schema.Struct({
      id: Schema.String,
      name: Schema.NullOr(Schema.String),
      status: Schema.Literals(["provisioning", "ready", "failed", "suspended"]),
      tenant_id: Schema.String,
      group_id: Schema.String,
      billing_account_id: Schema.String,
      cloud_vm: Schema.optional(AdminWorkspaceVm),
      created_at: Schema.Finite,
      updated_at: Schema.Finite,
    })
  ),
  billing: Schema.NullOr(
    Schema.Struct({
      account_id: Schema.String,
      account_status: Schema.Literals([
        "active",
        "inactive",
        "missing",
        "identity_mismatch",
      ]),
      current_credits: NonNegative,
      active_grants: Schema.Array(
        Schema.Struct({
          id: Schema.String,
          package_code: Schema.NullOr(Schema.String),
          package_version: Schema.NullOr(Schema.String),
          remaining_credits: NonNegative,
          valid_from: Schema.String,
          expires_at: Schema.NullOr(Schema.String),
          source_type: Schema.String,
          source_id: Schema.NullOr(Schema.String),
        })
      ),
      has_more: Schema.Boolean,
    })
  ),
});

export const AdminWorkspaceAgentRole = Schema.Literals(["router", "worker"]);

/** What an agent chose: Comma's built-in model, a catalog model, or its runtime's model. */
export const AdminWorkspaceAgentSelection = Schema.Union([
  Schema.Struct({ kind: Schema.Literal("builtin") }),
  Schema.Struct({
    kind: Schema.Literal("catalog"),
    model: Schema.String,
    reasoning_effort: nullish(Schema.String),
    allow_paid: Schema.optional(Schema.Boolean),
    profile_id: nullish(Schema.String),
  }),
  Schema.Struct({
    kind: Schema.Literal("runtime"),
    model: Schema.String,
    reasoning_effort: nullish(Schema.String),
  }),
]);

export const AdminWorkspaceAgentModel = Schema.Struct({
  agent_id: Schema.String,
  name: Schema.optional(Schema.String),
  scope: nullish(Schema.Literals(["global", "tenant"])),
  role: AdminWorkspaceAgentRole,
  // Whether the agent chose its model or follows the platform model.
  source: Schema.optional(Schema.Literals(["pinned", "platform_default"])),
  model: Schema.String,
  model_display_name: nullish(Schema.String),
  model_vendor: nullish(Schema.String),
  model_icon: nullish(Schema.String),
  // Any subscription plan the backend pools, such as `codex` or `gemini`.
  account_pool: nullish(Schema.String),
  reasoning_effort: nullish(Schema.String),
  provider: Schema.String,
  selection: Schema.optional(AdminWorkspaceAgentSelection),
});

/** A Worker that runs on a connected or compute runtime and names no model of its own. */
const RuntimeAgentModel = Schema.Struct({
  agent_id: Schema.String,
  name: Schema.String,
  role: Schema.Literal("worker"),
  source: Schema.Literals(["agent_config", "runtime_default"]),
  model: Schema.NullOr(Schema.String),
  provider: Schema.NullOr(Schema.String),
  reasoning_effort: Schema.NullOr(Schema.String),
  runtime: Schema.Struct({
    kind: Schema.Literals(["connected", "compute"]),
    provider: Schema.String,
  }),
});

/** The agent a model change answers with: a model agent, or a runtime Worker. */
export const AdminWorkspaceAgentModelChange = Schema.Union([
  AdminWorkspaceAgentModel,
  RuntimeAgentModel,
]);

/** The platform model a role follows when nothing is chosen for it. */
export const AdminWorkspacePlatformModel = Schema.Struct({
  name: nullish(Schema.String),
  model: Schema.String,
  provider: nullish(Schema.String),
  model_display_name: nullish(Schema.String),
  model_vendor: nullish(Schema.String),
  model_icon: nullish(Schema.String),
});

export const AdminWorkspaceAgentModels = Schema.Struct({
  workspace_id: Schema.String,
  workers: Schema.optional(
    Schema.Struct({
      items: Schema.Array(
        Schema.Union([AdminWorkspaceAgentModel, RuntimeAgentModel])
      ).check(Schema.isMaxLength(50)),
      next_cursor: Schema.NullOr(Schema.String),
    })
  ),
  agents: Schema.Struct({
    router: AdminWorkspaceAgentModel,
    // Null for a workspace created without a default Worker.
    worker: Schema.NullOr(AdminWorkspaceAgentModel),
  }),
  platform_defaults: Schema.optional(
    Schema.Struct({
      router: Schema.NullOr(AdminWorkspacePlatformModel),
      worker: Schema.NullOr(AdminWorkspacePlatformModel),
    })
  ),
});

export const AdminAuditEvent = Schema.Struct({
  id: Schema.String,
  action: NonEmpty,
  outcome: Schema.Literals(["started", "succeeded", "failed", "rejected"]),
  actor: Schema.Struct({
    type: Schema.Literals(["comma_user", "ops"]),
    user_id: Schema.NullOr(Schema.String),
    email: Schema.NullOr(Schema.String),
  }),
  target: Schema.Struct({ type: Schema.String, id: Schema.String }),
  reason: Schema.String,
  error_code: Schema.NullOr(Schema.String),
  created_at: Schema.Finite,
  updated_at: Schema.Finite,
});

export const AdminAuditEventPage = Schema.Struct({
  data: Schema.Array(AdminAuditEvent),
  has_more: Schema.Boolean,
  next_cursor: Schema.NullOr(Schema.String),
});

export const AdminLookup = Schema.Struct({
  data: Schema.Array(
    Schema.Struct({
      match: Schema.Literals([
        "email",
        "user_id",
        "workspace_id",
        "tenant_id",
        "group_id",
      ]),
      user: AdminUser,
      workspace: Schema.NullOr(
        Schema.Struct({
          id: Schema.String,
          name: Schema.NullOr(Schema.String),
          tenant_id: Schema.NullOr(Schema.String),
          group_id: Schema.NullOr(Schema.String),
        })
      ),
    })
  ).check(Schema.isMaxLength(20)),
});

export const AdminUserStats = Schema.Struct({
  registered_total: Schema.Finite,
  registered_team: Schema.Finite,
  team_email_domain: Schema.String,
  new_by_day: Schema.Array(
    Schema.Struct({ date: Schema.String, count: Schema.Finite })
  ),
});

const oauthClientFields = {
  id: Schema.String,
  name: Schema.String,
  confidential: Schema.Boolean,
  redirect_uris: Schema.Array(Schema.String),
  disabled_at: Schema.NullOr(Schema.String),
  created_at: Schema.NullOr(Schema.String),
};

export const AdminOauthClient = Schema.Struct(oauthClientFields);

export const AdminOauthClientSecret = Schema.Struct({
  ...oauthClientFields,
  confidential: Schema.Literal(true),
  client_secret: NonEmpty,
});

export const AdminOauthClientCreation = Schema.Union([
  AdminOauthClientSecret,
  Schema.Struct({ ...oauthClientFields, confidential: Schema.Literal(false) }),
]);

export const RevokeSessionResult = Schema.Struct({
  revoked: Schema.Literal(true),
  session_id: Schema.String,
});

export const RevokeAllSessionsResult = Schema.Struct({
  revoked_count: WholeNonNegative,
});

export const AdminPackageVersion = passthrough({
  id: Schema.String,
  package_code: Schema.String,
  package_name: nullish(Schema.String),
  version: Schema.String,
  surface: Schema.String,
  kind: Schema.String,
  billing_period: nullish(Schema.String),
  grant_credits: Schema.Finite,
  grant_period: Schema.String,
  currency: nullish(Schema.String),
  amount_minor: nullish(Schema.Finite),
  effective_at: nullish(Schema.String),
  expires_at: nullish(Schema.String),
  status: Schema.String,
});

export const AdminRedeemCode = Schema.Struct({
  id: Schema.String,
  display_prefix: nullish(Schema.String),
  package_code: Schema.String,
  package_version: Schema.String,
  code_type: nullish(Schema.String),
  surface: nullish(Schema.String),
  scope_product_owner_type: nullish(Schema.String),
  scope_product_owner_id: nullish(Schema.String),
  status: nullish(Schema.String),
  max_redemptions: nullish(Schema.Finite),
  per_account_limit: nullish(Schema.Finite),
  valid_from: nullish(Schema.String),
  expires_at: nullish(Schema.String),
  metadata: Schema.optional(Schema.Unknown),
  code: Schema.optional(Schema.String),
});

export const AdminRedemption = Schema.Struct({
  id: Schema.String,
  redeem_code_id: Schema.String,
  billing_account_id: Schema.String,
  surface: nullish(Schema.String),
  product_owner_type: nullish(Schema.String),
  product_owner_id: nullish(Schema.String),
  source_type: nullish(Schema.String),
  source_id: nullish(Schema.String),
  source_event_id: nullish(Schema.String),
  idempotency_key: nullish(Schema.String),
  operator_snapshot: Schema.optional(Schema.Unknown),
  status: nullish(Schema.String),
  metadata: Schema.optional(Schema.Unknown),
});

/** A `{data: [...]}` page that keeps any other fields. */
export const DataPage = <S extends Schema.Top>(item: S) =>
  passthrough({ data: Schema.Array(item) });

export const AdminSupportSession = passthrough({
  id: Schema.String,
  token: Schema.String,
  expires_at: Schema.Finite,
  restricted: Schema.Literal(true),
  interaction_budget_remaining: nullish(Schema.Finite),
  tool_allowlist: Schema.optional(Schema.Array(Schema.String)),
  workspace_id: nullish(Schema.String),
  conversation_id: nullish(Schema.String),
});

export const AdminWorkspaceResult = passthrough({
  status: Schema.Literals(["provisioning", "ready"]),
  retry_after_seconds: Schema.optional(Schema.Finite),
  workspace: passthrough({ id: Schema.String, status: Schema.String }),
});

export const AdminRedemptionResult = Schema.Struct({
  redemption: AdminRedemption,
  idempotent: Schema.Boolean,
});

export const AdminManualGrantResult = Schema.Struct({
  manual_grant: Schema.Struct({
    id: Schema.String,
    billing_account_id: Schema.String,
    package_code: Schema.String,
    package_version: Schema.String,
    source_type: Schema.String,
    source_id: Schema.String,
    source_event_id: Schema.String,
    operator_snapshot: Schema.Struct({
      id: Schema.String,
      type: Schema.String,
      reason: Schema.NullOr(Schema.String),
    }),
    valid_from: Schema.String,
    expires_at: Schema.String,
    credit_grant_id: Schema.String,
    status: Schema.String,
  }),
  grant: Schema.NullOr(
    Schema.Struct({
      id: Schema.String,
      billing_account_id: Schema.String,
      package_code: Schema.optional(Schema.String),
      package_version: Schema.optional(Schema.String),
      initial_credits: Schema.optional(NonNegative),
      remaining_credits: NonNegative,
      valid_from: Schema.optional(Schema.String),
      expires_at: nullish(Schema.String),
      source_type: Schema.optional(Schema.String),
      source_id: Schema.optional(Schema.String),
      source_event_id: Schema.optional(Schema.String),
      status: Schema.String,
    })
  ),
  idempotent: Schema.Boolean,
});

export const AgentVmmOverview = passthrough({
  total: WholeNonNegative,
  ready: WholeNonNegative,
  needs_attention: WholeNonNegative,
  disabled: WholeNonNegative,
  revoked: WholeNonNegative,
  enrolling: WholeNonNegative,
  draining: WholeNonNegative,
  disconnected_or_stale: WholeNonNegative,
  lease_expiring: WholeNonNegative,
  unknown_outcome: WholeNonNegative,
});

export const AgentVmmEnvironment = passthrough({
  id: Schema.String,
  owner_type: Schema.String,
  owner_id: Schema.String,
  desired_state: Schema.String,
  observed_state: Schema.String,
  generation: Whole,
  revision: WholeNonNegative,
  binding_status: Schema.String,
  allocations: WholeNonNegative,
  workloads: WholeNonNegative,
  runtimes: WholeNonNegative,
  updated_at: Schema.String,
});

export const AgentVmmNode = passthrough({
  id: Schema.String,
  device_id: Schema.NullOr(Schema.String),
  group_id: Schema.String,
  status: Schema.String,
  issue: Schema.NullOr(Schema.String),
  updated_at: Schema.String,
  registration: passthrough({
    status: Schema.String,
    desired_enabled: Schema.Boolean,
    revision: WholeNonNegative,
  }),
  installation: Schema.NullOr(
    passthrough({
      id: Schema.String,
      revision: WholeNonNegative,
      status: Schema.String,
      error_code: Schema.NullOr(Schema.String),
      retryable: Schema.Boolean,
    })
  ),
  connection: passthrough({
    status: Schema.String,
    last_observed_at: Schema.NullOr(Schema.String),
    binding_count: WholeNonNegative,
  }),
  work: Schema.Record(Schema.String, Schema.Unknown),
  operations: Schema.Record(Schema.String, Schema.Unknown),
  environments: Schema.optional(Schema.Array(AgentVmmEnvironment)),
});

export const AgentVmmNodePage = Schema.Struct({
  data: Schema.Array(AgentVmmNode),
  has_more: Schema.Boolean,
  next_cursor: Schema.NullOr(Schema.String),
});

export const AgentVmmCommandResult = Schema.Struct({
  accepted: Schema.Literal(true),
  action: Schema.String,
  target: Schema.String,
  result_revision: WholeNonNegative,
});

export const FreeRouterPolicy = Schema.Struct({
  revision: WholeNonNegative,
  models: Schema.Array(
    Schema.Struct({ provider: Schema.String, sku: Schema.String })
  ).check(Schema.isMaxLength(100)),
});

export const GuestModePolicy = Schema.Struct({
  enabled: Schema.Boolean,
  salix_tenant_id: Schema.NullOr(Schema.String),
  daily_creation_limit: WholeNonNegative,
  tenant_concurrency: WholePositive,
  session_ttl_seconds: WholePositive,
  pow_difficulty: WholePositive,
  revision: WholeNonNegative,
  created_today: WholeNonNegative,
});
