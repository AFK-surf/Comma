import { z } from "zod";

/*
 * Same-origin JSON contract served by Phoenix under /dashboard/api/v1. The
 * session cookie authenticates every request, so the SPA carries no auth code.
 * Success bodies are `{ok: true, data}`; errors are `{ok: false, error}`.
 * Objects are parsed leniently: unknown fields are dropped, never rejected.
 */

const userSchema = z.object({
  id: z.string(),
  name: z.string().nullable(),
  email: z.string().nullable(),
});

const orgSummarySchema = z.object({
  slug: z.string(),
  name: z.string(),
});

export const sessionSchema = z.object({
  user: userSchema,
  orgs: z.array(orgSummarySchema),
});

export const orgContextSchema = z.object({
  user: userSchema,
  orgs: z.array(orgSummarySchema),
  org: z.object({
    slug: z.string(),
    name: z.string(),
    role: z.enum(["owner", "admin", "member"]).catch("member"),
  }),
  capabilities: z.object({
    operations: z.boolean(),
    triage: z.boolean(),
    information_flow: z.boolean(),
    meetings: z.boolean(),
    daily_brief: z.boolean().catch(false),
    settings: z.boolean(),
  }),
  projects: z.array(z.object({ id: z.string(), name: z.string() })),
});

export const projectStatuses = [
  "ready",
  "stale",
  "refreshing",
  "missing",
  "error",
] as const;

export const overviewSchema = z.object({
  project_count: z.number().int(),
  used_project_count: z.number().int(),
  conversation_count: z.number().int(),
  token_totals: z.object({
    input: z.number().int(),
    output: z.number().int(),
    cache_read: z.number().int(),
    cache_write: z.number().int(),
    total: z.number().int(),
  }),
  member_count: z.number().int(),
  runners: z.object({ total: z.number().int(), online: z.number().int() }),
  projects: z.array(
    z.object({
      id: z.string(),
      name: z.string(),
      conversation_count: z.number().int(),
      token_total: z.number().int(),
      status: z.enum(projectStatuses).catch("missing"),
      refreshed_at: z.string().nullable(),
    })
  ),
  attention: z.array(
    z.object({
      id: z.string(),
      severity: z.enum(["error", "warning"]).catch("warning"),
      title: z.string(),
      detail: z.string(),
      href: z.string(),
    })
  ),
  /** For org admins: members waiting for an OAuth client while none is set up. */
  oauth_waiting: z
    .object({ names: z.array(z.string()), truncated: z.boolean() })
    .nullable()
    .catch(null),
});

export const projectOverviewSchema = z.object({
  project: z.object({
    id: z.string(),
    name: z.string(),
    slug: z.string().nullable(),
    status: z.string(),
    created_at: z.string(),
    created_by: z.string().nullable(),
    // Least privilege when the server adds a role this client does not know.
    role: z.enum(["admin", "user"]).catch("user"),
  }),
  usage: z.object({
    conversation_count: z.number().int(),
    token_total: z.number().int(),
    refreshed_at: z.string().nullable(),
    status: z.enum(projectStatuses).catch("missing"),
  }),
  recent_conversations: z.array(
    z.object({
      id: z.string(),
      title: z.string().nullable().catch(null),
      status: z.string().nullable().catch(null),
      updated_at: z.string().nullable().catch(null),
      href: z.string(),
    })
  ),
  connected_providers: z.array(z.string()),
  agents: z.object({
    status: z.enum(["ok", "unavailable"]).catch("unavailable"),
    items: z.array(
      z.object({
        id: z.string(),
        name: z.string().nullable(),
        role: z.string(),
        lifecycle: z.string(),
      })
    ),
    truncated: z.boolean(),
  }),
});

export const healthStatuses = [
  "healthy",
  "degraded",
  "action_required",
  "critical",
  "unknown",
] as const;

export const signalStatuses = ["ok", "degraded", "unknown"] as const;

/*
 * Labels, details and reasons arrive localized from the server. Signal keys
 * are documented as delivery | integrations | runners | devices but are only
 * used as React keys, so a new key renders like any other.
 */
export const healthSchema = z.object({
  health: z.object({
    status: z.enum(healthStatuses).catch("unknown"),
    reasons: z.array(z.string()),
  }),
  signals: z.array(
    z.object({
      key: z.string(),
      label: z.string(),
      detail: z.string(),
      observed_at: z.string().nullable(),
      status: z.enum(signalStatuses).catch("unknown"),
    })
  ),
  runners: z.object({ total: z.number().int(), online: z.number().int() }),
  events: z.array(
    z.object({
      id: z.string(),
      occurred_at: z.string(),
      severity: z.string(),
      title: z.string(),
      summary: z.string(),
      href: z.string().nullable(),
    })
  ),
  audit_export_href: z.string(),
});

export const auditPageSchema = z.object({
  entries: z.array(
    z.object({
      id: z.string(),
      created_at: z.string(),
      actor: z.string(),
      action: z.string(),
      resource: z.string(),
      result: z.string(),
    })
  ),
  next_cursor: z.string().nullable(),
});

export const orgRoles = ["owner", "admin", "member"] as const;

const nullableText = z.string().nullable().catch(null);

export const onboardingSteps = ["swarm", "oauth", "connect"] as const;

/** The first-run checklist; `active` is false once it was skipped or finished. */
export const onboardingSchema = z.object({
  active: z.boolean(),
  steps: z
    .array(z.object({ id: z.enum(onboardingSteps), done: z.boolean() }))
    .catch([]),
  first_project_id: nullableText,
  oauth_configured: z.boolean().nullable().catch(null),
  /** The member already asked the admins to configure OAuth. */
  oauth_reminded: z.boolean().catch(false),
});

export const memberSchema = z.object({
  user_id: z.string(),
  name: nullableText,
  email: nullableText,
  mobile: nullableText,
  // Least privilege when the server adds a role this client does not know.
  role: z.enum(orgRoles).catch("member"),
  joined_at: nullableText,
  sso: z.boolean().catch(false),
  sso_provider: nullableText,
});

/** Every Members endpoint, reads and writes alike, answers with this page. */
export const membersSchema = z.object({
  viewer: z.object({
    user_id: z.string(),
    role: z.enum(orgRoles).catch("member"),
    can_manage: z.boolean().catch(false),
    can_grant_owner: z.boolean().catch(false),
  }),
  members: z.array(memberSchema),
});

export const runnerStatuses = [
  "online",
  "recently_lost",
  "degraded",
  "offline",
  "unknown",
] as const;

export const runnerSchema = z.object({
  id: z.string(),
  stable_id: nullableText,
  name: nullableText,
  status: nullableText,
  effective_status: z.enum(runnerStatuses).catch("unknown"),
  host_identity: nullableText,
  os_summary: nullableText,
  version: nullableText,
  component_versions: z.record(z.string(), z.string()).catch({}),
  update_available: z.boolean().catch(false),
  capacity: z.number().int().catch(0),
  current_connector_count: z.number().int().catch(0),
  last_seen_at: nullableText,
  last_seen_age_seconds: z.number().nullable().catch(null),
  connectors: z
    .object({
      total: z.number().int(),
      by_status: z.array(z.object({ status: z.string(), count: z.number().int() })),
    })
    .catch({ total: 0, by_status: [] }),
  // Only owners and admins receive credential state; `null` for everyone else.
  credential: z
    .object({
      active: z.boolean(),
      key_id: z.string().nullable(),
      created_at: z.string().nullable(),
    })
    .nullable()
    .catch(null),
});

export const runnersPageSchema = z.object({
  viewer: z.object({ can_manage: z.boolean().catch(false) }),
  runners: z.array(runnerSchema),
  total_count: z.number().int(),
  cursor: nullableText,
  next_cursor: nullableText,
  poll_interval_ms: z.number().int().positive().catch(5_000),
});

export const runnerConnectorsSchema = z.object({
  entries: z.array(
    z.object({
      id: z.string(),
      name: nullableText,
      provisioning_status: z.string().catch("unknown"),
      project_id: nullableText,
      project_name: nullableText,
    })
  ),
  cursor: nullableText,
  next_cursor: nullableText,
});

export const runnerOnboardingSchema = z.object({
  org_id: z.string(),
  api_base_url: z.string(),
  install_code_ttl_seconds: z.number().int().catch(900),
  local_steps: z.array(
    z.object({
      id: z.string(),
      group: z.enum(["primary", "advanced"]).catch("advanced"),
      title: z.string(),
      description: z.string(),
      command: z.string(),
    })
  ),
  paths: z.object({
    config: z.string(),
    install_status: z.string(),
    worker_status: z.string(),
    logs: z.string(),
  }),
  agent_handoff: z.string(),
  agent_skill: z.string(),
});

/** A one-time install command; the server never returns it again. */
export const computeInstallCommandSchema = z.object({
  command: z.string(),
  expires_at: z.string().datetime(),
});
export type BftComputeInstallCommand = z.infer<typeof computeInstallCommandSchema>;

export const installCommandSchema = z.object({
  command: z.string(),
  expires_at: z.string(),
  runner_stable_id: nullableText,
});

/*
 * Settings (owner/admin). Secrets are write-only: responses carry
 * `*_configured` flags, and a blank secret in a write keeps the stored one.
 * Every write answers with the refreshed page or section.
 */
export const cliSchema = z.object({
  api_base_url: z.string(),
  install_command: z.string(),
  login_command: z.string(),
  sessions: z.array(
    z.object({
      id: z.string(),
      client_name: nullableText,
      device: nullableText,
      created_at: nullableText,
      last_seen_at: nullableText,
      expires_at: nullableText,
    })
  ),
  sessions_truncated: z.boolean().catch(false),
});

const optionSchema = z.object({ value: z.string(), label: z.string() });

export const settingsGeneralSchema = z.object({
  organization: z.object({
    name: z.string(),
    slug: z.string(),
    icon: nullableText,
    default_locale: nullableText,
  }),
  locale_options: z.array(optionSchema).catch([]),
  cli: cliSchema,
});

const platformDefaultSchema = z
  .object({ label: z.string(), model_icon: nullableText })
  .nullable()
  .catch(null);

/**
 * A Salix model choice: a catalog model, a runtime model or a platform tier.
 * The client sends it back as received; the server validates it.
 */
export const modelChoiceSchema = z.looseObject({ kind: z.string() });

/**
 * One model the organization can offer; `key` is stable selection state.
 * `served_by` says what serves it: a subscription (`plans` names which), a
 * pay-per-use Provider API key, the platform, or (null) none of the
 * organization's accounts. Pay-per-use is a choice of its own (`allow_paid`);
 * `key_sources` names the key sources that may serve it, and on a
 * subscription choice that it is also available pay-per-use.
 */
export const modelOptionSchema = z.object({
  key: z.string(),
  choice: modelChoiceSchema,
  label: z.string(),
  vendor: nullableText,
  served_by: z.enum(["subscription", "api_key", "platform"]).nullable().catch(null),
  plans: z.array(z.string()).catch([]),
  key_sources: z.array(z.string()).catch([]),
});

export const settingsModelsSchema = z.object({
  catalog_status: z.enum(["ok", "unavailable"]).catch("unavailable"),
  servable_status: z.enum(["ok", "unavailable"]).catch("unavailable"),
  catalog: z.array(modelOptionSchema),
  allowed_models: z.array(modelOptionSchema).catch([]),
  default_router_model: modelOptionSchema.nullable().catch(null),
  /** The model Tasks run in a swarm without its own default Task model. */
  default_task_model: modelOptionSchema.nullable().catch(null),
  default_options: z
    .object({ router: z.array(modelOptionSchema), task: z.array(modelOptionSchema) })
    .catch({ router: [], task: [] }),
  platform_defaults: z
    .object({ router: platformDefaultSchema, task: platformDefaultSchema })
    .catch({ router: null, task: null }),
});

export const subscriptionProviders = ["codex", "claude"] as const;

const accountSchema = z.object({
  id: z.string(),
  version: z.string(),
  credential_kind: z
    .enum(["subscription_oauth", "provider_api_key"])
    .catch("subscription_oauth"),
  provider: nullableText,
  name: nullableText,
  email: nullableText,
  status: z.string().catch("unknown"),
  disabled: z.boolean().catch(false),
  quota: z
    .object({
      plan_type: nullableText,
      observed_at: nullableText,
      windows: z
        .array(
          z.object({
            period: nullableText,
            remaining_percent: z.number().nullable().catch(null),
            reset_at: nullableText,
          })
        )
        .catch([]),
      reset_credits: z
        .object({ available_count: z.number().int().nullable().catch(null) })
        .nullable()
        .catch(null),
    })
    .nullable()
    .catch(null),
  // A pending attempt is retried with the same request id.
  reset_attempt: z
    .object({ request_id: z.string(), outcome: z.string() })
    .nullable()
    .catch(null),
  connection: z
    .object({ endpoint: z.string(), protocol: z.string(), auth_scheme: z.string() })
    .nullable()
    .catch(null),
  compatible_runtimes: z.array(z.string()).catch([]),
});

export const accountsPageSchema = z.object({
  accounts: z.array(accountSchema),
  next: z.string().nullable().catch(null),
});

export const resetResultSchema = z.object({
  outcome: z.string(),
  quota_refreshed: z.boolean().catch(false),
  account: accountSchema,
});

export const accountUsageSchema = z.object({
  bindings: z.array(
    z.object({
      project: z.object({ id: z.string(), name: z.string() }),
      workload_id: z.string(),
      href: nullableText,
    })
  ),
  hidden_count: z.number().int().catch(0),
  next: z.number().int().nullable().catch(null),
});

export const oauthAttemptSchema = z.object({
  id: z.string(),
  mode: z.enum(["device", "callback"]).catch("callback"),
  href: z.string(),
  user_code: nullableText,
  interval: z.number().int().catch(5),
});

export const oauthResultSchema = z.object({
  status: z.enum(["pending", "connected"]),
  interval: z.number().int().nullable().catch(null),
});

const cliOrgSchema = z.object({ id: z.string(), slug: z.string(), name: z.string() });

export const cliLoginStatuses = [
  "pending",
  "approved",
  "consumed",
  "cancelled",
  "expired",
] as const;

export const cliLoginSchema = z.object({
  request: z
    .object({
      user_code: z.string(),
      // An unknown status is treated as finished: nothing can be approved.
      status: z.enum(cliLoginStatuses).catch("cancelled"),
      client_name: nullableText,
      created_at: nullableText,
      expires_at: nullableText,
      granted_orgs: z.array(cliOrgSchema).catch([]),
    })
    .nullable(),
  orgs: z.array(cliOrgSchema),
});

export const wizardSteps = ["capabilities", "profile", "integrations"] as const;

/** The first-run onboarding wizard; it belongs to the user, not to an organization. */
export const wizardSchema = z.object({
  status: z.enum(["in_progress", "completed", "skipped"]).catch("in_progress"),
  /** The step a bare `/onboarding` resumes on. */
  step: z.enum(wizardSteps).catch("capabilities"),
  capability_groups: z.array(
    z.object({ key: z.string(), capabilities: z.array(z.string()) })
  ),
  capabilities: z.record(z.string(), z.boolean()),
  user: z.object({ name: nullableText, email: nullableText }),
  org: z
    .object({
      slug: z.string(),
      name: z.string(),
      role: z.enum(orgRoles).nullable().catch("member"),
    })
    .nullable(),
  teammates: z.object({
    total: z.number().int(),
    sample: z.array(
      z.object({
        name: nullableText,
        email: nullableText,
        role: z.enum(orgRoles).catch("member"),
      })
    ),
  }),
});

export const toolkitStates = [
  "connected",
  "connectable",
  "ask_admin",
  "unconfigured",
] as const;

export const wizardIntegrationsSchema = z.object({
  project: z.object({ id: z.string(), name: z.string() }).nullable(),
  can_connect: z.boolean(),
  org_admin: z.boolean(),
  composio: z.object({
    status: z.enum(["ok", "unavailable"]).catch("unavailable"),
    configured: z.boolean(),
  }),
  toolkits: z.array(
    z.object({
      toolkit: z.string(),
      state: z.enum(toolkitStates).catch("unconfigured"),
    })
  ),
  messaging: z.array(z.object({ provider: z.string(), connected: z.boolean() })),
  /** In the profile's vocabulary: Google's toolkits all count as `google`. */
  connected_providers: z.array(z.string()),
});

export const wizardFinishSchema = z.object({
  redirect: z.string(),
  notice: nullableText,
});

export const ssoProviders = ["generic_oidc", "feishu", "lark"] as const;
export const ssoRoles = ["member", "admin"] as const;
export const provisioningPolicies = ["jit", "existing_identity"] as const;

export const settingsSsoSchema = z.object({
  connection: z
    .object({
      provider: z.enum(ssoProviders).catch("generic_oidc"),
      issuer: nullableText,
      client_id: nullableText,
      client_secret_configured: z.boolean().catch(false),
      allowed_domains: z.array(z.string()).catch([]),
      // Least privilege when the server adds a role this client does not know.
      default_role: z.enum(ssoRoles).catch("member"),
      provider_config: z
        .object({
          scope: nullableText,
          provisioning_policy: z.enum(provisioningPolicies).catch("jit"),
        })
        .catch({ scope: null, provisioning_policy: "jit" }),
    })
    .nullable(),
  feishu_app: z
    .object({
      app_id: z.string(),
      display_name: nullableText,
      app_secret_configured: z.boolean().catch(false),
    })
    .nullable(),
  redirect_uri: z.string(),
  default_feishu_scope: z.string().catch("contact:user.base:readonly"),
});

export const ssoChecksSchema = z.object({
  checks: z.object({
    gates: z.array(
      z.object({
        gate_id: z.string(),
        label: z.string(),
        status: z.string(),
        next_action: nullableText,
      })
    ),
  }),
  recorded: z.boolean().catch(false),
  warning: nullableText,
});

const sectionStatus = z.enum(["ok", "unavailable"]).catch("unavailable");

export const oauthSectionSchema = z.object({
  status: sectionStatus,
  apps: z.array(
    z.object({
      provider: z.string(),
      label: z.string(),
      client_id: nullableText,
      client_secret_configured: z.boolean().catch(false),
      source: nullableText,
      configured: z.boolean().catch(false),
      setup_href: nullableText,
      /** What the provider's app form asks for: X sends all three, Lark only the redirect URL. */
      setup_config: z
        .object({
          app_name: nullableText.optional().transform((value) => value ?? null),
          callback_url: z.string(),
          website_url: nullableText.optional().transform((value) => value ?? null),
        })
        .nullable()
        .optional(),
    })
  ),
  waiting_members: z
    .object({ names: z.array(z.string()), truncated: z.boolean().catch(false) })
    .catch({ names: [], truncated: false }),
});

export const composioSectionSchema = z.object({
  status: sectionStatus,
  enabled: z.boolean().catch(false),
  api_key_configured: z.boolean().catch(false),
  base_url: nullableText,
  source: nullableText,
});

export const signalSectionSchema = z.object({
  status: sectionStatus,
  override_e164: nullableText,
  platform_e164: nullableText,
  effective_e164: nullableText,
});

export const feishuSectionSchema = z.object({
  apps: z.array(
    z.object({
      id: z.string(),
      app_id: z.string(),
      display_name: nullableText,
      sso_enabled: z.boolean().catch(false),
      bot_enabled: z.boolean().catch(false),
      app_secret_configured: z.boolean().catch(false),
      verification_token_configured: z.boolean().catch(false),
      encrypt_key_configured: z.boolean().catch(false),
      routes: z
        .array(
          z.object({
            project_id: z.string(),
            project_name: nullableText,
            connect_id: z.string(),
            disabled: z.boolean().catch(false),
            href: z.string(),
          })
        )
        .catch([]),
    })
  ),
  apps_truncated: z.boolean().catch(false),
  // `skipped` when no app has the bot enabled; `unavailable` when Salix could
  // not be asked, which is not the same as "no routes".
  routes_status: z.enum(["ok", "unavailable", "skipped"]).catch("unavailable"),
  /** How many Agent Swarms the routes were read for; `projects_truncated` when more exist. */
  projects_shown: z.number().int().nonnegative().catch(0),
  projects_truncated: z.boolean().catch(false),
  redirect_uri: z.string(),
  scope_cards: z
    .array(
      z.object({
        id: z.string(),
        title: z.string(),
        description: nullableText,
        json: z.string(),
      })
    )
    .catch([]),
  optional_scopes: z
    .array(z.object({ scope: z.string(), label: nullableText, note: nullableText }))
    .catch([]),
});

export const settingsIntegrationsSchema = z.object({
  oauth: oauthSectionSchema,
  composio: composioSectionSchema,
  signal: signalSectionSchema,
  feishu: feishuSectionSchema,
});

/** One Agent Swarm row; a create answers with the new row. */
export const swarmSchema = z.object({
  id: z.string(),
  name: z.string(),
  slug: nullableText,
  salix_group_id: nullableText,
  status: z.string().catch("active"),
  created_at: nullableText,
});

/** One page of 50 visible Agent Swarms by name; `cursor` continues it. */
export const swarmsPageSchema = z.object({
  viewer: z.object({ can_create: z.boolean().catch(false) }),
  projects: z.array(swarmSchema),
  next_cursor: nullableText,
});

const swarmStatusSchema = z.enum(["ok", "unavailable"]).catch("unavailable");

/** The swarm a sub-page belongs to, and the caller's role in it. */
const swarmPageProjectSchema = z.object({
  id: z.string(),
  name: z.string(),
  // Least privilege when the server adds a role this client does not know.
  role: z.enum(["admin", "user"]).catch("user"),
});

const agentSummarySchema = z.object({
  id: z.string(),
  name: z.string().nullable(),
  role: z.string(),
  lifecycle: z.string(),
});

/**
 * The swarm's agents: its Router. Workers are retired; Tasks run on the
 * swarm's Task agent at the default place and model of swarm Settings.
 */
export const swarmAgentsSchema = z.object({
  project: swarmPageProjectSchema,
  status: swarmStatusSchema,
  agents: z.array(agentSummarySchema),
});

/**
 * One agent: its list facts, model and prompt, and a Router's canonical
 * session. A Worker made before Workers were retired is `read_only` history.
 */
export const swarmAgentSchema = z.object({
  project: swarmPageProjectSchema,
  agent: agentSummarySchema.extend({
    created_at: nullableText,
    runtime_id: nullableText,
    model: nullableText,
    system_prompt: nullableText,
    // Least privilege when the server leaves it out.
    read_only: z.boolean().catch(true),
  }),
  router_session: z
    .object({ status: swarmStatusSchema, id: nullableText })
    .nullable()
    .catch(null),
});

/** A write that changed the agent answers it again with a localized notice. */
export const swarmAgentWriteSchema = swarmAgentSchema.extend({ notice: z.string() });

/** One entry of a model picker; the label and group arrive localized. */
export const modelPickerRowSchema = z.object({
  key: z.string(),
  choice: modelChoiceSchema.nullable().catch(null),
  label: z.string(),
  disabled: z.boolean().catch(false),
  group: z.string(),
});

/** The Configure form; labels and groups arrive localized. */
export const agentConfigSchema = z.object({
  agent: z.object({ id: z.string(), name: z.string().nullable(), role: z.string() }),
  model_key: z.string().catch(""),
  system_prompt: z.string().catch(""),
  // Only an org owner changes the Router's instructions; others see them.
  prompt_editable: z.boolean().catch(false),
  available: z.boolean().catch(false),
  // The first entry, key "" and choice `null`, follows the default model.
  models: z.array(modelPickerRowSchema).catch([]),
});

/** The models a place lists per runtime; none listed leaves only its default. */
/** The coding agents a station runs a Task with. */
export const stationRuntimes = ["codex", "claude"] as const;
export type BftStationRuntime = (typeof stationRuntimes)[number];

const stationModelsSchema = z
  .object({
    codex: z.array(z.string()).catch([]),
    claude: z.array(z.string()).catch([]),
  })
  .partial()
  .catch({});

/**
 * The stations of this swarm's devices and the swarm's Cloud VM, for the
 * target picker. `issue` arrives localized and says why a place is not
 * selectable (an old connector or station, the Cloud VM turned off).
 */
export const agentTargetsSchema = z.object({
  stations: z.array(
    z.object({
      id: z.string(),
      label: z.string(),
      connected: z.boolean().catch(false),
      selectable: z.boolean().catch(false),
      issue: nullableText,
      models: stationModelsSchema,
    })
  ),
  cloud_vm: z
    .object({
      selectable: z.boolean().catch(false),
      issue: nullableText,
      models: stationModelsSchema,
    })
    .catch({ selectable: false, issue: null, models: {} }),
});

export const switchedSessionSchema = z.object({
  router_session_id: z.string(),
  notice: z.string(),
});

const countSchema = z.number().int().nonnegative().nullable().catch(null);

/** Android facts a device reports; phases and states are codes the page names. */
const androidDeviceSchema = z.object({
  profiles: z.array(z.string()).catch([]),
  default_profile: nullableText,
  active_profile: nullableText,
  target_profile: nullableText,
  phase: nullableText,
  state: nullableText,
  available_slots: countSchema,
  capacity: countSchema,
});

/**
 * Where a Cloud VM runs: on Cloudflare, or on an org Runner (`name` is null
 * when the Runner is not one of the org's). `conflict`: the swarm has more
 * than one Runner, so no new VM can be placed.
 */
const cloudVmLocationSchema = z.discriminatedUnion("kind", [
  z.object({ kind: z.literal("cloudflare") }),
  z.object({ kind: z.literal("runner"), name: nullableText }),
  z.object({ kind: z.literal("conflict") }),
]);

export const androidSetups = ["connected", "needs_attention", "not_connected"] as const;

/**
 * The Devices page: the swarm's Cloud VM, up to 100 devices from the device
 * projection, Android setup and one Compute page.
 *
 * `cloud_vm.vm` is null until the VM exists; then it says where the VM runs
 * and its status. `runner` prepares the separate VMM Station.
 * `next_location` is Cloudflare for a new Cloud VM.
 */
export const swarmDevicesSchema = z.object({
  project: swarmPageProjectSchema,
  cloud_vm: z.object({
    enabled: z.boolean().catch(false),
    manageable: z.boolean().catch(false),
    vm: z
      .object({
        status: z.string().catch("unknown"),
        location: cloudVmLocationSchema.nullable().catch(null),
      })
      .nullable()
      .catch(null),
    runner: z
      .object({ name: nullableText, status: z.string().catch("processing") })
      .nullable()
      .catch(null),
    next_location: cloudVmLocationSchema.nullable().catch(null),
    runner_choosable: z.boolean().catch(false),
    runner_removable: z.boolean().catch(false),
  }),
  devices: z.array(
    z.object({
      id: z.string(),
      name: nullableText,
      status: z.string().catch("unknown"),
      disconnectable: z.boolean().catch(false),
      runtimes: z
        .array(
          z.object({ id: z.string(), provider: z.string(), version: nullableText })
        )
        .catch([]),
      host: nullableText,
      os: nullableText,
      cpu_model: nullableText,
      cpu_count: countSchema,
      memory_bytes: countSchema,
      last_seen_at: nullableText,
      info_updated_at: nullableText,
      android: androidDeviceSchema.nullable().catch(null),
      /**
       * Why the device cannot take tasks (`device_needs_station`: the old
       * connector; `station_outdated`: a station older than `required_tasks`),
       * with the localized `message` saying how to upgrade it. Null when it can.
       */
      station_notice: z
        .object({
          reason: z.string(),
          tasks: z.number().int().nullable().catch(null),
          required_tasks: z.number().int().catch(2),
          message: z.string(),
        })
        .nullable()
        .catch(null),
    })
  ),
  provisioning: z.boolean().catch(false),
  android: z.object({
    status: swarmStatusSchema,
    entitled: z.boolean().catch(false),
    profiles: z.array(z.string()).catch([]),
    setup: z.enum(androidSetups).catch("not_connected"),
    registered: z.boolean().catch(false),
  }),
  compute: z.object({
    status: swarmStatusSchema,
    environments: z.array(
      z.object({
        id: z.string(),
        desired_state: z.string(),
        observed_state: nullableText,
        revision: z.number().int(),
      })
    ),
    workloads: z.array(
      z.object({ id: z.string(), kind: z.string(), observed_state: nullableText })
    ),
  }),
});

export const deviceProvisioningSchema = z.object({ active: z.boolean().catch(false) });

/** Online runners a device can be created on. */
export const deviceRunnersSchema = z.object({
  runners: z.array(z.object({ id: z.string(), label: z.string() })),
  runners_href: z.string(),
});

export const noticeSchema = z.object({ notice: z.string() });

export const cloudComputerSchema = z.object({
  enabled: z.boolean(),
  notice: z.string(),
});

/** One page of 100 tasks, most recently updated first; `next_cursor` continues it. */
export const swarmTasksSchema = z.object({
  project: swarmPageProjectSchema,
  status: swarmStatusSchema,
  tasks: z.array(
    z.object({
      id: z.string(),
      title: nullableText,
      status: z.string().catch("active"),
      kind: nullableText,
      scheduled: z.boolean().catch(false),
      updated_at: nullableText,
      href: z.string(),
    })
  ),
  next_cursor: nullableText,
});

export const createdTaskSchema = z.object({ id: z.string(), href: z.string() });

/**
 * Where a new Task can run and the models it can choose. `places`: inside
 * Salix, the swarm's Cloud VM while it is on, and each connected station that
 * takes Tasks, with the models each runs per coding agent; `default` marks the
 * swarm's default place. `models`: a Task inside Salix chooses among them;
 * the first, key "" and choice `null`, is the swarm's default Task model.
 * Labels arrive localized.
 */
export const taskTargetsSchema = z.object({
  places: z.array(
    z.object({
      id: z.string(),
      kind: z.enum(["salix", "cloud_vm", "station"]),
      device_id: nullableText.optional(),
      label: z.string(),
      default: z.boolean().catch(false),
      models: stationModelsSchema,
    })
  ),
  models: z
    .array(
      z.object({
        key: z.string(),
        choice: modelChoiceSchema.nullable().catch(null),
        label: z.string(),
      })
    )
    .catch([]),
});

/*
 * Task detail. The header and schedule come with the page and again with
 * each write and poll; messages carry server-sanitized HTML for their text.
 */
export const taskHeaderSchema = z.object({
  id: z.string(),
  title: nullableText,
  status: z.string().catch("active"),
  kind: nullableText,
  scheduled: z.boolean().catch(false),
  schedulable: z.boolean().catch(false),
  /** Set while the task waits for review: accepting names this version. */
  review_version: z.number().int().nullable().catch(null),
  terminal: z.boolean().catch(false),
  updated_at: nullableText,
});

export const taskScheduleIntervalUnits = ["minutes", "hours", "days"] as const;

export const taskScheduleFormSchema = z.object({
  mode: z.enum(["cron", "interval"]).catch("cron"),
  interval_value: z.string().catch("1"),
  interval_unit: z.enum(taskScheduleIntervalUnits).catch("days"),
  cron: z.string().catch(""),
  timezone: z.string().catch("UTC"),
  command: z.string().catch(""),
});

export const taskScheduleSchema = z.object({
  /** `none`: no schedule; `missing` or `unavailable`: its definition could not be read. */
  status: z.enum(["none", "ok", "missing", "unavailable"]).catch("unavailable"),
  recurrence: nullableText,
  command: nullableText,
  form: taskScheduleFormSchema,
});

export const taskMessageBlockSchema = z.discriminatedUnion("type", [
  z.object({ type: z.literal("text"), html: z.string() }),
  z.object({
    type: z.literal("attachment"),
    kind: z.enum(["image", "file"]).catch("file"),
    name: z.string(),
    path: nullableText,
    mime: nullableText,
    href: nullableText,
  }),
]);

export const taskMessageSchema = z.object({
  id: z.string(),
  seq: z.number().int().nullable().catch(null),
  author: z.string(),
  from_person: z.boolean().catch(false),
  created_at: nullableText,
  // A block this client does not know is left out, not the whole message.
  blocks: z.array(z.unknown()).transform((blocks) =>
    blocks.flatMap((block) => {
      const parsed = taskMessageBlockSchema.safeParse(block);
      return parsed.success ? [parsed.data] : [];
    })
  ),
});

export const swarmTaskSchema = z.object({
  project: swarmPageProjectSchema,
  task: taskHeaderSchema,
  schedule: taskScheduleSchema,
  participants: z.array(
    z.object({
      id: z.string(),
      label: z.string(),
      role_label: nullableText,
      agent_href: nullableText,
      thread_url: nullableText,
    })
  ),
  /** The latest 50 messages, oldest first. */
  messages: z.array(taskMessageSchema),
  has_older: z.boolean().catch(false),
});

/** A page of messages: newer than `after`, or older than `before`. */
export const taskMessagesSchema = z.object({
  task: taskHeaderSchema,
  messages: z.array(taskMessageSchema),
  has_more: z.boolean().catch(false),
});

export const taskScheduleReplySchema = z.object({
  task: taskHeaderSchema,
  schedule: taskScheduleSchema,
});

export const taskReviewReplySchema = z.object({ task: taskHeaderSchema });

export const sentTaskMessageSchema = z.object({ message_id: nullableText });

export const schedulePreviewSchema = z.object({ recurrence: nullableText });

/** The swarm's recurring schedules (at most 200); the recurrence is localized. */
export const swarmSchedulesSchema = z.object({
  project: swarmPageProjectSchema,
  status: swarmStatusSchema,
  schedules: z.array(
    z.object({
      id: z.string(),
      target: z.enum(["agent", "task"]).catch("agent"),
      agent_name: nullableText,
      prompt: nullableText,
      recurrence: z.string(),
      last_run_at: nullableText,
      href: z.string(),
    })
  ),
  truncated: z.boolean().catch(false),
});

/** Up to 50 websites the swarm's agents publish; `total` counts them all. */
export const swarmWebsitesSchema = z.object({
  status: swarmStatusSchema,
  items: z.array(
    z.object({
      name: z.string(),
      url: nullableText,
      agent_name: nullableText,
      agent_href: z.string(),
    })
  ),
  total: z.number().int(),
});

export const swarmAccessRoles = ["admin", "user"] as const;

/** One page of 100 explicit access grants; `next_cursor` continues it. */
export const swarmAccessPageSchema = z.object({
  members: z.array(
    z.object({
      id: z.string(),
      name: nullableText,
      email: nullableText,
      role: z.enum(swarmAccessRoles).catch("user"),
      granted_at: nullableText,
    })
  ),
  truncated: z.boolean().catch(false),
  next_cursor: nullableText,
});

/**
 * The model a Task of the swarm runs when the Router names none. Key "" (the
 * first row, choice `null`) means none is set: each Task runs the org default
 * Task model. `models` also lists the platform model and the organization's offered
 * models.
 */
export const swarmTaskModelSchema = z.object({
  status: z.enum(["ok", "unavailable"]).catch("unavailable"),
  key: z.string().catch(""),
  label: nullableText,
  models: z.array(modelPickerRowSchema).catch([]),
});

/** Where a Task of the swarm runs when the Router names no place. */
export const swarmTaskPlaceSchema = z.discriminatedUnion("kind", [
  z.object({ kind: z.literal("salix") }),
  z.object({ kind: z.literal("cloud_vm") }),
  z.object({ kind: z.literal("station"), device_id: z.string() }),
]);

/**
 * The swarm's default place to run Tasks and its name: Salix (also when none
 * is set), the Cloud VM or a station.
 */
export const swarmTaskPlaceSettingSchema = z.object({
  status: z.enum(["ok", "unavailable"]).catch("unavailable"),
  place: swarmTaskPlaceSchema.nullable().catch(null),
  label: nullableText,
});

/**
 * Identity, runtime ids, the default Task model, the default place to run
 * Tasks and the first page of explicit access grants.
 */
export const swarmSettingsSchema = z.object({
  project: swarmPageProjectSchema.extend({
    slug: nullableText,
    status: z.string().catch("active"),
    runtime_id: nullableText,
  }),
  org_runtime_id: nullableText,
  task_model: swarmTaskModelSchema.catch({
    status: "unavailable",
    key: "",
    label: null,
    models: [],
  }),
  task_place: swarmTaskPlaceSettingSchema.catch({
    status: "unavailable",
    place: null,
    label: null,
  }),
  access: swarmAccessPageSchema,
});

/** Where to go after archiving, and the notice to show there. */
export const archivedSwarmSchema = z.object({
  redirect: z.string(),
  notice: z.string(),
});

/**
 * An access write answers the Settings page with the caller's role read again,
 * or, when the caller removed their own access, where to go instead.
 */
export const swarmAccessWriteSchema = z.union([
  swarmSettingsSchema,
  archivedSwarmSchema,
]);

export const pluginRefKeys = [
  "tool_refs",
  "skill_refs",
  "mcp_refs",
  "oauth_requirements",
  "im_connect_requirements",
] as const;

/** A capability reference: an id, or a JSON object for structured ones. */
const pluginRefSchema = z.union([z.string(), z.record(z.string(), z.unknown())]);
const pluginRefList = z.array(pluginRefSchema).catch([]);

export const emptyPluginRefs = () => ({
  tool_refs: [],
  skill_refs: [],
  mcp_refs: [],
  oauth_requirements: [],
  im_connect_requirements: [],
});

export const pluginSchema = z.object({
  plugin_id: z.string(),
  name: nullableText,
  description: nullableText,
  owner_scope: z.enum(["tenant", "system"]).catch("system"),
  editable: z.boolean().catch(false),
  refs: z
    .object({
      tool_refs: pluginRefList,
      skill_refs: pluginRefList,
      mcp_refs: pluginRefList,
      oauth_requirements: pluginRefList,
      im_connect_requirements: pluginRefList,
    })
    .catch(() => emptyPluginRefs()),
  setup_destination: nullableText,
  setup_targets: z.array(z.string()).catch([]),
});

export const pluginsSchema = z.object({
  viewer: z.object({ can_manage: z.boolean().catch(false) }),
  plugins: z.array(pluginSchema),
});

export const pluginScopes = ["system", "tenant", "group"] as const;

/** One credential of a plugin: managed OAuth, native MCP OAuth, Composio or messaging. */
const pluginConnectionSchema = z.object({
  id: z.string(),
  kind: z.string(),
  label: z.string(),
  state: nullableText,
  dependent_mcps: z.array(z.string()).catch([]),
  credential_setup: z
    .object({
      key: z.string(),
      label: z.string(),
      help_url: z
        .string()
        .url()
        .refine((url) => url.startsWith("https://")),
    })
    .nullable()
    .optional(),
  /** What its button does; null for a messaging credential set up elsewhere. */
  action: z.enum(["connect", "reconnect"]).nullable().catch(null),
  disconnectable: z.boolean().catch(false),
  /** The swarm's Connections page at its messaging section, for a messaging credential. */
  integrations_href: nullableText,
});

const swarmPluginSchema = z.object({
  plugin_id: z.string(),
  name: nullableText,
  description: nullableText,
  owner_scope: z.enum(pluginScopes).catch("system"),
  enabled: z.boolean().catch(false),
  locked: z.boolean().catch(false),
  toggleable: z.boolean().catch(false),
  editable: z.boolean().catch(false),
  /** MCP servers and messaging connections that still need setup. */
  attention: z.array(z.string()).catch([]),
  refs: pluginSchema.shape.refs,
  setup_destination: nullableText,
});

const pluginAndroidSchema = z
  .object({ status: swarmStatusSchema, entitled: z.boolean().catch(false) })
  .nullable()
  .catch(null);

/** An Agent Swarm's product plugins, by name, from one Salix read. */
export const swarmPluginsSchema = z.object({
  project: swarmPageProjectSchema,
  plugins: z.array(swarmPluginSchema),
  android: pluginAndroidSchema,
});

/** One plugin with its MCP servers and connections; `plugin` is null when the swarm cannot see it. */
export const swarmPluginDetailSchema = z.object({
  project: swarmPageProjectSchema,
  plugin: swarmPluginSchema
    .extend({
      setup: z
        .object({
          mcps: z.array(
            z.object({
              alias: z.string(),
              placement: nullableText,
              state: nullableText,
              connections: z.array(pluginConnectionSchema),
            })
          ),
          connections: z.array(pluginConnectionSchema),
        })
        .nullable()
        .catch(null),
    })
    .nullable(),
  android: pluginAndroidSchema,
});

/** A started connection opens the provider; one already connected says so. */
export const connectionStartSchema = z.union([
  z.object({ redirect_url: z.string() }),
  noticeSchema,
]);

/** One readable section of the Connections page; each degrades on its own. */
const sectionStateSchema = z
  .enum(["ok", "preparing", "unavailable"])
  .catch("unavailable");

const slackManifestViewSchema = z
  .object({
    json: z.string(),
    create_url: nullableText,
    redirect_url: nullableText,
    events_url: nullableText,
    interactions_url: nullableText,
  })
  .nullable()
  .catch(null);

export const feishuRouteStatuses = [
  "ready",
  "disabled",
  "missing_router",
  "not_connected",
  "unknown",
] as const;

/**
 * An Agent Swarm's Connections page: its messaging channels (Feishu, Slack,
 * Signal) and the third-party accounts its agents use (managed OAuth and
 * Composio toolkits).
 */
const tailnetSettingsSchema = z.object({
  tags: z.array(z.string()).catch([]),
  accept_routes: z.boolean().catch(false),
  expected_tailnet: nullableText,
});

const tailnetUnavailable = {
  status: "unavailable" as const,
  enabled: false,
  state: "disabled",
  approved: false,
  login_url: null,
  tailnet: null,
  node_name: null,
  login_name: null,
  node_tags: [],
  addresses: [],
  key_expiry: null,
  error: null,
  settings: { tags: [], accept_routes: false, expected_tailnet: null },
};

/**
 * The swarm's node in the organization's Tailscale network. `login_url` is
 * present only for swarm admins while the node waits for a tailnet admin.
 */
export const tailnetSectionSchema = z
  .object({
    status: sectionStateSchema,
    enabled: z.boolean().catch(false),
    state: z.string().catch("disabled"),
    approved: z.boolean().catch(false),
    login_url: nullableText,
    tailnet: nullableText,
    node_name: nullableText,
    login_name: nullableText,
    node_tags: z.array(z.string()).catch([]),
    addresses: z.array(z.string()).catch([]),
    key_expiry: nullableText,
    error: z
      .object({ code: nullableText, message: nullableText })
      .nullable()
      .catch(null),
    settings: tailnetSettingsSchema.catch(tailnetUnavailable.settings),
  })
  .catch(tailnetUnavailable);

export const tailnetWriteSchema = z.object({
  tailnet: tailnetSectionSchema,
  notice: nullableText,
});

export const qqMenuScopes = ["all", "private", "group"] as const;

/** One shortcut of a QQ bot's command menu. */
const qqMenuItemSchema = z.object({
  name: z.string(),
  description: z.string().catch(""),
  /** What the agent is asked when a person picks the item; empty sends the name. */
  prompt: z.string().catch(""),
  scope: z.enum(qqMenuScopes).catch("all"),
  admin_only: z.boolean().catch(false),
});

export const swarmConnectionsSchema = z.object({
  project: swarmPageProjectSchema,
  /** Owner or admin of the organization: may open its settings. */
  org_admin: z.boolean().catch(false),
  messaging: z.object({
    status: sectionStateSchema,
    feishu: z
      .object({
        apps: z.array(z.object({ app_id: z.string(), name: z.string() })).catch([]),
        connects: z.array(
          z.object({
            connect_id: z.string(),
            status: z.string().catch("configured"),
            disabled: z.boolean().catch(false),
            app_id: nullableText,
            webhook_url: nullableText,
            app_secret_configured: z.boolean().catch(false),
            verification_token_configured: z.boolean().catch(false),
            encrypt_key_configured: z.boolean().catch(false),
            updated_at: nullableText,
          })
        ),
        route: z.object({
          status: z.enum(feishuRouteStatuses).catch("unknown"),
          connect_id: nullableText,
          router: nullableText,
        }),
      })
      .nullable(),
    slack: z
      .object({
        app_name: z.string(),
        manifest: slackManifestViewSchema,
        /** The Router a connection can deliver to. */
        inbound_agents: z
          .array(z.object({ id: z.string(), label: z.string() }))
          .catch([]),
        default_inbound_agent_id: nullableText,
        /**
         * The models a connection that makes each new thread a Task can run;
         * the first row (key "", choice `null`) is the swarm's default Task model.
         */
        task_models: z
          .array(
            z.object({
              key: z.string(),
              choice: modelChoiceSchema.nullable().catch(null),
              label: z.string(),
            })
          )
          .catch([]),
        connects: z.array(
          z.object({
            connect_id: z.string(),
            installed: z.boolean().catch(false),
            disabled: z.boolean().catch(false),
            workspace: nullableText,
            inbound_agent: nullableText,
            install_url: nullableText,
            client_secret_configured: z.boolean().catch(false),
            signing_secret_configured: z.boolean().catch(false),
            updated_at: nullableText,
          })
        ),
      })
      .nullable(),
    /**
     * The swarm's Lark apps (open.larksuite.com); each connect holds its own
     * app credentials. Feishu apps are the organization's, above.
     */
    lark: z
      .object({
        connects: z.array(
          z.object({
            connect_id: z.string(),
            status: z.string().catch("configured"),
            disabled: z.boolean().catch(false),
            app_id: nullableText,
            app_name: nullableText,
            /** The request URL to save in the Lark Developer Console. */
            webhook_url: nullableText,
            app_secret_configured: z.boolean().catch(false),
            verification_token_configured: z.boolean().catch(false),
            encrypt_key_configured: z.boolean().catch(false),
            updated_at: nullableText,
          })
        ),
        route: z.object({
          status: z.enum(feishuRouteStatuses).catch("unknown"),
          connect_id: nullableText,
          router: nullableText,
        }),
        /** The scopes a Lark app needs, as the JSON of the console's batch import. */
        scope_json: nullableText,
      })
      .nullable()
      .catch(null),
    /** The swarm's QQ bots; each connect holds its own bot credentials. */
    qq: z
      .object({
        connects: z.array(
          z.object({
            connect_id: z.string(),
            status: z.string().catch("configured"),
            disabled: z.boolean().catch(false),
            app_id: nullableText,
            bot_name: nullableText,
            webhook_url: nullableText,
            app_secret_configured: z.boolean().catch(false),
            /** The shortcuts of the bot's command menu, after its fixed commands. */
            command_menu: z.array(qqMenuItemSchema).catch([]),
            /** Whether QQ took the menu: `synced`, `owner_panel` or `failed`, by chat type. */
            command_menu_sync: z.record(z.string(), z.string()).catch({}),
            updated_at: nullableText,
          })
        ),
        route: z.object({
          status: z.enum(feishuRouteStatuses).catch("unknown"),
          connect_id: nullableText,
          router: nullableText,
        }),
      })
      .nullable()
      .catch(null),
  }),
  signal: z.object({
    status: sectionStateSchema,
    number: nullableText,
    bindings: z
      .array(
        z.object({
          binding_id: z.string(),
          display_name: nullableText,
          kind: z.enum(["person", "group"]).catch("person"),
          number: nullableText,
        })
      )
      .catch([]),
    bindings_truncated: z.boolean().catch(false),
  }),
  accounts: z.object({
    status: sectionStateSchema,
    connections: z.array(
      z.object({
        binding_id: z.string(),
        provider: z.string(),
        alias: nullableText,
        account: nullableText,
        scopes: z.array(z.string()).catch([]),
        status: z.string().catch("active"),
        enabled: z.boolean().catch(true),
      })
    ),
    providers: z.array(
      z.object({ provider: z.string(), ready: z.boolean().catch(false) })
    ),
  }),
  composio: z.object({
    status: sectionStateSchema,
    configured: z.boolean().catch(false),
    toolkits: z.array(z.object({ toolkit: z.string(), account_id: nullableText })),
  }),
  tailnet: tailnetSectionSchema,
});

export const slackManifestSchema = z.object({ manifest: slackManifestViewSchema });

/** A Run checks result; it is recorded for the Health page's Delivery signal. */
export const runChecksSchema = z.object({
  checks: z.object({
    ran_at: nullableText,
    gates: z.array(
      z.object({
        gate_id: z.string(),
        label: z.string(),
        status: z.string(),
        reason_class: nullableText,
        next_action: nullableText,
        required: z.boolean().catch(true),
        evidence: z.record(z.string(), z.unknown()).catch({}),
      })
    ),
  }),
  recorded: z.boolean().catch(false),
  warning: nullableText,
});

/** A one-time Signal code; it is shown only in this answer. */
export const signalClaimSchema = z.object({
  claim: z.object({ number: z.string(), command: z.string() }),
});

const swarmSkillSchema = z.object({
  id: z.string(),
  location: z.string(),
  name: z.string(),
  description: nullableText,
  source: nullableText,
  activation: z.string().catch("regular"),
  deletable: z.boolean().catch(false),
  delete_reason: nullableText,
});

/** One skill with its `SKILL.md`, read when the viewer opens it. */
export const swarmSkillDetailSchema = z.object({
  skill: swarmSkillSchema.extend({ content: z.string().catch("") }),
});

/**
 * The skills of an Agent Swarm's Router (or first agent): its custom skills
 * and the read-only system skills projected into it, and the upload limits.
 */
export const swarmSkillsSchema = z.object({
  project: swarmPageProjectSchema,
  status: swarmStatusSchema,
  agent: z.object({ id: z.string(), name: z.string() }).nullable().catch(null),
  custom: z.array(swarmSkillSchema),
  system: z.array(swarmSkillSchema),
  miniskill_status: nullableText,
  agents_href: z.string(),
  limits: z.object({
    max_bytes: z.number().int().positive(),
    extensions: z.array(z.string()),
  }),
});

const nullableNumber = z.number().nullable().catch(null);
const nullableBoolean = z.boolean().nullable().catch(null);
const calendarRef = { account_id: z.string(), calendar_id: z.string() };

export const meetingStatuses = [
  "updating",
  "failed",
  "queued",
  "not_sent",
  "ready",
  "timed_out",
  "preparing",
  "scheduled",
] as const;

/** One Agent Swarm's preparation settings, Slack bots and next 24 hours (at most 20). */
export const meetingsOverviewSchema = z.object({
  settings: z.object({
    enabled: z.boolean().catch(false),
    mode: nullableText,
    connect_id: nullableText,
    channel: nullableText,
    channel_id: nullableText,
    calendar_selections: z
      .array(z.object({ ...calendarRef, name: nullableText }))
      .catch([]),
    preparation_lead_minutes: nullableNumber,
    research_enabled: nullableBoolean,
    calendar_writeback: nullableBoolean,
    personal_preparation: nullableBoolean,
    channel_notice: nullableBoolean,
    series: z
      .array(z.object({ ...calendarRef, event_id: z.string(), title: nullableText }))
      .catch([]),
  }),
  connects: z.array(
    z.object({
      connect_id: z.string(),
      app_name: nullableText,
      bot_username: nullableText,
      workspace_name: nullableText,
      state: z.enum(["connected", "unconnected", "unavailable"]).catch("unavailable"),
      preparation: z
        .enum(["enabled", "paused", "not_configured"])
        .catch("not_configured"),
      // `null`: Slack has not said which permissions the bot holds.
      missing_scopes: z.array(z.string()).nullable().catch(null),
    })
  ),
  events: z.array(
    z.object({
      meeting_plan_id: z.string(),
      title: nullableText,
      start_ms: nullableNumber,
      status: z.enum(meetingStatuses).catch("scheduled"),
    })
  ),
  calendar_health: nullableText,
  truncated: z.boolean().catch(false),
  runtime_enabled: z.boolean().catch(false),
});

/** One cursor page of past meetings shared in the team channel. */
export const meetingHistorySchema = z.object({
  channel: nullableText,
  meetings: z.array(
    z.object({
      meeting_id: z.string(),
      title: nullableText,
      status: nullableText,
      start_ms: nullableNumber,
      recording_url: nullableText,
      recording_status: nullableText,
      canvas_url: nullableText,
      thread_url: nullableText,
    })
  ),
  next_cursor: nullableText,
});

const channelPage = {
  channels: z.array(z.object({ id: z.string(), name: z.string() })).catch([]),
  next_cursor: nullableText,
};

export const meetingCatalogSchema = z.object({
  calendars: z.array(
    z.object({ ...calendarRef, name: nullableText, account_name: nullableText })
  ),
  ...channelPage,
});

export const meetingChannelsSchema = z.object(channelPage);

export const meetingSeriesSchema = z.object({
  meetings: z.array(
    z.object({ ...calendarRef, event_id: z.string(), title: nullableText })
  ),
  next_cursor: nullableText,
});

export const meetingDetailSchema = z.object({ report: nullableText });

// One unreadable day does not cost the rest of the calendar.
const calendarSchema = z
  .array(z.unknown())
  .catch([])
  .transform((days) => days.filter((day): day is string => typeof day === "string"));

const dailyBriefSettingsShape = {
  project_id: z.string(),
  slack_connect_id: z.string(),
  enabled: z.boolean().catch(false),
  retention_days: z.number().catch(90),
  team_names: z.enum(["hidden", "shown"]).catch("hidden"),
  off_days: calendarSchema,
  work_days: calendarSchema,
  team_channel_id: z.string().nullable().catch(null),
  team_post_at: z.string().catch("10:20:00"),
};

/** The organization's daily brief: settings, linked members, today and the latest runs. */
export const dailyBriefSchema = z.object({
  settings: z.object(dailyBriefSettingsShape).nullable(),
  members: z.array(
    z.object({
      id: z.string(),
      email: nullableText,
      name: nullableText,
      slack_user_id: nullableText,
      enabled: z.boolean().catch(true),
      timezone: nullableText,
      deliver_at: nullableText,
      last_brief_at: nullableText,
      requested_at: nullableText,
    })
  ),
  /** The last team brief, member briefs of the past 24 hours, and the next brief time. */
  today: z
    .object({
      team_pass: z
        .object({ status: z.string(), at: nullableText, error: nullableText })
        .nullable()
        .catch(null),
      sent: z.number().catch(0),
      pending: z.number().catch(0),
      failed: z.number().catch(0),
      requested: z.number().catch(0),
      members: z.number().catch(0),
      next_brief_at: nullableText,
    })
    .nullable()
    .catch(null),
  runs: z
    .array(
      z.object({
        id: z.string(),
        kind: z.enum(["team_brief", "personal_brief"]).catch("personal_brief"),
        status: z.enum(["running", "pending", "completed", "failed"]).catch("failed"),
        member_id: nullableText,
        member: nullableText,
        tokens: z.number().catch(0),
        error: nullableText,
        complete: z.boolean().catch(true),
        retryable: z.boolean().catch(false),
        at: z.string(),
      })
    )
    .catch([]),
});

export const dailyBriefRequestSchema = z.object({
  id: z.string(),
  requested_at: nullableText,
});

/** The saved settings. */
export const dailyBriefSavedSchema = z.object(dailyBriefSettingsShape);

export const dailyBriefSyncSchema = z.object({
  linked: z.number(),
  unresolved: z.array(z.string()).catch([]),
});

const dataPolicyScopeSchema = z.object({
  scope_id: z.string(),
  kind: nullableText,
  display_name: nullableText,
  observed_at: nullableText,
  tags: z.array(z.string()).catch([]),
  audience_mode: z.string().catch("space"),
  sealed: z.boolean().catch(false),
  classified: z.boolean().catch(false),
});

/** Information-flow settings of one Agent Swarm, by chat workspace. */
export const dataPolicySchema = z.object({
  mode: z.enum(["off", "audit", "enforce"]).catch("off"),
  language: z.enum(["zh", "en"]).catch("zh"),
  audience_modes: z.array(z.string()).catch(["space", "members"]),
  connects: z.array(
    z.object({
      connect_id: z.string(),
      provider: nullableText,
      name: nullableText,
      available: z.boolean().catch(false),
      // Each list holds at most 200 rows; more exist when this is set.
      truncated: z.boolean().catch(false),
      scopes: z.array(dataPolicyScopeSchema).catch([]),
      clearances: z
        .array(z.object({ tag: z.string(), principals: z.array(z.string()) }))
        .catch([]),
      principals: z
        .array(
          z.object({ id: z.string(), observed: nullableText, override: nullableText })
        )
        .catch([]),
    })
  ),
});

/** A Slack source (connect) of a router Agent, as Slack triage shows it. */
const triageSourceSchema = z.object({
  connect_id: z.string(),
  bot_name: nullableText,
  bot_username: nullableText,
  workspace_name: nullableText,
  // `false`: the source's record could not be read; nothing but "off" is offered.
  complete: z.boolean().catch(false),
  enabled: z.boolean().catch(false),
  authority_valid: z.boolean().catch(false),
  // `false`: the channel list is known to be incomplete; `null`: not reported.
  channel_scope_complete: nullableBoolean,
  channel_controls: z.boolean().catch(false),
  channels: z
    .array(
      z.object({
        id: z.string(),
        name: nullableText,
        enabled: z.boolean().catch(false),
      })
    )
    .catch([]),
});

export const triageAgentStates = ["ready", "partial", "empty", "unavailable"] as const;
const okOrUnavailable = z.enum(["ok", "unavailable"]).catch("unavailable");

/** Every router Agent of the org with its Slack sources. */
export const triageOverviewSchema = z.object({
  agents_status: okOrUnavailable,
  agents: z.array(
    z.object({
      id: z.string(),
      name: z.string().catch(""),
      project_id: z.string(),
      project_name: nullableText,
      state: z.enum(triageAgentStates).catch("unavailable"),
      sources: z.array(triageSourceSchema).catch([]),
    })
  ),
  posture_status: okOrUnavailable,
  has_sources: z.boolean().catch(false),
  unavailable_projects: z.array(nullableText).catch([]),
});

export const triageEvaluationSchema = z.object({
  readiness: z.enum(["ready", "unavailable", "unknown"]).catch("unknown"),
  checked_at_ms: nullableNumber,
});

export const triageChannelsSchema = z.object({
  channels: z
    .array(
      z.object({
        id: z.string(),
        name: z.string().catch(""),
        private: z.boolean().catch(false),
      })
    )
    .catch([]),
  next_cursor: nullableText,
});

export const triageNoticeSchema = z.object({ notice: z.string().catch("") });

/**
 * Where the Agent's Triage Tasks run: on its swarm, at the default place and
 * default Task model that the swarm's Settings (`settings_href`) set.
 * `tools_ready` is false when the swarm's plugins turn off a Triage tool,
 * null when unknown.
 */
export const triageTaskSettingsSchema = z.object({
  settings_href: z.string(),
  tools_ready: nullableBoolean,
});

const triageContextSchema = z.object({
  id: nullableText,
  kind: nullableText,
  state: nullableText,
  resolved_reason: nullableText,
  subject: z.string().catch(""),
  value: z.string().catch(""),
  confidence: nullableText,
  source_count: nullableNumber,
  basis: nullableText,
  next_check_at_ms: nullableNumber,
});

const triageThreadSchema = z.object({
  connect_id: nullableText,
  channel_id: nullableText,
  thread_ts: nullableText,
  message_count: nullableNumber,
  latest_activity_at_ms: nullableNumber,
  url: nullableText,
});

/** A Slack message of an activity row; its text is read through `revealTriageText`. */
const triageMessageSchema = z.object({
  ref: z.string(),
  speaker: nullableText,
  actor_kind: nullableText,
  at: nullableNumber,
  files: z
    .object({
      total: z.number().int().catch(0),
      truncated: z.boolean().catch(false),
      items: z
        .array(z.object({ name: z.string().catch(""), kind: nullableText }))
        .catch([]),
    })
    .nullable()
    .catch(null),
});

const counts = z.record(z.string(), z.number()).catch({});

const triageOutcomeSchema = z.object({
  kind: z.literal("outcome"),
  id: z.string(),
  obligation_id: nullableText,
  at: nullableNumber,
  updated_at: nullableNumber,
  state: nullableText,
  attempts: nullableNumber,
  source: triageThreadSchema,
  messages: z.array(triageMessageSchema).catch([]),
  communication: z.object({
    kind: nullableText,
    reason: nullableText,
    status: nullableText,
    text: nullableText,
    emoji: nullableText,
    explanation: nullableText,
  }),
  effect: z.object({
    adapter: nullableText,
    status: nullableText,
    external_writes: nullableNumber,
  }),
  companion: z
    .object({
      kind: nullableText,
      emoji: nullableText,
      state: nullableText,
      external_writes: nullableNumber,
    })
    .nullable()
    .catch(null),
  evidence: counts,
  context: counts,
  related_context: z.array(triageContextSchema).catch([]),
  delegations: z
    .array(
      z.object({
        index: nullableNumber,
        status: nullableText,
        task: z.string().catch(""),
      })
    )
    .catch([]),
});

const triageProcessingSchema = z.object({
  kind: z.literal("processing"),
  id: z.string(),
  at: nullableNumber,
  state: nullableText,
  terminal_status: nullableText,
  suggested_action: nullableText,
  source: triageThreadSchema,
  messages: z.array(triageMessageSchema).catch([]),
});

/** One Timeline page: at most 20 outcomes, plus received messages on the first page. */
export const triageActivitySchema = z.object({
  items: z.array(
    z.discriminatedUnion("kind", [triageOutcomeSchema, triageProcessingSchema])
  ),
  next_cursor: nullableText,
  intake_status: okOrUnavailable,
  // `null`: follow-ups could not be read.
  follow_ups: z.array(triageContextSchema).nullable().catch(null),
  context: z.array(triageContextSchema).catch([]),
});

export const triageRevealSchema = z.object({
  messages: z.record(
    z.string(),
    z.object({
      parts: z
        .array(
          z.object({
            kind: z.enum(["text", "mention", "link"]).catch("text"),
            text: z.string().catch(""),
            url: nullableText,
          })
        )
        .catch([]),
      speaker: nullableText,
    })
  ),
});

export const triageHeatmapSchema = z.object({
  since_ms: z.number(),
  truncated: z.boolean().catch(false),
  cells: z
    .array(
      z.object({
        connect_id: nullableText,
        channel_id: z.string(),
        at_ms: z.number(),
        reply: z.number().catch(0),
        reaction: z.number().catch(0),
        silence: z.number().catch(0),
        total: z.number().catch(0),
      })
    )
    .catch([]),
});

export const triageProcessingDetailSchema = z.object({
  state: nullableText,
  terminal_status: nullableText,
  suggested_action: nullableText,
  source: z.record(z.string(), z.string().nullable()).catch({}),
  milestones: z.record(z.string(), z.number().nullable()).catch({}),
  evaluator: z
    .object({
      model: nullableText,
      provider: nullableText,
      prompt_ref: nullableText,
      policy_ref: nullableText,
      request_count: nullableNumber,
      tool_names: z.array(z.string()).nullable().catch(null),
      retry: nullableBoolean,
    })
    .nullable()
    .catch(null),
  trace_ref: nullableText,
  decision_reason: nullableText,
});

export const triageDelegationSchema = z.object({
  state: z.enum(["created", "not_created", "unavailable"]).catch("unavailable"),
  href: nullableText,
  preview: z
    .object({
      title: nullableText,
      status: nullableText,
      delivery_error: z.boolean().catch(false),
      participation: z
        .object({ kind: nullableText, reason_code: nullableText })
        .nullable()
        .catch(null),
      messages: z
        .array(
          z.object({
            id: nullableText,
            actor: nullableText,
            at: nullableNumber,
            text: z.string().catch(""),
          })
        )
        .catch([]),
    })
    .nullable()
    .catch(null),
});

const triageUseSchema = z.object({
  id: z.string(),
  session_id: nullableText,
  used_at: nullableNumber,
  excerpt: nullableText,
});

export const triageKnowledgeSchema = z.object({
  status: okOrUnavailable,
  assertions: z
    .array(
      z.object({
        id: z.string(),
        kind: z.enum(["fact", "decision"]).catch("fact"),
        content: z.string().catch(""),
        observed_at: nullableText,
        source: z
          .object({ type: nullableText, ref: nullableText })
          .catch({ type: null, ref: null }),
        subjects: z
          .array(
            z.object({
              kind: z.enum(["person", "project"]).catch("project"),
              id: z.string(),
              name: z.string().catch(""),
            })
          )
          .catch([]),
        uses: z.array(triageUseSchema).catch([]),
      })
    )
    .catch([]),
  members: z
    .array(
      z.object({
        id: z.string(),
        name: z.string().catch(""),
        role: nullableText,
        source_ref: nullableText,
      })
    )
    .catch([]),
  retained: z
    .array(
      z.object({
        id: z.string(),
        kind: z.enum(["decision", "context"]).catch("context"),
        name: z.string().catch(""),
        content: z.string().catch(""),
        confidence: nullableText,
        source_count: nullableNumber,
        updated_at_ms: nullableNumber,
      })
    )
    .catch([]),
  usage: z.enum(["available", "unavailable"]).catch("unavailable"),
  usage_complete: z.boolean().catch(false),
  retained_status: z.enum(["available", "unavailable"]).catch("unavailable"),
  incomplete: z.boolean().catch(false),
  imported: z
    .object({
      status: z.enum(["ok", "off", "unavailable"]).catch("off"),
      grounding: z.boolean().catch(false),
      items: z
        .array(
          z.object({
            id: z.string(),
            kind: z.enum(["person", "project", "decision", "context"]).catch("context"),
            name: z.string().catch(""),
            aliases: z.array(z.string()).catch([]),
            source_refs: z.array(z.string()).catch([]),
          })
        )
        .catch([]),
    })
    .catch({ status: "off", grounding: false, items: [] }),
});

const revokedKeySchema = z.object({ id: z.string(), revoked_at: nullableText });
const removedRunnerSchema = z.object({ id: z.string() });

export type BftUser = z.infer<typeof userSchema>;
export type BftOrgSummary = z.infer<typeof orgSummarySchema>;
export type BftSession = z.infer<typeof sessionSchema>;
export type BftOrgContext = z.infer<typeof orgContextSchema>;
export type BftCapabilities = BftOrgContext["capabilities"];
export type BftOverview = z.infer<typeof overviewSchema>;
export type BftProjectOverview = z.infer<typeof projectOverviewSchema>;
export type BftOnboarding = z.infer<typeof onboardingSchema>;
export type BftOnboardingStep = (typeof onboardingSteps)[number];
export type BftProjectStatus = (typeof projectStatuses)[number];
export type BftHealth = z.infer<typeof healthSchema>;
export type BftHealthStatus = (typeof healthStatuses)[number];
export type BftSignalStatus = (typeof signalStatuses)[number];
export type BftAuditPage = z.infer<typeof auditPageSchema>;
export type BftAuditEntry = BftAuditPage["entries"][number];
export type BftOrgRole = (typeof orgRoles)[number];
export type BftMembers = z.infer<typeof membersSchema>;
export type BftMember = z.infer<typeof memberSchema>;
export type BftRunnerStatus = (typeof runnerStatuses)[number];
export type BftRunner = z.infer<typeof runnerSchema>;
export type BftRunnersPage = z.infer<typeof runnersPageSchema>;
export type BftRunnerConnectors = z.infer<typeof runnerConnectorsSchema>;
export type BftRunnerConnector = BftRunnerConnectors["entries"][number];
export type BftRunnerOnboarding = z.infer<typeof runnerOnboardingSchema>;
export type BftInstallCommand = z.infer<typeof installCommandSchema>;
export type BftCli = z.infer<typeof cliSchema>;
export type BftSettingsGeneral = z.infer<typeof settingsGeneralSchema>;
export type BftSettingsModels = z.infer<typeof settingsModelsSchema>;
export type BftSubscriptionProvider = (typeof subscriptionProviders)[number];
export type BftModelChoice = z.infer<typeof modelChoiceSchema>;
export type BftModelOption = z.infer<typeof modelOptionSchema>;
export type BftAccount = z.infer<typeof accountSchema>;
export type BftAccountsPage = z.infer<typeof accountsPageSchema>;
export type BftResetResult = z.infer<typeof resetResultSchema>;
export type BftAccountUsage = z.infer<typeof accountUsageSchema>;
export type BftOAuthAttempt = z.infer<typeof oauthAttemptSchema>;
export type BftOAuthResult = z.infer<typeof oauthResultSchema>;
export type BftCliLogin = z.infer<typeof cliLoginSchema>;
export type BftWizard = z.infer<typeof wizardSchema>;
export type BftWizardStep = (typeof wizardSteps)[number];
export type BftWizardIntegrations = z.infer<typeof wizardIntegrationsSchema>;
export type BftToolkitState = (typeof toolkitStates)[number];
export type BftWizardFinish = z.infer<typeof wizardFinishSchema>;
export type BftCliLoginStatus = (typeof cliLoginStatuses)[number];
export type BftSettingsSso = z.infer<typeof settingsSsoSchema>;
export type BftSsoProvider = (typeof ssoProviders)[number];
export type BftSsoChecks = z.infer<typeof ssoChecksSchema>;
export type BftSettingsIntegrations = z.infer<typeof settingsIntegrationsSchema>;
export type BftOAuthSection = z.infer<typeof oauthSectionSchema>;
export type BftComposioSection = z.infer<typeof composioSectionSchema>;
export type BftSignalSection = z.infer<typeof signalSectionSchema>;
export type BftFeishuSection = z.infer<typeof feishuSectionSchema>;
export type BftFeishuApp = BftFeishuSection["apps"][number];
export type BftSwarm = z.infer<typeof swarmSchema>;
export type BftSwarmsPage = z.infer<typeof swarmsPageSchema>;
export type BftSwarmAgents = z.infer<typeof swarmAgentsSchema>;
export type BftSwarmAgentRow = BftSwarmAgents["agents"][number];
export type BftSwarmAgent = z.infer<typeof swarmAgentSchema>;
export type BftSwarmAgentWrite = z.infer<typeof swarmAgentWriteSchema>;
export type BftAgentConfig = z.infer<typeof agentConfigSchema>;
export type BftModelPickerRow = z.infer<typeof modelPickerRowSchema>;
export type BftAgentTargets = z.infer<typeof agentTargetsSchema>;
export type BftAgentStation = BftAgentTargets["stations"][number];
export type BftSwarmDevices = z.infer<typeof swarmDevicesSchema>;
export type BftSwarmDevice = BftSwarmDevices["devices"][number];
export type BftAndroidDevice = NonNullable<BftSwarmDevice["android"]>;
export type BftComputeEnvironment = BftSwarmDevices["compute"]["environments"][number];
export type BftCloudVm = BftSwarmDevices["cloud_vm"];
export type BftDeviceRunners = z.infer<typeof deviceRunnersSchema>;
export type BftSwarmTasks = z.infer<typeof swarmTasksSchema>;
export type BftTaskTargets = z.infer<typeof taskTargetsSchema>;
export type BftTaskPlace = BftTaskTargets["places"][number];

/** A new Task: what it does, and where it runs with which model when named. */
export interface BftNewTask {
  title: string;
  content: string;
  runs_on?: BftSwarmTaskPlace;
  model?: BftModelChoice;
}
export type BftSwarmTask = BftSwarmTasks["tasks"][number];
export type BftSwarmSchedules = z.infer<typeof swarmSchedulesSchema>;
export type BftSwarmTaskDetail = z.infer<typeof swarmTaskSchema>;
export type BftTaskHeader = z.infer<typeof taskHeaderSchema>;
export type BftTaskSchedule = z.infer<typeof taskScheduleSchema>;
export type BftTaskScheduleForm = z.infer<typeof taskScheduleFormSchema>;
export type BftTaskMessage = z.infer<typeof taskMessageSchema>;
export type BftTaskMessages = z.infer<typeof taskMessagesSchema>;
export type BftTaskScheduleReply = z.infer<typeof taskScheduleReplySchema>;
export type BftSwarmSchedule = BftSwarmSchedules["schedules"][number];
export type BftSwarmWebsites = z.infer<typeof swarmWebsitesSchema>;
export type BftSwarmSettings = z.infer<typeof swarmSettingsSchema>;
export type BftSwarmTaskPlace = z.infer<typeof swarmTaskPlaceSchema>;
export type BftSwarmAccessRole = (typeof swarmAccessRoles)[number];
export type BftSwarmAccessPage = z.infer<typeof swarmAccessPageSchema>;
export type BftSwarmMember = BftSwarmAccessPage["members"][number];
export type BftSwarmAccessWrite = z.infer<typeof swarmAccessWriteSchema>;
export type BftPlugin = z.infer<typeof pluginSchema>;
export type BftPluginRefKey = (typeof pluginRefKeys)[number];
export type BftPluginRef = z.infer<typeof pluginRefSchema>;
export type BftPlugins = z.infer<typeof pluginsSchema>;
export type BftSwarmPlugins = z.infer<typeof swarmPluginsSchema>;
export type BftSwarmPlugin = BftSwarmPlugins["plugins"][number];
export type BftSwarmPluginDetail = z.infer<typeof swarmPluginDetailSchema>;
export type BftPluginConnection = z.infer<typeof pluginConnectionSchema>;
export type BftConnectionStart = z.infer<typeof connectionStartSchema>;
export type BftSwarmConnections = z.infer<typeof swarmConnectionsSchema>;
export type BftQqMenuItem = z.infer<typeof qqMenuItemSchema>;
export type BftSlackManifest = z.infer<typeof slackManifestSchema>["manifest"];
export type BftRunChecks = z.infer<typeof runChecksSchema>;
export type BftSignalClaim = z.infer<typeof signalClaimSchema>["claim"];
export type BftTailnetSection = z.infer<typeof tailnetSectionSchema>;
export type BftTailnetSettings = z.infer<typeof tailnetSettingsSchema>;

/**
 * What the Slack connect form sends; the secrets are write-only. Messages go
 * to the Router (`inbound_agent_id`, null for the swarm's Router), or each new
 * Slack thread becomes a Task that runs `inbound_tasks.model` (null: the
 * swarm's default Task model).
 */
export interface BftSlackCredentials {
  app_name: string;
  app_id: string;
  client_id: string;
  client_secret: string;
  signing_secret: string;
}
export type BftSlackInbound =
  | { inbound_agent_id: string | null }
  | { inbound_tasks: { model: BftModelChoice | null } };
export type BftSlackConnectDraft = BftSlackCredentials & BftSlackInbound;
export type BftSwarmSkills = z.infer<typeof swarmSkillsSchema>;
export type BftSwarmSkill = BftSwarmSkills["custom"][number];
export type BftSwarmSkillDetail = z.infer<typeof swarmSkillDetailSchema>;
export type BftMeetingsOverview = z.infer<typeof meetingsOverviewSchema>;
export type BftMeetingStatus = (typeof meetingStatuses)[number];
export type BftMeetingConnect = BftMeetingsOverview["connects"][number];
export type BftMeetingHistory = z.infer<typeof meetingHistorySchema>;
export type BftMeetingRecord = BftMeetingHistory["meetings"][number];
export type BftMeetingCatalog = z.infer<typeof meetingCatalogSchema>;
export type BftMeetingSeries = z.infer<typeof meetingSeriesSchema>["meetings"][number];
export type BftDailyBrief = z.infer<typeof dailyBriefSchema>;
export type BftDailyBriefSettings = NonNullable<BftDailyBrief["settings"]>;
export type BftDailyBriefMember = BftDailyBrief["members"][number];
export type BftDailyBriefSaved = z.infer<typeof dailyBriefSavedSchema>;
export type BftDailyBriefSync = z.infer<typeof dailyBriefSyncSchema>;
export type BftDailyBriefRun = BftDailyBrief["runs"][number];
export type BftDataPolicy = z.infer<typeof dataPolicySchema>;
export type BftDataPolicyConnect = BftDataPolicy["connects"][number];
export type BftDataPolicyScope = z.infer<typeof dataPolicyScopeSchema>;
export type BftTriageOverview = z.infer<typeof triageOverviewSchema>;
export type BftTriageAgent = BftTriageOverview["agents"][number];
export type BftTriageSource = z.infer<typeof triageSourceSchema>;
export type BftTriageEvaluation = z.infer<typeof triageEvaluationSchema>;
export type BftTriageChannels = z.infer<typeof triageChannelsSchema>;
export type BftTriageTaskSettings = z.infer<typeof triageTaskSettingsSchema>;
export type BftTriageActivity = z.infer<typeof triageActivitySchema>;
export type BftTriageItem = BftTriageActivity["items"][number];
export type BftTriageOutcome = z.infer<typeof triageOutcomeSchema>;
export type BftTriageContext = z.infer<typeof triageContextSchema>;
export type BftTriageMessage = z.infer<typeof triageMessageSchema>;
export type BftTriageReveal = z.infer<typeof triageRevealSchema>["messages"];
export type BftTriageHeatmap = z.infer<typeof triageHeatmapSchema>;
export type BftTriageProcessingDetail = z.infer<typeof triageProcessingDetailSchema>;
export type BftTriageDelegation = z.infer<typeof triageDelegationSchema>;
export type BftTriageKnowledge = z.infer<typeof triageKnowledgeSchema>;
/** The Timeline page a request is for; `before` and `channel` come from the heatmap. */
export interface BftTriageNav {
  kind: string;
  channel: string | null;
  before: number | null;
  cursor: string | null;
}
/** What the settings form saves; `{enabled: false}` pauses preparation. */
export type BftMeetingSettingsDraft =
  | { enabled: false }
  | {
      enabled: true;
      connect_id: string;
      channel_id: string;
      calendar_selections: { account_id: string; calendar_id: string }[];
      preparation_lead_minutes: number;
      research_enabled: boolean;
      calendar_writeback: boolean;
      autojoin: boolean;
      personal_preparation: boolean;
      channel_notice: boolean;
      series: BftMeetingSeries[];
    };
/** One Data policy change; every change answers with the settings read again. */
export type BftDataPolicyChange =
  | { kind: "group"; mode?: string; language?: string }
  | {
      kind: "classify";
      connect: string;
      scope: string;
      tags: string[];
      audience_mode: string;
      sealed: boolean;
    }
  | { kind: "reset"; connect: string; scope: string }
  | { kind: "grant"; connect: string; tag: string; user: string }
  | { kind: "withdraw"; connect: string; tag: string; principal: string }
  | { kind: "place"; connect: string; user: string; placement: string };
/** A new skill from the Skills page. */
export interface BftSkillDraft {
  name: string;
  description: string;
  instructions: string;
  activation: "regular" | "per-message";
}

/** What the plugin editor sends; `refs` replaces every category. */
export interface BftPluginDraft {
  name: string;
  description: string;
  setup_destination: string;
  refs: Record<BftPluginRefKey, BftPluginRef[]>;
}

const errorEnvelopeSchema = z.object({
  ok: z.literal(false),
  error: z.object({
    code: z.string(),
    message: z.string(),
    details: z.object({ fields: z.unknown() }).partial().optional().catch(undefined),
  }),
});

/** Field name to the message shown under that field. */
export type BftFieldErrors = Record<string, string>;

/**
 * `details.fields` arrives as a changeset map (`{slug: ["has already been
 * taken"]}`) or, for a rule over several fields, as a list of field names
 * that share the error's own message.
 */
export function fieldErrors(fields: unknown, message: string): BftFieldErrors {
  if (Array.isArray(fields)) {
    return Object.fromEntries(
      fields
        .filter((field) => typeof field === "string")
        .map((field) => [field, message])
    );
  }
  if (!fields || typeof fields !== "object") return {};
  return Object.fromEntries(
    Object.entries(fields).flatMap(([field, value]) => {
      const text = (Array.isArray(value) ? value : [value])
        .filter((item) => typeof item === "string")
        .join("; ");
      return text ? [[field, text]] : [];
    })
  );
}

export class BftApiError extends Error {
  readonly status: number;
  readonly code: string | undefined;
  readonly fields: BftFieldErrors;

  constructor(
    status: number,
    message: string,
    code?: string,
    fields: BftFieldErrors = {}
  ) {
    super(message);
    this.name = "BftApiError";
    this.status = status;
    this.code = code;
    this.fields = fields;
  }
}

/** The browser is leaving for /login; callers keep showing their loading state. */
export class BftUnauthenticatedError extends BftApiError {
  constructor() {
    super(401, "Not signed in", "unauthenticated");
    this.name = "BftUnauthenticatedError";
  }
}

export class BftNotFoundError extends BftApiError {
  constructor(code?: string, message = "Not found") {
    super(404, message, code);
    this.name = "BftNotFoundError";
  }
}

/**
 * Phoenix rejects a write without the page's CSRF token with a bare 403 (not
 * the JSON envelope). The page has to be reloaded to get a fresh token.
 */
export const csrfRejectedCode = "csrf_rejected";

/** The token Phoenix writes into `<meta name="csrf-token">` of the SPA page. */
export function csrfToken(doc: Document | undefined = globalThis.document) {
  return (
    doc?.querySelector('meta[name="csrf-token"]')?.getAttribute("content")?.trim() ||
    null
  );
}

/** Headers for a JSON write: the CSRF token whenever the page carries one. */
export function writeHeaders(token: string | null, json: boolean) {
  return {
    accept: "application/json",
    ...(json ? { "content-type": "application/json" } : {}),
    ...(token ? { "x-csrf-token": token } : {}),
  };
}

export interface BftApiOptions {
  fetch?: typeof fetch;
  /** Full-page navigation; injectable for tests. */
  assignLocation?: (href: string) => void;
  /** Reads the CSRF token at write time; injectable for tests. */
  csrfToken?: () => string | null;
}

export interface BftApi {
  /**
   * Calls `listener` after every successful write that can change what pages
   * read; failed writes and POSTs that only read (status polls, reveals) do
   * not call it. Returns the unsubscribe.
   */
  onWrite(listener: () => void): () => void;
  session(signal?: AbortSignal): Promise<BftSession>;
  orgContext(org: string, signal?: AbortSignal): Promise<BftOrgContext>;
  overview(org: string, signal?: AbortSignal): Promise<BftOverview>;
  onboarding(org: string, signal?: AbortSignal): Promise<BftOnboarding>;
  /** Skips the checklist for good, or acknowledges it when every step is done. */
  dismissOnboarding(org: string): Promise<BftOnboarding>;
  /** A member asks the org admins to configure an OAuth client. */
  remindOnboardingAdmins(org: string): Promise<BftOnboarding>;
  projectOverview(
    org: string,
    project: string,
    signal?: AbortSignal
  ): Promise<BftProjectOverview>;
  /** One page of Agent Swarms matching `query`; `cursor` continues a page. */
  swarms(
    org: string,
    query: string,
    cursor: string | null,
    signal?: AbortSignal
  ): Promise<BftSwarmsPage>;
  createSwarm(org: string, swarm: { name: string; slug: string }): Promise<BftSwarm>;
  /** The swarm's agents: its Router. */
  swarmAgents(
    org: string,
    project: string,
    signal?: AbortSignal
  ): Promise<BftSwarmAgents>;
  swarmAgent(
    org: string,
    project: string,
    agentId: string,
    signal?: AbortSignal
  ): Promise<BftSwarmAgent>;
  agentConfig(
    org: string,
    project: string,
    agentId: string,
    signal?: AbortSignal
  ): Promise<BftAgentConfig>;
  /** A missing `model` keeps the model; `model: null` follows the default model. */
  configureAgent(
    org: string,
    project: string,
    agentId: string,
    config: { model?: BftModelChoice | null; system_prompt: string }
  ): Promise<BftSwarmAgentWrite>;
  agentTargets(
    org: string,
    project: string,
    signal?: AbortSignal
  ): Promise<BftAgentTargets>;
  switchRouterSession(
    org: string,
    project: string,
    agentId: string,
    expectedSessionId: string
  ): Promise<{ router_session_id: string; notice: string }>;
  /** The Devices page. */
  swarmDevices(
    org: string,
    project: string,
    signal?: AbortSignal
  ): Promise<BftSwarmDevices>;
  /** Whether a device request is still being provisioned; cheap to poll. */
  deviceProvisioning(
    org: string,
    project: string,
    signal?: AbortSignal
  ): Promise<{ active: boolean }>;
  deviceRunners(
    org: string,
    project: string,
    signal?: AbortSignal
  ): Promise<BftDeviceRunners>;
  createDevice(
    org: string,
    project: string,
    device: { name: string; alias: string; runner_id: string }
  ): Promise<{ notice: string }>;
  setCloudComputer(
    org: string,
    project: string,
    enabled: boolean
  ): Promise<{ enabled: boolean; notice: string }>;
  /**
   * Choose the org Runner the swarm's Cloud VM uses, before the VM exists.
   * `requestId` makes a retried choice idempotent.
   */
  chooseCloudVmRunner(
    org: string,
    project: string,
    choice: { runner_id: string; request_id: string }
  ): Promise<{ notice: string }>;
  removeCloudVmRunner(org: string, project: string): Promise<{ notice: string }>;
  disconnectDevice(
    org: string,
    project: string,
    deviceId: string
  ): Promise<{ notice: string }>;
  deleteDevice(
    org: string,
    project: string,
    deviceId: string
  ): Promise<{ notice: string }>;
  createComputeInstallCommand(
    org: string,
    project: string,
    requestId: string
  ): Promise<BftComputeInstallCommand>;
  createShellWorkload(
    org: string,
    project: string,
    environmentId: string
  ): Promise<{ notice: string }>;
  /** Drains or revokes the environment at the revision the page showed. */
  setEnvironmentIntent(
    org: string,
    project: string,
    environmentId: string,
    intent: "drain" | "revoke",
    expectedRevision: number
  ): Promise<{ notice: string }>;
  /** One page of a swarm's tasks; `cursor` continues the list. */
  swarmTasks(
    org: string,
    project: string,
    cursor: string | null,
    signal?: AbortSignal
  ): Promise<BftSwarmTasks>;
  /** Where a new Task can run and the models it can choose. */
  taskTargets(
    org: string,
    project: string,
    signal?: AbortSignal
  ): Promise<BftTaskTargets>;
  createTask(
    org: string,
    project: string,
    task: BftNewTask
  ): Promise<{ id: string; href: string }>;
  swarmSchedules(
    org: string,
    project: string,
    signal?: AbortSignal
  ): Promise<BftSwarmSchedules>;
  /** Deletes one schedule; answers the refreshed list. */
  deleteSchedule(
    org: string,
    project: string,
    scheduleId: string
  ): Promise<BftSwarmSchedules>;
  /** One task: its header, schedule, participants and latest messages. */
  swarmTask(
    org: string,
    project: string,
    task: string,
    signal?: AbortSignal
  ): Promise<BftSwarmTaskDetail>;
  /**
   * Messages after (newer) or before (older) a message id; neither reads the
   * latest page.
   */
  taskMessages(
    org: string,
    project: string,
    task: string,
    cursor: { after: string } | { before: string } | null,
    signal?: AbortSignal
  ): Promise<BftTaskMessages>;
  /** Steers the task; a retry with the same `request_id` appends one message. */
  sendTaskMessage(
    org: string,
    project: string,
    task: string,
    message: { text: string; request_id: string }
  ): Promise<{ message_id: string | null }>;
  /** Marks the task complete at the review version the user saw. */
  acceptTaskReview(
    org: string,
    project: string,
    task: string,
    reviewVersion: number
  ): Promise<{ task: BftTaskHeader }>;
  saveTaskSchedule(
    org: string,
    project: string,
    task: string,
    form: BftTaskScheduleForm
  ): Promise<BftTaskScheduleReply>;
  deleteTaskSchedule(
    org: string,
    project: string,
    task: string
  ): Promise<BftTaskScheduleReply>;
  /** How the form's recurrence reads, localized; null until it has one. */
  previewTaskSchedule(
    org: string,
    project: string,
    task: string,
    form: Omit<BftTaskScheduleForm, "command">,
    signal?: AbortSignal
  ): Promise<{ recurrence: string | null }>;
  swarmWebsites(
    org: string,
    project: string,
    signal?: AbortSignal
  ): Promise<BftSwarmWebsites>;
  swarmSettings(
    org: string,
    project: string,
    signal?: AbortSignal
  ): Promise<BftSwarmSettings>;
  renameSwarm(org: string, project: string, name: string): Promise<BftSwarmSettings>;
  /** Set the default Task model to one of `task_model.models`' choices. */
  setSwarmTaskModel(
    org: string,
    project: string,
    model: BftModelChoice
  ): Promise<BftSwarmSettings>;
  /** Clear the default Task model: each Task runs the org default Task model. */
  clearSwarmTaskModel(org: string, project: string): Promise<BftSwarmSettings>;
  /** Set where a Task runs when the Router names no place. */
  setSwarmTaskPlace(
    org: string,
    project: string,
    place: BftSwarmTaskPlace
  ): Promise<BftSwarmSettings>;
  archiveSwarm(
    org: string,
    project: string
  ): Promise<{ redirect: string; notice: string }>;
  /** A later page of the Access list; `cursor` is a previous `next_cursor`. */
  swarmAccess(
    org: string,
    project: string,
    cursor: string
  ): Promise<BftSwarmAccessPage>;
  /**
   * Access writes answer the whole Settings payload, or where to go when the
   * caller no longer sees the swarm.
   */
  grantSwarmAccess(
    org: string,
    project: string,
    grant: { email: string; role: BftSwarmAccessRole }
  ): Promise<BftSwarmAccessWrite>;
  changeSwarmAccess(
    org: string,
    project: string,
    userId: string,
    role: BftSwarmAccessRole
  ): Promise<BftSwarmAccessWrite>;
  removeSwarmAccess(
    org: string,
    project: string,
    userId: string
  ): Promise<BftSwarmAccessWrite>;
  swarmPlugins(
    org: string,
    project: string,
    signal?: AbortSignal
  ): Promise<BftSwarmPlugins>;
  swarmPlugin(
    org: string,
    project: string,
    pluginId: string,
    signal?: AbortSignal
  ): Promise<BftSwarmPluginDetail>;
  setSwarmPluginEnabled(
    org: string,
    project: string,
    pluginId: string,
    enabled: boolean
  ): Promise<{ notice: string }>;
  /** Creates a project plugin when `id` is null. */
  saveSwarmPlugin(
    org: string,
    project: string,
    id: string | null,
    plugin: BftPluginDraft
  ): Promise<{ notice: string }>;
  connectPlugin(
    org: string,
    project: string,
    pluginId: string,
    connectionId: string,
    configValues?: Record<string, string>
  ): Promise<BftConnectionStart>;
  disconnectPlugin(
    org: string,
    project: string,
    pluginId: string,
    connectionId: string
  ): Promise<{ notice: string }>;
  swarmConnections(
    org: string,
    project: string,
    signal?: AbortSignal
  ): Promise<BftSwarmConnections>;
  slackManifest(
    org: string,
    project: string,
    appName: string,
    signal?: AbortSignal
  ): Promise<BftSlackManifest>;
  /** Connects an org Feishu app; Salix keeps its secrets. */
  createFeishuConnect(
    org: string,
    project: string,
    connect: { app_id: string; app_name: string }
  ): Promise<{ notice: string }>;
  /**
   * Connects a Lark app by its App ID and App Secret, with the Verification
   * Token or the Encrypt Key of its event subscription (at least one).
   */
  createLarkConnect(
    org: string,
    project: string,
    connect: {
      app_id: string;
      app_secret: string;
      verification_token: string;
      encrypt_key: string;
    }
  ): Promise<{ notice: string }>;
  /** Connects a QQ bot by its AppID and AppSecret. */
  createQqConnect(
    org: string,
    project: string,
    connect: { app_id: string; app_secret: string }
  ): Promise<{ notice: string }>;
  /** Replaces the shortcuts of a QQ bot's command menu; QQ gets the menu at once. */
  updateQqMenu(
    org: string,
    project: string,
    connectId: string,
    items: BftQqMenuItem[]
  ): Promise<{ notice: string }>;
  createSlackConnect(
    org: string,
    project: string,
    connect: BftSlackConnectDraft
  ): Promise<{ notice: string }>;
  setImConnectEnabled(
    org: string,
    project: string,
    connectId: string,
    enabled: boolean
  ): Promise<{ notice: string }>;
  deleteImConnect(
    org: string,
    project: string,
    connectId: string
  ): Promise<{ notice: string }>;
  runFeishuChecks(org: string, project: string): Promise<BftRunChecks>;
  /** Runs the checks of one Lark app: its request URL, route and bot identity. */
  runLarkChecks(org: string, project: string, connectId: string): Promise<BftRunChecks>;
  runSlackChecks(
    org: string,
    project: string,
    connectId: string
  ): Promise<BftRunChecks>;
  createSignalClaim(org: string, project: string): Promise<BftSignalClaim>;
  removeSignalBinding(
    org: string,
    project: string,
    bindingId: string
  ): Promise<{ notice: string }>;
  connectAccount(
    org: string,
    project: string,
    account: { provider: string; alias: string }
  ): Promise<BftConnectionStart>;
  setAccountEnabled(
    org: string,
    project: string,
    bindingId: string,
    enabled: boolean
  ): Promise<{ notice: string }>;
  disconnectAccount(
    org: string,
    project: string,
    bindingId: string
  ): Promise<{ notice: string }>;
  connectComposio(
    org: string,
    project: string,
    toolkit: string
  ): Promise<BftConnectionStart>;
  disconnectComposio(
    org: string,
    project: string,
    accountId: string
  ): Promise<{ notice: string }>;
  connectTailnet(
    org: string,
    project: string,
    settings: BftTailnetSettings
  ): Promise<z.infer<typeof tailnetWriteSchema>>;
  disconnectTailnet(
    org: string,
    project: string
  ): Promise<z.infer<typeof tailnetWriteSchema>>;
  swarmSkills(
    org: string,
    project: string,
    signal?: AbortSignal
  ): Promise<BftSwarmSkills>;
  swarmSkill(
    org: string,
    project: string,
    skillId: string,
    signal?: AbortSignal
  ): Promise<BftSwarmSkillDetail>;
  createSkill(
    org: string,
    project: string,
    skill: BftSkillDraft
  ): Promise<{ notice: string }>;
  uploadSkill(
    org: string,
    project: string,
    file: { filename: string; content: string }
  ): Promise<{ notice: string }>;
  deleteSkill(
    org: string,
    project: string,
    skillId: string
  ): Promise<{ notice: string }>;
  plugins(org: string, signal?: AbortSignal): Promise<BftPlugins>;
  /** Creates an organization plugin when `id` is null. */
  savePlugin(
    org: string,
    id: string | null,
    plugin: BftPluginDraft
  ): Promise<BftPlugin>;
  meetings(
    org: string,
    project: string,
    signal?: AbortSignal
  ): Promise<BftMeetingsOverview>;
  /** One past-meetings page; `cursor` continues it. */
  meetingHistory(
    org: string,
    project: string,
    cursor: string | null,
    signal?: AbortSignal
  ): Promise<BftMeetingHistory>;
  meetingCatalog(
    org: string,
    project: string,
    connect: string
  ): Promise<BftMeetingCatalog>;
  meetingChannels(
    org: string,
    project: string,
    connect: string,
    cursor: string
  ): Promise<z.infer<typeof meetingChannelsSchema>>;
  /** Meetings with a Google Meet link in the next 14 days of one calendar. */
  meetingSeries(
    org: string,
    project: string,
    calendar: { account_id: string; calendar_id: string },
    cursor: string | null
  ): Promise<z.infer<typeof meetingSeriesSchema>>;
  meetingReport(org: string, project: string, planId: string): Promise<string | null>;
  saveMeetings(
    org: string,
    project: string,
    draft: BftMeetingSettingsDraft
  ): Promise<unknown>;
  /** The daily brief's settings, members and last 7 days (owner/admin). */
  dailyBrief(org: string, signal?: AbortSignal): Promise<BftDailyBrief>;
  /**
   * `prepare_slack_app` asks again for the bot App's Slack access while the
   * brief stays on; turning it on always asks.
   */
  saveDailyBrief(
    org: string,
    settings: BftDailyBriefSettings
  ): Promise<BftDailyBriefSaved>;
  /** Links organization members to their Slack users by email. */
  syncDailyBriefMembers(org: string): Promise<BftDailyBriefSync>;
  /** Sends one member's brief on the delivery worker's next minute. */
  requestDailyBrief(org: string, member: string): Promise<unknown>;
  /** Router Agents and their Slack sources (owner/admin). */
  triage(org: string, signal?: AbortSignal): Promise<BftTriageOverview>;
  /** AI evaluation status; `refresh` drops the cached answer first. */
  triageEvaluation(
    org: string,
    agent: string,
    refresh: boolean,
    signal?: AbortSignal
  ): Promise<BftTriageEvaluation>;
  /** One page (at most 100) of the Slack channels a source can add. */
  triageChannels(
    org: string,
    agent: string,
    connect: string,
    cursor: string | null
  ): Promise<BftTriageChannels>;
  setTriageSource(
    org: string,
    agent: string,
    connect: string,
    enabled: boolean
  ): Promise<string>;
  setTriageChannel(
    org: string,
    agent: string,
    connect: string,
    channel: string,
    enabled: boolean
  ): Promise<string>;
  addTriageChannels(
    org: string,
    agent: string,
    connect: string,
    channelIds: string[]
  ): Promise<string>;
  triageTaskSettings(
    org: string,
    agent: string,
    signal?: AbortSignal
  ): Promise<BftTriageTaskSettings>;
  triageActivity(
    org: string,
    agent: string,
    nav: BftTriageNav,
    signal?: AbortSignal
  ): Promise<BftTriageActivity>;
  /**
   * Message text, audited per message before it is returned. With `nav` the
   * messages are on that Timeline page; without it, received in the last 7 days.
   */
  revealTriageText(
    org: string,
    agent: string,
    refs: string[],
    nav: BftTriageNav | null
  ): Promise<BftTriageReveal>;
  triageHeatmap(
    org: string,
    agent: string,
    signal?: AbortSignal
  ): Promise<BftTriageHeatmap>;
  triageProcessing(
    org: string,
    agent: string,
    ref: string,
    signal?: AbortSignal
  ): Promise<BftTriageProcessingDetail>;
  triageDelegation(
    org: string,
    agent: string,
    obligation: string,
    index: number
  ): Promise<BftTriageDelegation>;
  triageKnowledge(
    org: string,
    agent: string,
    signal?: AbortSignal
  ): Promise<BftTriageKnowledge>;
  dataPolicy(
    org: string,
    project: string,
    signal?: AbortSignal
  ): Promise<BftDataPolicy>;
  changeDataPolicy(
    org: string,
    project: string,
    change: BftDataPolicyChange
  ): Promise<BftDataPolicy>;
  health(org: string, signal?: AbortSignal): Promise<BftHealth>;
  /** One page of the audit log, newest first; `cursor` continues a page. */
  audit(
    org: string,
    cursor?: string | null,
    signal?: AbortSignal
  ): Promise<BftAuditPage>;
  members(org: string, signal?: AbortSignal): Promise<BftMembers>;
  inviteMember(
    org: string,
    invite: { email: string; role: BftOrgRole }
  ): Promise<BftMembers>;
  changeMemberRole(org: string, userId: string, role: BftOrgRole): Promise<BftMembers>;
  removeMember(org: string, userId: string): Promise<BftMembers>;
  /** One page of 25 runners; `cursor` continues a page. */
  runners(
    org: string,
    cursor?: string | null,
    signal?: AbortSignal
  ): Promise<BftRunnersPage>;
  runnerConnectors(
    org: string,
    runnerId: string,
    cursor?: string | null,
    signal?: AbortSignal
  ): Promise<BftRunnerConnectors>;
  runnerOnboarding(org: string, signal?: AbortSignal): Promise<BftRunnerOnboarding>;
  createInstallCommand(org: string): Promise<BftInstallCommand>;
  /** Revokes the key and returns an install command bound to the same runner. */
  rotateRunnerKey(org: string, keyId: string): Promise<BftInstallCommand>;
  revokeRunnerKey(org: string, keyId: string): Promise<{ id: string }>;
  removeRunner(org: string, runnerId: string): Promise<{ id: string }>;
  settingsGeneral(org: string, signal?: AbortSignal): Promise<BftSettingsGeneral>;
  updateSettingsGeneral(
    org: string,
    changes: Partial<BftSettingsGeneral["organization"]>
  ): Promise<BftSettingsGeneral>;
  revokeCliSession(org: string, sessionId: string): Promise<BftCli>;
  settingsModels(org: string, signal?: AbortSignal): Promise<BftSettingsModels>;
  /**
   * `[]` allows the whole catalog; a `null` default follows the platform.
   * An absent field keeps its value.
   */
  updateSettingsModels(
    org: string,
    models: {
      allowed_models?: BftModelChoice[];
      default_router_model?: BftModelChoice | null;
      default_task_model?: BftModelChoice | null;
    }
  ): Promise<BftSettingsModels>;
  /** One page of 25 accounts; `cursor` continues a page. */
  modelAccounts(
    org: string,
    cursor: string | null,
    signal?: AbortSignal
  ): Promise<BftAccountsPage>;
  /**
   * Account writes. Each returns the refreshed page at `cursor`: a Provider
   * API key or an imported credential file, then a change to one account.
   */
  createModelAccount(
    org: string,
    account: Record<string, unknown>,
    cursor: string | null
  ): Promise<BftAccountsPage>;
  updateModelAccount(
    org: string,
    id: string,
    changes: Record<string, unknown>,
    cursor: string | null
  ): Promise<BftAccountsPage>;
  deleteModelAccount(
    org: string,
    account: { id: string; version: string },
    cursor: string | null
  ): Promise<BftAccountsPage>;
  refreshAccountQuota(
    org: string,
    id: string,
    cursor: string | null
  ): Promise<BftAccountsPage>;
  resetAccountQuota(
    org: string,
    account: { id: string; version: string },
    requestId: string
  ): Promise<BftResetResult>;
  accountUsage(
    org: string,
    id: string,
    cursor: number | null,
    signal?: AbortSignal
  ): Promise<BftAccountUsage>;
  /** Codex answers with a device code, Claude with a link and a callback. */
  beginAccountOAuth(
    org: string,
    target: { provider: BftSubscriptionProvider; account_id?: string; version?: string }
  ): Promise<BftOAuthAttempt>;
  /** An empty `code` polls a device authorization. */
  completeAccountOAuth(
    org: string,
    attemptId: string,
    code: string
  ): Promise<BftOAuthResult>;
  settingsSso(org: string, signal?: AbortSignal): Promise<BftSettingsSso>;
  updateSettingsSso(
    org: string,
    connection: Record<string, unknown>
  ): Promise<BftSettingsSso>;
  runSsoChecks(org: string): Promise<BftSsoChecks>;
  settingsIntegrations(
    org: string,
    signal?: AbortSignal
  ): Promise<BftSettingsIntegrations>;
  saveOAuthApp(
    org: string,
    provider: string,
    app: { client_id: string; client_secret: string }
  ): Promise<BftOAuthSection>;
  deleteOAuthApp(org: string, provider: string): Promise<BftOAuthSection>;
  saveComposio(
    org: string,
    settings: { api_key: string; base_url: string; enabled: boolean }
  ): Promise<BftComposioSection>;
  deleteComposio(org: string): Promise<BftComposioSection>;
  /** A blank number returns to the platform number. */
  saveSignal(org: string, number: string): Promise<BftSignalSection>;
  /** Creates an app when `id` is null. */
  saveFeishuApp(
    org: string,
    id: string | null,
    app: Record<string, unknown>
  ): Promise<BftFeishuSection>;
  deleteFeishuApp(org: string, id: string): Promise<BftFeishuSection>;
  /** A CLI device-login request by its user code, and the orgs it may be granted. */
  cliLogin(code: string, signal?: AbortSignal): Promise<BftCliLogin>;
  approveCliLogin(code: string, orgIds: string[]): Promise<BftCliLogin>;
  denyCliLogin(code: string): Promise<BftCliLogin>;
  /** The first-run wizard; reading it creates the user's own Agent Swarm if needed. */
  wizard(signal?: AbortSignal): Promise<BftWizard>;
  wizardIntegrations(signal?: AbortSignal): Promise<BftWizardIntegrations>;
  /** Saves the grants and moves on to the profile step. */
  saveWizardCapabilities(capabilities: Record<string, boolean>): Promise<BftWizard>;
  /** Captures the profile and moves on to the integrations step. */
  saveWizardProfile(): Promise<BftWizard>;
  /** The Composio Connect Link for one toolkit. */
  connectWizardToolkit(toolkit: string): Promise<{ redirect_url: string }>;
  completeWizard(): Promise<BftWizardFinish>;
  skipWizard(): Promise<BftWizardFinish>;
}

export const apiBasePath = "/dashboard/api/v1";

const orgPath = (org: string) => `/orgs/${encodeURIComponent(org)}`;
const cliLoginPath = (code: string, rest = "") =>
  `/cli/device-login/${encodeURIComponent(code)}${rest}`;

/** `a=1&b=2` from the set parameters; empty and null ones are left out. */
const searchOf = (params: Record<string, string | null>) =>
  new URLSearchParams(
    Object.entries(params).filter((entry): entry is [string, string] => !!entry[1])
  ).toString();

const withCursor = (path: string, cursor: string | null | undefined) =>
  cursor ? `${path}?cursor=${encodeURIComponent(cursor)}` : path;

type WriteMethod = "POST" | "PUT" | "PATCH" | "DELETE";

/**
 * A request with a body. `changes` says whether its successful answer changed
 * server data (the default) — false for POSTs that only read.
 */
interface Write<T> {
  method: WriteMethod;
  idempotencyKey?: string;
  body?: unknown;
  changes?: boolean | ((data: T) => boolean);
}

export function createBftApi(options: BftApiOptions = {}): BftApi {
  const fetchImpl = options.fetch ?? ((...args) => globalThis.fetch(...args));
  const assignLocation =
    options.assignLocation ?? ((href: string) => window.location.assign(href));
  const readCsrfToken = options.csrfToken ?? (() => csrfToken());

  const writeListeners = new Set<() => void>();

  async function request<T>(
    path: string,
    schema: z.ZodType<T>,
    signal: AbortSignal | undefined,
    write?: Write<T>
  ): Promise<T> {
    const data = await exchange(path, schema, signal, write);
    const changes = write?.changes ?? true;
    if (write && (typeof changes === "function" ? changes(data) : changes)) {
      for (const listener of writeListeners) listener();
    }
    return data;
  }

  async function exchange<T>(
    path: string,
    schema: z.ZodType<T>,
    signal: AbortSignal | undefined,
    write: { method: WriteMethod; body?: unknown; idempotencyKey?: string } | undefined
  ): Promise<T> {
    const init: RequestInit = {
      credentials: "same-origin",
      ...(signal ? { signal } : {}),
      ...(write
        ? {
            method: write.method,
            headers: {
              ...writeHeaders(readCsrfToken(), write.body !== undefined),
              ...(write.idempotencyKey
                ? { "idempotency-key": write.idempotencyKey }
                : {}),
            },
            ...(write.body !== undefined ? { body: JSON.stringify(write.body) } : {}),
          }
        : { headers: { accept: "application/json" } }),
    };
    const response = await fetchImpl(`${apiBasePath}${path}`, init);

    if (response.status === 401) {
      assignLocation("/login");
      throw new BftUnauthenticatedError();
    }

    const body: unknown = await response.json().catch(() => undefined);
    const parsed = errorEnvelopeSchema.safeParse(body);

    if (response.status === 404) {
      throw parsed.success
        ? new BftNotFoundError(parsed.data.error.code, parsed.data.error.message)
        : new BftNotFoundError();
    }
    if (!response.ok) {
      if (parsed.success) {
        const { code, message, details } = parsed.data.error;
        throw new BftApiError(
          response.status,
          message,
          code,
          fieldErrors(details?.fields, message)
        );
      }
      // Only Plug's CSRF check answers a dashboard write with a bare 403.
      throw new BftApiError(
        response.status,
        `HTTP ${response.status}`,
        write && response.status === 403 ? csrfRejectedCode : undefined
      );
    }

    const envelope = z.object({ ok: z.literal(true), data: schema }).safeParse(body);
    if (!envelope.success) {
      throw new BftApiError(
        response.status,
        `Unexpected response from ${path}: ${envelope.error.message}`,
        "invalid_response"
      );
    }
    return envelope.data.data;
  }

  const getJson = <T>(path: string, schema: z.ZodType<T>, signal?: AbortSignal) =>
    request(path, schema, signal);
  const send = <T>(
    method: WriteMethod,
    path: string,
    schema: z.ZodType<T>,
    body?: unknown,
    changes: boolean | ((data: T) => boolean) = true
  ) => request(path, schema, undefined, { method, body, changes });

  const swarmPath = (org: string, project: string, rest: string) =>
    `${orgPath(org)}/projects/${encodeURIComponent(project)}${rest}`;
  const taskPath = (org: string, project: string, task: string, rest = "") =>
    swarmPath(org, project, `/tasks/${encodeURIComponent(task)}${rest}`);
  const agentPath = (org: string, project: string, agentId: string, rest = "") =>
    swarmPath(org, project, `/agents/${encodeURIComponent(agentId)}${rest}`);
  const pluginPath = (org: string, project: string, pluginId: string, rest = "") =>
    swarmPath(org, project, `/plugins/${encodeURIComponent(pluginId)}${rest}`);
  const connectionsPath = (org: string, project: string, rest = "") =>
    swarmPath(org, project, `/connections${rest}`);
  const meetingsPath = (org: string, project: string, rest = "") =>
    `${orgPath(org)}/meetings/${encodeURIComponent(project)}${rest}`;
  const triagePath = (
    org: string,
    rest = "",
    params: Record<string, string | null> = {}
  ) => {
    const search = searchOf(params);
    return `${orgPath(org)}/triage${rest}${search ? `?${search}` : ""}`;
  };
  const dataPolicyPath = (org: string, project: string, rest = "") =>
    `${orgPath(org)}/data-policy/${encodeURIComponent(project)}${rest}`;
  const membersPath = (org: string, userId?: string) =>
    `${orgPath(org)}/members${userId === undefined ? "" : `/${encodeURIComponent(userId)}`}`;
  const runnersPath = (org: string, rest = "") => `${orgPath(org)}/runners${rest}`;
  const settingsPath = (org: string, rest: string) => `${orgPath(org)}/settings${rest}`;
  const integrationsPath = (org: string, rest = "") =>
    settingsPath(org, `/integrations${rest}`);
  const oauthPath = (org: string, provider: string) =>
    integrationsPath(org, `/oauth/${encodeURIComponent(provider)}`);
  const feishuPath = (org: string, rest: string) =>
    integrationsPath(org, `/feishu${rest}`);
  const feishuAppPath = (org: string, id: string) =>
    feishuPath(org, `/apps/${encodeURIComponent(id)}`);
  const modelsPath = (org: string, rest: string) => settingsPath(org, `/models${rest}`);
  const accountPath = (org: string, id: string, rest = "") =>
    modelsPath(org, `/accounts/${encodeURIComponent(id)}${rest}`);

  return {
    onWrite: (listener) => {
      writeListeners.add(listener);
      return () => writeListeners.delete(listener);
    },
    session: (signal) => getJson("/session", sessionSchema, signal),
    orgContext: (org, signal) =>
      getJson(`${orgPath(org)}/context`, orgContextSchema, signal),
    overview: (org, signal) =>
      getJson(`${orgPath(org)}/overview`, overviewSchema, signal),
    onboarding: (org, signal) =>
      getJson(`${orgPath(org)}/onboarding`, onboardingSchema, signal),
    dismissOnboarding: (org) =>
      send("POST", `${orgPath(org)}/onboarding/dismiss`, onboardingSchema),
    remindOnboardingAdmins: (org) =>
      send("POST", `${orgPath(org)}/onboarding/remind-admins`, onboardingSchema),
    projectOverview: (org, project, signal) =>
      getJson(swarmPath(org, project, "/overview"), projectOverviewSchema, signal),
    swarms: (org, query, cursor, signal) => {
      const params = new URLSearchParams();
      if (query.trim()) params.set("query", query.trim());
      if (cursor) params.set("cursor", cursor);
      const search = params.size > 0 ? `?${params.toString()}` : "";
      return getJson(`${orgPath(org)}/projects${search}`, swarmsPageSchema, signal);
    },
    createSwarm: (org, swarm) =>
      send("POST", `${orgPath(org)}/projects`, swarmSchema, swarm),
    swarmAgents: (org, project, signal) =>
      getJson(swarmPath(org, project, "/agents"), swarmAgentsSchema, signal),
    swarmAgent: (org, project, agentId, signal) =>
      getJson(agentPath(org, project, agentId), swarmAgentSchema, signal),
    agentConfig: (org, project, agentId, signal) =>
      getJson(agentPath(org, project, agentId, "/config"), agentConfigSchema, signal),
    configureAgent: (org, project, agentId, config) =>
      send("PATCH", agentPath(org, project, agentId), swarmAgentWriteSchema, config),
    agentTargets: (org, project, signal) =>
      getJson(swarmPath(org, project, "/agents/targets"), agentTargetsSchema, signal),
    switchRouterSession: (org, project, agentId, expectedSessionId) =>
      send(
        "POST",
        agentPath(org, project, agentId, "/router-session"),
        switchedSessionSchema,
        { expected_session_id: expectedSessionId }
      ),
    swarmDevices: (org, project, signal) =>
      getJson(swarmPath(org, project, "/devices"), swarmDevicesSchema, signal),
    deviceProvisioning: (org, project, signal) =>
      getJson(
        swarmPath(org, project, "/devices/provisioning"),
        deviceProvisioningSchema,
        signal
      ),
    deviceRunners: (org, project, signal) =>
      getJson(swarmPath(org, project, "/devices/runners"), deviceRunnersSchema, signal),
    createDevice: (org, project, device) =>
      send("POST", swarmPath(org, project, "/devices"), noticeSchema, device),
    setCloudComputer: (org, project, enabled) =>
      send("PUT", swarmPath(org, project, "/devices/cloud"), cloudComputerSchema, {
        enabled,
      }),
    chooseCloudVmRunner: (org, project, choice) =>
      send(
        "PUT",
        swarmPath(org, project, "/devices/cloud-vm/runner"),
        noticeSchema,
        choice
      ),
    removeCloudVmRunner: (org, project) =>
      send("DELETE", swarmPath(org, project, "/devices/cloud-vm/runner"), noticeSchema),
    disconnectDevice: (org, project, deviceId) =>
      send(
        "POST",
        swarmPath(org, project, `/devices/${encodeURIComponent(deviceId)}/disconnect`),
        noticeSchema
      ),
    deleteDevice: (org, project, deviceId) =>
      send(
        "DELETE",
        swarmPath(org, project, `/devices/${encodeURIComponent(deviceId)}`),
        noticeSchema
      ),
    createComputeInstallCommand: (org, project, requestId) =>
      request(
        swarmPath(org, project, "/compute-nodes/agent-vmm/install-commands"),
        computeInstallCommandSchema,
        undefined,
        { method: "POST", body: {}, idempotencyKey: requestId }
      ),
    createShellWorkload: (org, project, environmentId) =>
      send(
        "POST",
        swarmPath(org, project, `/compute/${encodeURIComponent(environmentId)}/shell`),
        noticeSchema
      ),
    setEnvironmentIntent: (org, project, environmentId, intent, expectedRevision) =>
      send(
        "POST",
        swarmPath(
          org,
          project,
          `/compute/${encodeURIComponent(environmentId)}/${intent}`
        ),
        noticeSchema,
        { expected_revision: expectedRevision }
      ),
    swarmTasks: (org, project, cursor, signal) =>
      getJson(
        withCursor(swarmPath(org, project, "/tasks"), cursor),
        swarmTasksSchema,
        signal
      ),
    taskTargets: (org, project, signal) =>
      getJson(swarmPath(org, project, "/tasks/targets"), taskTargetsSchema, signal),
    createTask: (org, project, task) =>
      send("POST", swarmPath(org, project, "/tasks"), createdTaskSchema, task),
    swarmSchedules: (org, project, signal) =>
      getJson(swarmPath(org, project, "/schedules"), swarmSchedulesSchema, signal),
    deleteSchedule: (org, project, scheduleId) =>
      send(
        "DELETE",
        swarmPath(org, project, `/schedules/${encodeURIComponent(scheduleId)}`),
        swarmSchedulesSchema
      ),
    swarmTask: (org, project, task, signal) =>
      getJson(taskPath(org, project, task), swarmTaskSchema, signal),
    taskMessages: (org, project, task, cursor, signal) => {
      const search = cursor
        ? `?${new URLSearchParams(cursor as Record<string, string>).toString()}`
        : "";
      return getJson(
        taskPath(org, project, task, `/messages${search}`),
        taskMessagesSchema,
        signal
      );
    },
    sendTaskMessage: (org, project, task, message) =>
      send(
        "POST",
        taskPath(org, project, task, "/messages"),
        sentTaskMessageSchema,
        message
      ),
    acceptTaskReview: (org, project, task, reviewVersion) =>
      send("POST", taskPath(org, project, task, "/review"), taskReviewReplySchema, {
        review_version: reviewVersion,
      }),
    saveTaskSchedule: (org, project, task, form) =>
      send(
        "PUT",
        taskPath(org, project, task, "/schedule"),
        taskScheduleReplySchema,
        form
      ),
    deleteTaskSchedule: (org, project, task) =>
      send(
        "DELETE",
        taskPath(org, project, task, "/schedule"),
        taskScheduleReplySchema
      ),
    previewTaskSchedule: (org, project, task, form, signal) =>
      getJson(
        taskPath(
          org,
          project,
          task,
          `/schedule/preview?${new URLSearchParams(form).toString()}`
        ),
        schedulePreviewSchema,
        signal
      ),
    swarmWebsites: (org, project, signal) =>
      getJson(swarmPath(org, project, "/websites"), swarmWebsitesSchema, signal),
    swarmSettings: (org, project, signal) =>
      getJson(swarmPath(org, project, "/settings"), swarmSettingsSchema, signal),
    renameSwarm: (org, project, name) =>
      send("PATCH", swarmPath(org, project, "/settings"), swarmSettingsSchema, {
        name,
      }),
    setSwarmTaskModel: (org, project, model) =>
      send(
        "PUT",
        swarmPath(org, project, "/settings/task-model"),
        swarmSettingsSchema,
        {
          model,
        }
      ),
    clearSwarmTaskModel: (org, project) =>
      send(
        "DELETE",
        swarmPath(org, project, "/settings/task-model"),
        swarmSettingsSchema
      ),
    setSwarmTaskPlace: (org, project, place) =>
      send(
        "PUT",
        swarmPath(org, project, "/settings/task-place"),
        swarmSettingsSchema,
        {
          place,
        }
      ),
    archiveSwarm: (org, project) =>
      send("POST", swarmPath(org, project, "/archive"), archivedSwarmSchema),
    swarmAccess: (org, project, cursor) =>
      getJson(
        withCursor(swarmPath(org, project, "/access"), cursor),
        swarmAccessPageSchema
      ),
    grantSwarmAccess: (org, project, grant) =>
      send("POST", swarmPath(org, project, "/access"), swarmAccessWriteSchema, grant),
    changeSwarmAccess: (org, project, userId, role) =>
      send(
        "PATCH",
        swarmPath(org, project, `/access/${encodeURIComponent(userId)}`),
        swarmAccessWriteSchema,
        { role }
      ),
    removeSwarmAccess: (org, project, userId) =>
      send(
        "DELETE",
        swarmPath(org, project, `/access/${encodeURIComponent(userId)}`),
        swarmAccessWriteSchema
      ),
    swarmPlugins: (org, project, signal) =>
      getJson(swarmPath(org, project, "/plugins"), swarmPluginsSchema, signal),
    swarmPlugin: (org, project, pluginId, signal) =>
      getJson(pluginPath(org, project, pluginId), swarmPluginDetailSchema, signal),
    setSwarmPluginEnabled: (org, project, pluginId, enabled) =>
      send("PUT", pluginPath(org, project, pluginId, "/enablement"), noticeSchema, {
        enabled,
      }),
    saveSwarmPlugin: (org, project, id, plugin) =>
      id === null
        ? send("POST", swarmPath(org, project, "/plugins"), noticeSchema, plugin)
        : send("PUT", pluginPath(org, project, id), noticeSchema, plugin),
    connectPlugin: (org, project, pluginId, connectionId, configValues) =>
      send(
        "POST",
        pluginPath(
          org,
          project,
          pluginId,
          `/connections/${encodeURIComponent(connectionId)}/connect`
        ),
        connectionStartSchema,
        configValues ? { config_values: configValues } : undefined
      ),
    disconnectPlugin: (org, project, pluginId, connectionId) =>
      send(
        "POST",
        pluginPath(
          org,
          project,
          pluginId,
          `/connections/${encodeURIComponent(connectionId)}/disconnect`
        ),
        noticeSchema
      ),
    swarmConnections: (org, project, signal) =>
      getJson(connectionsPath(org, project), swarmConnectionsSchema, signal),
    slackManifest: (org, project, appName, signal) =>
      getJson(
        connectionsPath(
          org,
          project,
          `/slack/manifest${appName.trim() ? `?${searchOf({ app_name: appName })}` : ""}`
        ),
        slackManifestSchema,
        signal
      ).then((data) => data.manifest),
    createFeishuConnect: (org, project, connect) =>
      send("POST", connectionsPath(org, project, "/feishu"), noticeSchema, connect),
    createLarkConnect: (org, project, connect) =>
      send("POST", connectionsPath(org, project, "/lark"), noticeSchema, connect),
    createQqConnect: (org, project, connect) =>
      send("POST", connectionsPath(org, project, "/qq"), noticeSchema, connect),
    updateQqMenu: (org, project, connectId, items) =>
      send(
        "PUT",
        connectionsPath(org, project, `/qq/${encodeURIComponent(connectId)}/menu`),
        noticeSchema,
        { items }
      ),
    createSlackConnect: (org, project, connect) =>
      send("POST", connectionsPath(org, project, "/slack"), noticeSchema, connect),
    setImConnectEnabled: (org, project, connectId, enabled) =>
      send(
        "PUT",
        connectionsPath(
          org,
          project,
          `/im/${encodeURIComponent(connectId)}/enablement`
        ),
        noticeSchema,
        { enabled }
      ),
    deleteImConnect: (org, project, connectId) =>
      send(
        "DELETE",
        connectionsPath(org, project, `/im/${encodeURIComponent(connectId)}`),
        noticeSchema
      ),
    runFeishuChecks: (org, project) =>
      send("POST", connectionsPath(org, project, "/feishu/checks"), runChecksSchema),
    runLarkChecks: (org, project, connectId) =>
      send(
        "POST",
        connectionsPath(org, project, `/lark/${encodeURIComponent(connectId)}/checks`),
        runChecksSchema
      ),
    runSlackChecks: (org, project, connectId) =>
      send(
        "POST",
        connectionsPath(org, project, `/slack/${encodeURIComponent(connectId)}/checks`),
        runChecksSchema
      ),
    // A code changes nothing the page reads until someone redeems it on Signal.
    createSignalClaim: (org, project) =>
      send(
        "POST",
        connectionsPath(org, project, "/signal/claims"),
        signalClaimSchema,
        undefined,
        false
      ).then((data) => data.claim),
    removeSignalBinding: (org, project, bindingId) =>
      send(
        "DELETE",
        connectionsPath(
          org,
          project,
          `/signal/bindings/${encodeURIComponent(bindingId)}`
        ),
        noticeSchema
      ),
    connectAccount: (org, project, account) =>
      send(
        "POST",
        connectionsPath(org, project, "/accounts"),
        connectionStartSchema,
        account
      ),
    setAccountEnabled: (org, project, bindingId, enabled) =>
      send(
        "PUT",
        connectionsPath(
          org,
          project,
          `/accounts/${encodeURIComponent(bindingId)}/enablement`
        ),
        noticeSchema,
        { enabled }
      ),
    disconnectAccount: (org, project, bindingId) =>
      send(
        "DELETE",
        connectionsPath(org, project, `/accounts/${encodeURIComponent(bindingId)}`),
        noticeSchema
      ),
    connectComposio: (org, project, toolkit) =>
      send(
        "POST",
        connectionsPath(
          org,
          project,
          `/composio/${encodeURIComponent(toolkit)}/connect`
        ),
        connectionStartSchema
      ),
    disconnectComposio: (org, project, accountId) =>
      send(
        "DELETE",
        connectionsPath(org, project, `/composio/${encodeURIComponent(accountId)}`),
        noticeSchema
      ),
    connectTailnet: (org, project, settings) =>
      send(
        "PUT",
        connectionsPath(org, project, "/tailnet"),
        tailnetWriteSchema,
        settings
      ),
    disconnectTailnet: (org, project) =>
      send("DELETE", connectionsPath(org, project, "/tailnet"), tailnetWriteSchema),
    swarmSkills: (org, project, signal) =>
      getJson(swarmPath(org, project, "/skills"), swarmSkillsSchema, signal),
    swarmSkill: (org, project, skillId, signal) =>
      getJson(
        swarmPath(org, project, `/skills/${encodeURIComponent(skillId)}`),
        swarmSkillDetailSchema,
        signal
      ),
    createSkill: (org, project, skill) =>
      send("POST", swarmPath(org, project, "/skills"), noticeSchema, skill),
    uploadSkill: (org, project, file) =>
      send("POST", swarmPath(org, project, "/skills/upload"), noticeSchema, file),
    deleteSkill: (org, project, skillId) =>
      send(
        "DELETE",
        swarmPath(org, project, `/skills/${encodeURIComponent(skillId)}`),
        noticeSchema
      ),
    plugins: (org, signal) => getJson(`${orgPath(org)}/plugins`, pluginsSchema, signal),
    savePlugin: (org, id, plugin) =>
      id === null
        ? send("POST", `${orgPath(org)}/plugins`, pluginSchema, plugin)
        : send(
            "PUT",
            `${orgPath(org)}/plugins/${encodeURIComponent(id)}`,
            pluginSchema,
            plugin
          ),
    meetings: (org, project, signal) =>
      getJson(meetingsPath(org, project), meetingsOverviewSchema, signal),
    meetingHistory: (org, project, cursor, signal) =>
      getJson(
        withCursor(meetingsPath(org, project, "/history"), cursor),
        meetingHistorySchema,
        signal
      ),
    meetingCatalog: (org, project, connect) =>
      getJson(
        meetingsPath(org, project, `/catalog?${searchOf({ connect_id: connect })}`),
        meetingCatalogSchema
      ),
    meetingChannels: (org, project, connect, cursor) =>
      getJson(
        meetingsPath(
          org,
          project,
          `/channels?${searchOf({ connect_id: connect, cursor })}`
        ),
        meetingChannelsSchema
      ),
    meetingSeries: (org, project, calendar, cursor) =>
      getJson(
        meetingsPath(org, project, `/series?${searchOf({ ...calendar, cursor })}`),
        meetingSeriesSchema
      ),
    meetingReport: (org, project, planId) =>
      getJson(
        meetingsPath(org, project, `/detail?${searchOf({ plan: planId })}`),
        meetingDetailSchema
      ).then((detail) => detail.report),
    saveMeetings: (org, project, draft) =>
      send("PUT", meetingsPath(org, project, "/settings"), z.unknown(), draft),
    dailyBrief: (org, signal) =>
      getJson(`${orgPath(org)}/daily-brief`, dailyBriefSchema, signal),
    saveDailyBrief: (org, settings) =>
      send(
        "PUT",
        `${orgPath(org)}/daily-brief/settings`,
        dailyBriefSavedSchema,
        settings
      ),
    syncDailyBriefMembers: (org) =>
      send("POST", `${orgPath(org)}/daily-brief/members/sync`, dailyBriefSyncSchema),
    requestDailyBrief: (org, member) =>
      send(
        "POST",
        `${orgPath(org)}/daily-brief/members/${encodeURIComponent(member)}/send`,
        dailyBriefRequestSchema
      ),
    triage: (org, signal) => getJson(triagePath(org), triageOverviewSchema, signal),
    triageEvaluation: (org, agent, refresh, signal) =>
      getJson(
        triagePath(org, "/evaluation", { agent, refresh: refresh ? "1" : null }),
        triageEvaluationSchema,
        signal
      ),
    triageChannels: (org, agent, connect, cursor) =>
      getJson(
        triagePath(org, "/channels", { agent, connect, cursor }),
        triageChannelsSchema
      ),
    setTriageSource: (org, agent, connect, enabled) =>
      send(
        "PUT",
        triagePath(org, `/sources/${encodeURIComponent(connect)}`),
        triageNoticeSchema,
        {
          agent,
          enabled,
        }
      ).then((data) => data.notice),
    setTriageChannel: (org, agent, connect, channel, enabled) =>
      send(
        "PUT",
        triagePath(
          org,
          `/sources/${encodeURIComponent(connect)}/channels/${encodeURIComponent(channel)}`
        ),
        triageNoticeSchema,
        { agent, enabled }
      ).then((data) => data.notice),
    addTriageChannels: (org, agent, connect, channelIds) =>
      send(
        "POST",
        triagePath(org, `/sources/${encodeURIComponent(connect)}/channels`),
        triageNoticeSchema,
        { agent, channel_ids: channelIds }
      ).then((data) => data.notice),
    triageTaskSettings: (org, agent, signal) =>
      getJson(triagePath(org, "/worker", { agent }), triageTaskSettingsSchema, signal),
    triageActivity: (org, agent, nav, signal) =>
      getJson(
        triagePath(org, "/activity", {
          agent,
          kind: nav.kind,
          channel: nav.channel,
          before: nav.before === null ? null : String(nav.before),
          cursor: nav.cursor,
        }),
        triageActivitySchema,
        signal
      ),
    revealTriageText: (org, agent, refs, nav) =>
      send(
        "POST",
        triagePath(org, "/reveal"),
        triageRevealSchema,
        { agent, refs, ...(nav ? { activity: nav } : {}) },
        false
      ).then((data) => data.messages),
    triageHeatmap: (org, agent, signal) =>
      getJson(triagePath(org, "/heatmap", { agent }), triageHeatmapSchema, signal),
    triageProcessing: (org, agent, ref, signal) =>
      getJson(
        triagePath(org, "/processing", { agent, ref }),
        triageProcessingDetailSchema,
        signal
      ),
    triageDelegation: (org, agent, obligation, index) =>
      getJson(
        triagePath(org, "/delegation", { agent, obligation, index: String(index) }),
        triageDelegationSchema
      ),
    triageKnowledge: (org, agent, signal) =>
      getJson(triagePath(org, "/knowledge", { agent }), triageKnowledgeSchema, signal),
    dataPolicy: (org, project, signal) =>
      getJson(dataPolicyPath(org, project), dataPolicySchema, signal),
    changeDataPolicy: (org, project, change) => {
      const connect = (rest: string) =>
        "connect" in change
          ? dataPolicyPath(
              org,
              project,
              `/connects/${encodeURIComponent(change.connect)}${rest}`
            )
          : "";
      const segment = encodeURIComponent;
      switch (change.kind) {
        case "group":
          return send("PATCH", dataPolicyPath(org, project), dataPolicySchema, {
            mode: change.mode,
            language: change.language,
          });
        case "classify":
          return send(
            "PUT",
            connect(`/scopes/${segment(change.scope)}`),
            dataPolicySchema,
            {
              tags: change.tags,
              audience_mode: change.audience_mode,
              sealed: change.sealed,
            }
          );
        case "reset":
          return send(
            "DELETE",
            connect(`/scopes/${segment(change.scope)}`),
            dataPolicySchema
          );
        case "grant":
          return send("POST", connect("/clearances"), dataPolicySchema, {
            tag: change.tag,
            user: change.user,
          });
        case "withdraw":
          // In the body: a tag such as `.` or `..` does not survive as a path segment.
          return send("DELETE", connect("/clearances"), dataPolicySchema, {
            tag: change.tag,
            principal: change.principal,
          });
        case "place":
          return send(
            "PUT",
            connect(`/placements/${segment(change.user)}`),
            dataPolicySchema,
            {
              placement: change.placement,
            }
          );
      }
    },
    health: (org, signal) => getJson(`${orgPath(org)}/health`, healthSchema, signal),
    audit: (org, cursor, signal) =>
      getJson(withCursor(`${orgPath(org)}/audit`, cursor), auditPageSchema, signal),
    members: (org, signal) => getJson(membersPath(org), membersSchema, signal),
    inviteMember: (org, invite) =>
      send("POST", membersPath(org), membersSchema, invite),
    changeMemberRole: (org, userId, role) =>
      send("PATCH", membersPath(org, userId), membersSchema, { role }),
    removeMember: (org, userId) =>
      send("DELETE", membersPath(org, userId), membersSchema),
    runners: (org, cursor, signal) =>
      getJson(withCursor(runnersPath(org), cursor), runnersPageSchema, signal),
    runnerConnectors: (org, runnerId, cursor, signal) =>
      getJson(
        withCursor(
          runnersPath(org, `/${encodeURIComponent(runnerId)}/connectors`),
          cursor
        ),
        runnerConnectorsSchema,
        signal
      ),
    runnerOnboarding: (org, signal) =>
      getJson(runnersPath(org, "/onboarding"), runnerOnboardingSchema, signal),
    createInstallCommand: (org) =>
      send("POST", runnersPath(org, "/install-commands"), installCommandSchema),
    rotateRunnerKey: (org, keyId) =>
      send(
        "POST",
        runnersPath(org, `/keys/${encodeURIComponent(keyId)}/rotate`),
        installCommandSchema
      ),
    revokeRunnerKey: (org, keyId) =>
      send(
        "DELETE",
        runnersPath(org, `/keys/${encodeURIComponent(keyId)}`),
        revokedKeySchema
      ),
    removeRunner: (org, runnerId) =>
      send(
        "DELETE",
        runnersPath(org, `/${encodeURIComponent(runnerId)}`),
        removedRunnerSchema
      ),
    settingsGeneral: (org, signal) =>
      getJson(settingsPath(org, "/general"), settingsGeneralSchema, signal),
    updateSettingsGeneral: (org, changes) =>
      send("PATCH", settingsPath(org, "/general"), settingsGeneralSchema, changes),
    revokeCliSession: (org, sessionId) =>
      send(
        "DELETE",
        settingsPath(org, `/cli-sessions/${encodeURIComponent(sessionId)}`),
        cliSchema
      ),
    settingsModels: (org, signal) =>
      getJson(settingsPath(org, "/models"), settingsModelsSchema, signal),
    updateSettingsModels: (org, models) =>
      send("PUT", settingsPath(org, "/models"), settingsModelsSchema, models),
    settingsSso: (org, signal) =>
      getJson(settingsPath(org, "/sso"), settingsSsoSchema, signal),
    updateSettingsSso: (org, connection) =>
      send("PUT", settingsPath(org, "/sso"), settingsSsoSchema, connection),
    runSsoChecks: (org) =>
      send("POST", settingsPath(org, "/sso/checks"), ssoChecksSchema),
    settingsIntegrations: (org, signal) =>
      getJson(integrationsPath(org), settingsIntegrationsSchema, signal),
    saveOAuthApp: (org, provider, app) =>
      send("PUT", oauthPath(org, provider), oauthSectionSchema, app),
    deleteOAuthApp: (org, provider) =>
      send("DELETE", oauthPath(org, provider), oauthSectionSchema),
    saveComposio: (org, settings) =>
      send("PUT", integrationsPath(org, "/composio"), composioSectionSchema, settings),
    deleteComposio: (org) =>
      send("DELETE", integrationsPath(org, "/composio"), composioSectionSchema),
    saveSignal: (org, number) =>
      send("PUT", integrationsPath(org, "/signal"), signalSectionSchema, { number }),
    saveFeishuApp: (org, id, app) =>
      id === null
        ? send("POST", feishuPath(org, "/apps"), feishuSectionSchema, app)
        : send("PUT", feishuAppPath(org, id), feishuSectionSchema, app),
    deleteFeishuApp: (org, id) =>
      send("DELETE", feishuAppPath(org, id), feishuSectionSchema),
    modelAccounts: (org, cursor, signal) =>
      getJson(
        withCursor(modelsPath(org, "/accounts"), cursor),
        accountsPageSchema,
        signal
      ),
    createModelAccount: (org, account, cursor) =>
      send("POST", modelsPath(org, "/accounts"), accountsPageSchema, {
        ...account,
        cursor,
      }),
    updateModelAccount: (org, id, changes, cursor) =>
      send("PATCH", accountPath(org, id), accountsPageSchema, { ...changes, cursor }),
    deleteModelAccount: (org, account, cursor) =>
      send("DELETE", accountPath(org, account.id), accountsPageSchema, {
        version: account.version,
        cursor,
      }),
    refreshAccountQuota: (org, id, cursor) =>
      send("POST", accountPath(org, id, "/quota"), accountsPageSchema, { cursor }),
    resetAccountQuota: (org, account, requestId) =>
      send("POST", accountPath(org, account.id, "/reset"), resetResultSchema, {
        version: account.version,
        request_id: requestId,
      }),
    accountUsage: (org, id, cursor, signal) =>
      getJson(
        withCursor(
          accountPath(org, id, "/usage"),
          cursor === null ? null : String(cursor)
        ),
        accountUsageSchema,
        signal
      ),
    beginAccountOAuth: (org, target) =>
      send("POST", modelsPath(org, "/accounts/oauth"), oauthAttemptSchema, target),
    completeAccountOAuth: (org, attemptId, code) =>
      send(
        "POST",
        modelsPath(org, `/accounts/oauth/${encodeURIComponent(attemptId)}/complete`),
        oauthResultSchema,
        { code },
        // A device poll that is still pending changed nothing.
        (result) => result.status === "connected"
      ),
    cliLogin: (code, signal) => getJson(cliLoginPath(code), cliLoginSchema, signal),
    approveCliLogin: (code, orgIds) =>
      send("POST", cliLoginPath(code, "/approve"), cliLoginSchema, { org_ids: orgIds }),
    denyCliLogin: (code) => send("POST", cliLoginPath(code, "/deny"), cliLoginSchema),
    wizard: (signal) => getJson("/onboarding", wizardSchema, signal),
    wizardIntegrations: (signal) =>
      getJson("/onboarding/integrations", wizardIntegrationsSchema, signal),
    saveWizardCapabilities: (capabilities) =>
      send("PUT", "/onboarding/capabilities", wizardSchema, { capabilities }),
    saveWizardProfile: () => send("POST", "/onboarding/profile", wizardSchema),
    connectWizardToolkit: (toolkit) =>
      send(
        "POST",
        "/onboarding/connect",
        z.object({ redirect_url: z.string() }),
        { toolkit },
        false
      ),
    completeWizard: () => send("POST", "/onboarding/complete", wizardFinishSchema),
    skipWizard: () => send("POST", "/onboarding/skip", wizardFinishSchema),
  };
}
