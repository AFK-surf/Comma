// The Comma API's answers the core reads, as it checks them. Only what the core keeps or acts on is declared; the rest
// of an answer is dropped here.
import { z } from "zod";
import { taskLoop } from "./task-loop.ts";

export function pageSchema<T extends z.ZodType>(item: T) {
  return z
    .object({
      data: z.array(item),
      has_more: z.boolean().optional(),
      next_cursor: z.string().nullable().optional(),
    })
    .passthrough();
}

export const workspaceSchema = z
  .object({
    group_id: z.string(),
    id: z.string(),
    name: z.string(),
    owner_user_id: z.string().optional(),
    billing_account_id: z.string().optional(),
    status: z.enum(["provisioning", "ready", "failed"]).optional(),
    created_at: z.number().optional(),
    updated_at: z.number().optional(),
  })
  .strip();

export type Workspace = z.output<typeof workspaceSchema>;

export const workspaceBootstrapSchema = z.discriminatedUnion("status", [
  z.object({ status: z.literal("ready"), workspace: workspaceSchema }).passthrough(),
  z
    .object({
      retry_after_seconds: z.number().int().positive(),
      status: z.literal("provisioning"),
      workspace: workspaceSchema,
    })
    .passthrough(),
]);

const pluginResourceSchema = z.object({ id: z.string(), name: z.string() }).strip();

export const pluginCredentialSetupSchema = z
  .object({
    key: z.string(),
    label: z.string(),
    helpUrl: z.url(),
  })
  .strip();

export const pluginSchema = z
  .object({
    id: z.string(),
    name: z.string(),
    summary: z.string(),
    description: z.string().optional(),
    brand: z.string().nullable().optional(),
    category: z.string(),
    installed: z.boolean(),
    locked: z.boolean(),
    credentialSetup: pluginCredentialSetupSchema.nullable().optional(),
    mcps: z.array(pluginResourceSchema),
    skills: z.array(pluginResourceSchema),
  })
  .strip();

export const pluginAuthorizationSchema = z
  .object({
    authorizationUrl: z.url().optional(),
    state: z.string().min(1),
  })
  .strip();

export const pluginInstallResultSchema = z
  .object({
    plugin: pluginSchema,
    authorization: pluginAuthorizationSchema.nullable(),
    configuration: pluginCredentialSetupSchema.optional(),
  })
  .strip();

export const pluginPersonalSourcesSchema = z.object({
  pluginId: z.string(),
  sources: z.array(
    z.object({
      connectionId: z.string(),
      toolkit: z.string(),
      kind: z.enum(["composio", "managed_oauth", "native_mcp_oauth"]),
      state: z.enum([
        "ready",
        "needs_confirmation",
        "needs_authorization",
        "needs_reauthorization",
      ]),
      selectedAccountId: z.string().nullable().optional(),
      candidates: z.array(z.object({ id: z.string() })),
      mcpIds: z.array(z.string()).optional(),
    })
  ),
});

export const pluginAccountConfirmationSchema = z.object({
  state: z.string().min(1),
  toolkit: z.string(),
  connectionId: z.string(),
  identity: z.string(),
});

export const pluginConfirmedAccountSchema = z.object({
  state: z.literal("ready"),
  toolkit: z.string(),
  connectionId: z.string(),
});

/** A workspace as the task list keeps it. */
export const taskWorkspaceSchema = z
  .object({
    group_id: z.string().min(1).max(256),
    id: z.string().min(1).max(256),
    name: z.string().min(1).max(512),
  })
  .strip();

const meetingPhaseSchema = z.enum([
  "awaiting_recording",
  "recording",
  "paused",
  "saving",
  "processing",
  "saved",
  "dismissed",
  "discarded",
]);

/** A conversation as the task list reads it; what else the server sends is dropped. */
export const taskConversationSchema = z
  .object({
    meeting: z.object({ phase: meetingPhaseSchema }).strip().optional(),
    archive_availability: z
      .object({ allowed: z.boolean(), reason: z.string().nullable() })
      .strip()
      .optional(),
    activity_status: z.string().max(256).optional(),
    created_at: z.number().finite().optional(),
    freshness: z
      .object({ state: z.enum(["fresh", "stale", "unknown"]) })
      .strip()
      .optional(),
    group_id: z.string().min(1).max(256),
    id: z.string().min(1).max(256),
    kind: z.enum(["user_chat", "agent_task"]),
    origin: z.string().max(256).optional(),
    labels: z.array(z.string()).optional(),
    client_platform: z.string().optional(),
    /** The Message the Task was created from, such as the Home request the Router answered with it. */
    parent_message_id: z.string().max(256).optional(),
    review_version: z.number().int().nonnegative().nullish(),
    /** A Loop Task's Loop, as `taskLoop` reads it. */
    loop: z.unknown().optional(),
    /** When the Task's latest run started (Unix milliseconds). */
    run_started_at: z.number().int().positive().optional(),
    status: z.string().min(1).max(256),
    title: z.string().max(2_048),
    updated_at: z.number().finite().optional(),
  })
  .strip();

export type TaskConversation = z.output<typeof taskConversationSchema>;

export function taskPageSchema<T extends z.ZodType>(item: T) {
  return z
    .object({
      data: z.array(item).max(1_000),
      has_more: z.boolean().optional(),
      next_cursor: z.string().max(2_048).nullable().optional(),
    })
    .strip();
}

/**
 * A Task's facts as its summary, its archive or unarchive, and the archived list answer them; what else the server sends
 * is dropped.
 */
export const taskSummarySchema = z
  .object({
    archive_availability: z
      .object({ allowed: z.boolean(), reason: z.string().nullable() })
      .strip()
      .optional(),
    archived_at: z.number().finite().optional(),
    archived_from_status: z.string().max(256).optional(),
    client_platform: z.string().max(256).optional(),
    group_id: z.string().min(1).max(256),
    id: z.string().min(1).max(256),
    kind: z.enum(["user_chat", "agent_task"]),
    labels: z.array(z.string()).optional(),
    origin: z.string().max(256).optional(),
    loop: z.unknown().transform(taskLoop).optional(),
    run_started_at: z.number().int().positive().optional(),
    status: z.string().min(1).max(256),
    title: z.string().max(2_048),
    updated_at: z.number().finite().optional(),
  })
  .strip();

/** The owner's view of a Task's public link. */
export const taskShareSchema = z
  .object({
    url: z.string().url(),
    created_at: z.number(),
    shared_at: z.number(),
    message_count: z.number().int().nonnegative(),
    artifact_count: z.number().int().nonnegative(),
    has_newer_messages: z.boolean(),
  })
  .strip();

/** A page of a Group's active links, most recently shared first. */
export const taskSharePageSchema = z
  .object({
    data: z
      .array(
        z
          .object({
            conversation: z
              .object({ id: z.string().min(1).max(256), title: z.string().max(2_048) })
              .strip(),
            shared_at: z.number(),
            artifact_count: z.number().int().nonnegative(),
          })
          .strip()
      )
      .max(1_000),
    has_more: z.boolean(),
    next_cursor: z.string().max(2_048).nullable(),
  })
  .strip();

/** A Group's stored Task-board arrangement: bucket → ordered conversation ids. */
export const taskOrderSchema = z
  .object({ orders: z.record(z.string(), z.array(z.string())) })
  .strip();

/** What the list's event stream says: the list changed (`version`), or it must be read again whole. */
/** `GET /v1/comma/groups/:group/station-tasks`: the Tasks the group's stations host, as they last reported them. */
export const stationTasksSchema = z.object({
  tasks: z
    .array(
      z.object({
        station_id: z.string().min(1),
        device_id: z.string().nullable(),
        thread: z.string().min(1),
        task: z.string().nullable(),
        title: z.string().nullable(),
        status: z.string(),
        created_by: z.string().nullable(),
        created_at: z.number().int().nullable(),
        last_activity_at: z.number().int().nullable(),
        runtime: z.string().nullable(),
        model: z.string().nullable(),
        /** The Group's label ids a person set on the station; none from a server before labels. */
        labels: z.array(z.string().max(128)).max(20).default([]),
        rev: z.number().int().nullable(),
      })
    )
    .max(500),
});

export const taskListEventSchema = z.discriminatedUnion("type", [
  // Only on a stream opened with `?with=station_tasks`.
  z.strictObject({
    type: z.literal("station_tasks_invalidated"),
    group_id: z.string().min(1),
  }),
  z.strictObject({
    type: z.literal("conversation_list_resync_required"),
    group_id: z.string().min(1),
    kind: z.literal("agent_task"),
    version: z.string().min(1).max(128),
  }),
  z.strictObject({
    type: z.literal("conversation_list_invalidated"),
    group_id: z.string().min(1),
    kind: z.literal("agent_task"),
    version: z.string().min(1).max(128),
  }),
]);

export const billingPlanSchema = z
  .object({
    plan_key: z.string(),
    package_code: z.string(),
    package_version: z.string(),
    mode: z.enum(["payment", "subscription"]),
    name: z.string(),
    currency: z.string(),
    amount_minor: z.number().int().nonnegative(),
    grant_credits: z.number().int().positive(),
    grant_period: z.string().nullable().optional(),
    billing_period: z.string().nullable().optional(),
  })
  .strip();

export const billingSummarySchema = z
  .object({
    billing_account_id: z.string(),
    current_credits: z
      .union([
        z.number(),
        z
          .string()
          .regex(/^\d+$/)
          .transform((value) => Number(value)),
      ])
      .pipe(z.number().int().nonnegative()),
    active_subscription: z
      .object({
        package_code: z.string(),
        package_version: z.string(),
        status: z.enum(["active", "trialing", "past_due", "unpaid", "paused"]),
        source_id: z.string(),
        plan: billingPlanSchema.nullable().optional(),
        source_metadata: z
          .object({
            cancel_at_period_end: z.boolean().optional(),
            current_period_end: z.number().nullable().optional(),
            scheduled_plan: z
              .object({
                package_code: z.string(),
                package_version: z.string(),
                effective_at: z.number(),
              })
              .nullable()
              .optional(),
          })
          .strip()
          .optional(),
      })
      .strip()
      .nullable()
      .optional(),
    active_grants: z.array(
      z
        .object({
          id: z.string(),
          package_code: z.string().nullable(),
          package_version: z.string().nullable(),
          original_credits: z.number().int().nonnegative().optional(),
          remaining_credits: z.number().int().nonnegative(),
          valid_from: z.string(),
          expires_at: z.string().nullable().optional(),
          source_type: z.string(),
          source_id: z.string().nullable(),
        })
        .strip()
    ),
  })
  .strip();

export const billingSessionSchema = z
  .object({ id: z.string(), provider: z.literal("stripe"), url: z.url() })
  .strip();

export const billingChangePreviewSchema = z
  .object({
    amount_minor: z.number().int(),
    currency: z.string(),
    proration_date: z.number().int(),
    current_price_id: z.string(),
    period_end: z.number().int(),
    effect: z.enum(["upgrade", "downgrade", "keep_current"]),
  })
  .strip();

export const billingChangeSchema = z
  .object({
    id: z.string(),
    provider: z.literal("stripe"),
    effect: z.enum([
      "upgraded",
      "upgrade_failed",
      "payment_required",
      "downgrade_scheduled",
      "kept_current",
      "cancellation_scheduled",
    ]),
    url: z.url().nullable().optional(),
    effective_at: z.number().optional(),
  })
  .strip();

export const redemptionResultSchema = z
  .object({
    idempotent: z.boolean().optional(),
    grant: z
      .object({ remaining_credits: z.number().int().nonnegative() })
      .passthrough()
      .nullable()
      .optional(),
  })
  .passthrough();
export const wechatConnectionSchema = z
  .object({
    connect_id: z.string().min(1),
    status: z.enum(["pending", "prepared", "connected", "error"]),
    login_status: z.enum([
      "wait",
      "scaned",
      "need_verifycode",
      "expired",
      "verify_code_blocked",
      "binded_redirect",
      "confirmed",
    ]),
    connection_active: z.boolean(),
    qrcode_url: z.string().nullable(),
    expires_at: z.number().int(),
    wechat_id: z.string().optional(),
    bot_user_id: z.string().optional(),
    connected_at: z.number().int().optional(),
  })
  .strip();

export const wechatIntegrationSchema = z
  .object({
    connection: wechatConnectionSchema.nullable(),
    pending: wechatConnectionSchema.nullable(),
  })
  .strip();

const signalAccountSchema = z
  .object({
    e164: z.string().nullish(),
    state: z.string().nullish(),
    scope: z.string().nullish(),
  })
  .strip();

export const signalIntegrationSchema = z
  .object({
    /** The account that new connection codes use; null when none is set. */
    account: signalAccountSchema.nullish(),
    bindings: z.array(
      z
        .object({
          binding_id: z.string().min(1),
          kind: z.enum(["user", "group"]),
          peer: z.string().min(1),
          display_name: z.string().nullish(),
          bound_at: z.number().nullish(),
          /** The Signal number the chat talks with. */
          number: z.string().nullish(),
        })
        .strip()
    ),
    pending_claims: z.array(
      z.object({ claim_id: z.string().min(1), expires_at: z.number() }).strip()
    ),
    /** Present only in the response that created a code. */
    claim: z
      .object({
        claim_id: z.string().min(1),
        code: z.string().min(1),
        command: z.string().min(1),
        number: z.string().nullish(),
        expires_at: z.number(),
      })
      .strip()
      .nullish(),
  })
  .strip();

/** A connection attempt: Photon's names the handle that must send the code and the line to send it to. */
const imessageAttemptSchema = z
  .object({
    code: z.string().min(1),
    /** Unix seconds. */
    expires_at: z.number().int(),
    transport: z.enum(["relay", "photon"]).default("relay"),
    sender_handle: z.string().nullish(),
    line_handle: z.string().nullish(),
  })
  .strip();

export const imessageIntegrationSchema = z
  .object({
    /** Photon shared lines are set up on this deployment (the relay transport stays hidden). */
    photon_configured: z.boolean().default(false),
    connection_active: z.boolean(),
    photon_online: z.boolean().default(false),
    pending_claim: imessageAttemptSchema.nullable(),
    link: z
      .object({
        sender_handle: z.string().min(1),
        transport: z.enum(["relay", "photon"]).default("relay"),
        connection_id: z.string().min(1),
        /** Unix seconds. */
        connected_at: z.number().int(),
      })
      .strip()
      .nullable(),
  })
  .strip();

export const signalNumberSchema = z
  .object({
    override: signalAccountSchema.nullish(),
    platform: signalAccountSchema.nullish(),
    effective: signalAccountSchema.nullish(),
  })
  .strip();

export const telegramIntegrationSchema = z
  .object({
    bot_url: z.string().url().nullable(),
    bot_username: z.string().min(1).nullable(),
    configured: z.boolean(),
    link: z
      .object({
        telegram_user_id: z.string().min(1),
        telegram_username: z.string().min(1).nullable(),
        connection_id: z.string().optional(),
        connected_at: z.number().int(),
        updated_at: z.number().int(),
      })
      .strip()
      .nullable(),
    connection_active: z.boolean().optional(),
    official_login_available: z.boolean(),
    workspace_id: z.string().min(1),
    workspace_name: z.string().min(1),
  })
  .strip();

export const telegramConnectAttemptSchema = z
  .object({
    authorization_url: z.string().url(),
    expires_in_seconds: z.number().int().positive(),
    workspace_id: z.string().min(1),
  })
  .strip();

export const telegramDisconnectSchema = z.object({ disconnected: z.boolean() }).strip();

export const linearInstallationSchema = z
  .object({
    id: z.string().min(1),
    organization_id: z.string().min(1),
    organization_name: z.string().nullable(),
    organization_url_key: z.string().nullable(),
    installer: z.boolean(),
    revoked: z.boolean(),
    installed_at: z.string().min(1),
    updated_at: z.string().min(1),
  })
  .strip();

export const linearMemberSchema = z
  .object({
    id: z.string().min(1),
    linear_user_id: z.string().min(1),
    linear_user_name: z.string().nullable(),
    linear_user_email: z.string().nullable(),
    completion_state_policy: z.enum(["unchanged", "in_review", "done"]),
    linked_at: z.string().min(1),
    updated_at: z.string().min(1),
  })
  .strip();

export const linearIntegrationSchema = z
  .object({
    configured: z.boolean(),
    installation: linearInstallationSchema.nullable(),
    member: linearMemberSchema.nullable(),
    completion_state_policies: z.array(z.string()),
    workspace_id: z.string().min(1),
    workspace_name: z.string().min(1),
  })
  .strip();

export const linearConnectAttemptSchema = z
  .object({ authorization_url: z.string().url(), expires_at: z.string().min(1) })
  .strip();

export const linearDisconnectSchema = z.object({ disconnected: z.boolean() }).strip();

const nullableText = z
  .string()
  .nullish()
  .transform((value) => value ?? null);

export const tailnetStatusSchema = z
  .object({
    enabled: z.boolean(),
    state: z
      .enum([
        "disabled",
        "idle",
        "starting",
        "needs_login",
        "needs_approval",
        "running",
        "error",
      ])
      .catch("error"),
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
      .strip()
      .nullish()
      .transform((value) => value ?? null),
    settings: z
      .object({
        tags: z.array(z.string()),
        accept_routes: z.boolean(),
        expected_tailnet: nullableText,
      })
      .strip(),
    updated_at: nullableText,
  })
  .strip();

export const tailnetPeersSchema = z
  .object({
    peers: z.array(
      z
        .object({
          name: z.string(),
          dns_name: nullableText,
          ips: z.array(z.string()).catch([]),
          os: nullableText,
          online: z.boolean().catch(false),
          tags: z.array(z.string()).catch([]),
          routes: z.array(z.string()).catch([]),
        })
        .strip()
    ),
    next: z.number().catch(0),
  })
  .strip();

export const routerKeySchema = z
  .object({
    key_id: z.string().min(1),
    name: z.string(),
    prefix: z.string(),
    status: z.enum(["active", "disabled"]),
    created_by: z.string().optional(),
    created_at: z.number().optional(),
    updated_at: z.number().optional(),
    expires_at: z.number().nullable().optional(),
    last_used_at: z.number().nullable().optional(),
    /** Where an external service posts with this key: the Router endpoint on the public Salix base. */
    post_message_url: z.string().optional(),
  })
  .strip();

export const routerKeyCreatedSchema = routerKeySchema
  .extend({ key: z.string().min(1), post_message_url: z.string().min(1) })
  .strip();

export const taskLabelColorSchema = z.enum([
  "gray",
  "blue",
  "indigo",
  "purple",
  "pink",
  "orange",
  "warning",
  "success",
  "error",
  "brand",
]);

export const taskLabelSchema = z
  .object({
    id: z.string().min(1),
    name: z.string(),
    color: z.string(),
    description: z.string().optional(),
    created_at: z.number().optional(),
    updated_at: z.number().optional(),
  })
  .passthrough();

export const taskLabelProposalSchema = z
  .object({
    id: z.string().min(1),
    op: z.enum(["create", "update", "delete", "apply"]),
    payload: z
      .object({
        labels: z
          .array(
            z.object({
              id: z.string().optional(),
              name: z.string(),
              color: z.string(),
              description: z.string(),
            })
          )
          .optional(),
        conversation_id: z.string().optional(),
        conversation_title: z.string().optional(),
      })
      .catchall(z.unknown()),
    status: z.enum(["pending", "approved", "rejected"]),
    application_status: z.enum(["pending", "applied", "conflict"]).optional(),
    application_error: z.string().optional(),
    summary: z.string().optional(),
    proposed_by: z
      .object({ agent_id: z.string().optional(), session_id: z.string().optional() })
      .passthrough()
      .optional(),
    /** The chat the Router was answering when it proposed; that chat offers the confirmation too. */
    source_conversation_id: z.string().optional(),
    created_at: z.number().optional(),
    resolved_at: z.number().nullable().optional(),
  })
  .passthrough();

export const taskLabelCatalogSchema = z
  .object({
    approval_policy: z.enum(["ask", "auto"]).default("ask"),
    labels: z.array(taskLabelSchema),
    proposals: z.array(taskLabelProposalSchema).default([]),
    colors: z.array(z.string()).default([]),
    updated_at: z.number().optional(),
  })
  .passthrough();

export const condensedWorkspaceSchema = z
  .object({
    enabled: z.boolean(),
    revision: z.number(),
    statements: z.array(z.object({ id: z.string(), text: z.string() })),
    bytes: z.number(),
    recommended_max_bytes: z.number(),
    max_bytes: z.number(),
    removed_ids: z.array(z.string()).optional(),
  })
  .passthrough();

export const voiceKeySchema = z
  .object({
    key_id: z.string().min(1),
    name: z.string(),
    prefix: z.string(),
    status: z.enum(["active", "disabled"]),
    created_by: z.string().optional(),
    created_at: z.number().optional(),
    updated_at: z.number().optional(),
    expires_at: z.number().nullable().optional(),
    last_used_at: z.number().nullable().optional(),
    /** The `comma.voice.v1` WebSocket URL a voice client opens with this key. */
    sessions_url: z.string().optional(),
    /** The readiness URL (`comma-voice check`). */
    readiness_url: z.string().optional(),
  })
  .strip();

export const voiceKeyCreatedSchema = voiceKeySchema
  .extend({ key: z.string().min(1), sessions_url: z.string().min(1) })
  .strip();

export const voiceIntegrationSchema = z
  .object({
    /** The platform numbers a verified caller dials. */
    lines: z.array(z.string()),
    numbers: z.array(
      z
        .object({
          e164: z.string().min(1),
          carrier: z.string().nullish(),
          line: z.string().nullish(),
          verified_at: z.number().nullish(),
          pin_set: z.boolean(),
          pin_locked_until: z.number().nullish(),
          status: z.enum(["verified", "locked"]),
        })
        .strip()
    ),
    readiness: z.object({ ready: z.boolean(), reason: z.string().nullish() }).strip(),
    sessions_url: z.string().nullish(),
    readiness_url: z.string().nullish(),
  })
  .strip();

export const voiceVerificationSchema = z
  .object({ e164: z.string().min(1), line: z.string().nullish(), status: z.string() })
  .strip();

export const deviceSchema = z.object({
  disconnected_at: z.number().nullish(),
  system_info: z
    .object({
      /**
       * Computers use `comma_dev`, `comma_staging`, `comma`, or `connector`.
       * Comma hardware: `t-circle`, `m5stack-sticks3`, `waveshare-amoled-1-32`, or `esp32-devkit`.
       */
      client_source: z.string().optional(),
      hostname: z.string().optional(),
      cpu_model: z.string().optional(),
      memory_total: z.number().optional(),
      os_version: z.string().optional(),
    })
    .optional(),
  device_id: z.string().min(1),
  name: z.string(),
  alias: z.string().nullish(),
  status: z.enum(["connected", "disconnected"]),
  allows_operations: z.boolean(),
  /** The computer's one access value (a server from before says only `allows_operations`). */
  access: z.enum(["off", "read", "full"]).optional(),
  /** The station its Connector proved it runs; absent until one did. */
  station_id: z.string().nullish(),
  /**
   * Whether it takes Tasks: `ready`, `offline`, or why not (`device_needs_station`, `station_outdated`; another reason
   * a later server adds is shown as not ready).
   */
  tasks_readiness: z.string().max(64).optional(),
  /** The models its station's profiles enable, by runtime. */
  task_models: z.record(z.string(), z.array(z.string().max(256)).max(200)).optional(),
  os: z.string().optional(),
  arch: z.string().optional(),
  updated_at: z.number().optional(),
  device_runtimes: z
    .array(
      z.object({
        provider: z.string(),
        device_runtime_id: z.string(),
        readiness_checked_at: z.number().optional(),
        readiness_valid_until: z.number().optional(),
        auth: z
          .object({
            mode: z.string().optional(),
            backend: z.string().optional(),
            status: z.string().optional(),
          })
          .optional(),
        status: z.string().optional(),
        version: z.string().optional(),
        issue: z.string().optional(),
        message: z.string().optional(),
      })
    )
    .default([]),
});

export const computeWorkloadSchema = z.object({
  id: z.string(),
  environment_id: z.string(),
  name: z.string().optional(),
  revision: z.number().int().positive().optional(),
  generation: z.number().int().positive().optional(),
  deletion: z
    .object({
      phase: z.string(),
      request_id: z.string(),
      error: z.string().nullable().optional(),
    })
    .passthrough()
    .nullable()
    .optional(),
  location: z
    .object({
      provider: z.string(),
      registration_id: z.string().optional(),
      allocation_id: z.string().optional(),
    })
    .optional(),
  actions: z
    .object({
      rename: z.boolean(),
      delete: z.boolean().nullable(),
      retry: z.boolean().optional(),
    })
    .optional(),
  uses: z
    .array(
      z.object({
        kind: z.string(),
        id: z.string(),
        label: z.string().optional(),
        relation_id: z.string().optional(),
      })
    )
    .optional(),
  uses_truncated: z.boolean().optional(),
  runtime_policy: z
    .object({
      image: z.string().nullable().optional(),
      entrypoint: z.array(z.string()).nullable().optional(),
      command: z.array(z.string()).nullable().optional(),
      egress_mode: z.string().nullable().optional(),
      resources: z.object({
        pid_max: z.number().optional(),
        writable_quota_bytes: z.number().optional(),
      }),
    })
    .optional(),
  owner: z
    .object({ kind: z.string(), workload_id: z.string(), environment_id: z.string() })
    .nullable()
    .optional(),
  kind: z.string(),
  desired_state: z.string().optional(),
  observed_state: z.string(),
  phase: z
    .enum([
      "stopped",
      "draining",
      "action_required",
      "ready",
      "waiting_connection",
      "allocating",
      "starting",
      "unknown",
      "deleting",
      "deleted",
      "cloud_retired",
    ])
    .optional(),
  phase_observed_at: z.string().optional(),
  updated_at: z.string().optional(),
});
export const computeProjectionSchema = z.object({
  can_manage: z.boolean().optional(),
  workspace_name: z.string().nullable().optional(),
  environments: z.array(
    z.object({
      id: z.string(),
      desired_state: z.string(),
      observed_state: z.string(),
      can_create: z.boolean().optional(),
      create_unavailable_reason: z.string().nullable().optional(),
    })
  ),
  workloads: z.array(computeWorkloadSchema),
  next_workload_cursor: z.string().nullable().optional(),
});

const taskSearchHighlightSchema = z
  .object({
    end: z.number().int().nonnegative(),
    start: z.number().int().nonnegative(),
  })
  .strip();

const taskSearchContentMatchSchema = z
  .object({
    highlights: z.array(taskSearchHighlightSchema),
    snippet: z.string(),
  })
  .strip()
  .superRefine((match, context) => {
    validateTaskSearchHighlights(match.highlights, match.snippet, context);
  });

export const taskSearchResultSchema = z
  .object({
    content_match: taskSearchContentMatchSchema.optional(),
    conversation_id: z.string().min(1),
    highlights: z.array(taskSearchHighlightSchema),
    matched_field: z.enum(["title", "content"]),
    snippet: z.string(),
    title: z.string(),
    updated_at: z.number().optional(),
  })
  .strip()
  .superRefine((result, context) => {
    if (result.matched_field === "title" && result.snippet !== result.title) {
      context.addIssue({
        code: "custom",
        message: "Task title search snippets must preserve the full title",
        path: ["snippet"],
      });
    }
    validateTaskSearchHighlights(result.highlights, result.snippet, context);
  });

function validateTaskSearchHighlights(
  highlights: readonly z.output<typeof taskSearchHighlightSchema>[],
  snippet: string,
  context: z.RefinementCtx
) {
  highlights.forEach((highlight, index) => {
    if (highlight.start >= highlight.end || highlight.end > snippet.length) {
      context.addIssue({
        code: "custom",
        message: "Task search highlight is outside the snippet",
        path: ["highlights", index],
      });
    }
  });
}

export const skillSchema = z
  .object({
    skill_id: z.string(),
    name: z.string(),
    description: z.string().optional(),
    location: z.string(),
    source: z.string().optional(),
    activation: z.string().optional(),
  })
  .passthrough();

export const skillDetailSchema = skillSchema.extend({
  content: z.string(),
  files: z.array(z.string()),
});

/** One page of a Group Router's files under a System Files directory. */
export const systemFilesPageSchema = z
  .object({
    files: z.array(
      z
        .object({
          path: z.string(),
          size: z.number(),
          hash: z.string().nullable().optional(),
          modified_at: z.number().nullable().optional(),
        })
        .strip()
    ),
    next_cursor: z.string().nullable(),
  })
  .strip();

export const systemFileSchema = z
  .object({
    path: z.string(),
    content: z.string(),
    size: z.number(),
    hash: z.string().nullable().optional(),
  })
  .strip();

export const systemFileWrittenSchema = z
  .object({
    path: z.string(),
    size: z.number(),
    hash: z.string().nullable().optional(),
  })
  .strip();

export const systemFileDeletedSchema = z
  .object({ path: z.string(), deleted: z.boolean() })
  .strip();

export const routerInstructionsSchema = z.object({ content: z.string() }).strip();

export const skillFileSchema = z
  .object({ content: z.string(), path: z.string() })
  .strip();

export const modelProtocolSchema = z.enum([
  "anthropic",
  "chat_completions",
  "responses",
]);

/** Every model Comma can route, and the request id and protocol each source expects for it. */
export const modelCatalogSchema = z.object({
  sources: z.record(
    z.string(),
    z.object({
      name: z.string(),
      kind: z.enum(["api_key", "subscription"]),
      base_url: z.string().nullable().optional(),
      endpoint_required: z.boolean().optional(),
      protocols: z.array(modelProtocolSchema).max(3).optional(),
    })
  ),
  models: z
    .array(
      z.object({
        id: z.string(),
        name: z.string(),
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

const builtinSelectionSchema = z.object({ kind: z.literal("builtin") });
const catalogSelectionSchema = z.object({
  kind: z.literal("catalog"),
  model: z.string(),
  reasoning_effort: z.string().nullable(),
  allow_paid: z.boolean(),
  profile_id: z.string().nullable().default(null),
});

/** The model a Task runs when it names none: Comma's own, or a catalog model (never a runtime's). */
export const taskModelSelectionSchema = z.discriminatedUnion("kind", [
  builtinSelectionSchema,
  catalogSelectionSchema,
]);

export const taskModelSchema = z.object({ selection: taskModelSelectionSchema });

/** Where a Task runs when the Router names no place: inside Comma's cloud (Salix), the Workspace's Cloud VM, or a station. */
export const taskPlaceSelectionSchema = z.discriminatedUnion("kind", [
  z.object({ kind: z.literal("salix") }),
  z.object({ kind: z.literal("cloud_vm") }),
  z.object({ kind: z.literal("station"), device_id: z.string().min(1) }),
]);

export const taskPlaceSchema = z.object({ place: taskPlaceSelectionSchema });

export const agentSelectionSchema = z.discriminatedUnion("kind", [
  builtinSelectionSchema,
  catalogSelectionSchema,
  z.object({
    kind: z.literal("runtime"),
    model: z.string(),
    reasoning_effort: z.string().nullable(),
  }),
]);

export const replyStyleSchema = z.enum(["default", "concise"]);

const settingsAgentSchema = z.object({
  agent_id: z.string(),
  name: z.string(),
  role: z.enum(["router", "worker"]),
  reply_style: replyStyleSchema.optional().catch(undefined),
  selection: agentSelectionSchema.optional(),
  model: z.string().nullable().optional(),
  model_display_name: z.string().nullable().optional(),
  reasoning_effort: z.string().nullable().optional(),
  runtime: z
    .object({
      kind: z.string(),
      provider: z.string(),
      protocols: z.array(modelProtocolSchema).max(3).optional(),
    })
    .optional(),
});

export const agentModelsSchema = z.object({
  workspace_id: z.string(),
  agents: z.object({ router: settingsAgentSchema }),
  task_model: taskModelSchema,
  // A server older than the default place leaves it out: Tasks run inside Salix there.
  task_place: taskPlaceSchema.catch({ place: { kind: "salix" } }),
});

/** A profile: a signed-in subscription or a provider API key the system may route model requests through. */
export const modelProfileSchema = z.object({
  id: z.string(),
  credential_kind: z.enum(["subscription_oauth", "provider_api_key"]),
  source: z.string(),
  provider: z.string().optional(),
  name: z.string().nullable().optional(),
  email: z.string().nullable().optional(),
  key_hint: z.string().nullable().optional(),
  disabled: z.boolean(),
  status: z.string(),
  version: z.string(),
  models: z.array(z.string()).max(500).nullable().optional(),
  disabled_models: z.array(z.string()).max(500).optional(),
  connection: z
    .object({ endpoint: z.string().optional(), protocol: z.string().optional() })
    .nullable()
    .optional(),
  reset_attempt: z
    .object({ request_id: z.string(), outcome: z.string() })
    .nullable()
    .optional(),
  quota: z
    .object({
      plan_type: z.string().nullable().optional(),
      observed_at: z.string().nullable().optional(),
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

export const profilePageSchema = z.object({
  accounts: z.array(modelProfileSchema).max(25),
  next: z.string(),
});

export const subscriptionSignInSchema = z.object({
  id: z.string(),
  url: z.url(),
  expires_at: z.string(),
  mode: z.enum(["device", "callback"]).optional(),
  user_code: z.string().optional(),
  interval: z.number().int().min(5).optional(),
});

/** A device-code sign-in asked about: the profile once it is done, else when to ask again. */
export const signInPollSchema = z.union([
  modelProfileSchema,
  z.object({ status: z.literal("pending"), interval: z.number().int().min(5) }),
]);

export const quotaResetSchema = z.object({
  outcome: z.enum(["reset", "already_redeemed", "nothing_to_reset", "no_credit"]),
  account: modelProfileSchema,
  quota_refreshed: z.boolean(),
});

/** The models an endpoint lists (`model-discovery`): only their ids are kept. */
export const discoveredModelsSchema = z.object({
  data: z.array(z.object({ id: z.string() })).max(1000),
});

// Rich previews of a briefing or chat link (`recommendations/link-preview`), one shape per provider.
const linkPersonSchema = z.object({
  avatarUrl: z.string().nullable(),
  name: z.string().min(1),
});

const pullRequestPreviewSchema = z.object({
  additions: z.number().int().nonnegative().nullable(),
  author: z
    .object({ avatarUrl: z.string().nullable(), login: z.string().min(1) })
    .nullable(),
  changedFiles: z.number().int().nonnegative().nullable(),
  deletions: z.number().int().nonnegative().nullable(),
  href: z.string().min(1),
  kind: z.literal("github_pull_request"),
  number: z.number().int().positive(),
  repository: z.string().min(1),
  state: z.enum(["open", "closed", "merged", "draft"]),
  title: z.string().min(1),
  updatedAt: z.number().nullable(),
});

const linearIssuePreviewSchema = z.object({
  assignee: linkPersonSchema.nullable(),
  href: z.string().min(1),
  identifier: z.string().min(1),
  kind: z.literal("linear_issue"),
  priority: z.number().int().nullable(),
  priorityLabel: z.string().nullable(),
  project: z.string().nullable(),
  state: z
    .object({
      color: z.string().nullable(),
      name: z.string().min(1),
      type: z.enum([
        "triage",
        "backlog",
        "unstarted",
        "started",
        "completed",
        "canceled",
      ]),
    })
    .nullable(),
  team: z.string().nullable(),
  title: z.string().min(1),
  updatedAt: z.number().nullable(),
});

const notionPagePreviewSchema = z.object({
  archived: z.boolean(),
  createdAt: z.number().nullable(),
  href: z.string().min(1),
  icon: z.string().nullable(),
  kind: z.literal("notion_page"),
  parent: z.enum(["workspace", "database", "page"]),
  title: z.string().min(1),
  updatedAt: z.number().nullable(),
});

const calendarEventPreviewSchema = z.object({
  allDay: z.boolean(),
  attendeeCount: z.number().int().nonnegative().nullable(),
  endsAt: z.number().nullable(),
  href: z.string().min(1),
  kind: z.literal("google_calendar_event"),
  location: z.string().nullable(),
  meetingUrl: z.string().nullable(),
  organizer: z.object({ name: z.string().min(1) }).nullable(),
  startsAt: z.number().nullable(),
  status: z.enum(["confirmed", "tentative", "cancelled"]),
  title: z.string().min(1),
  updatedAt: z.number().nullable(),
});

const slackMessagePreviewSchema = z.object({
  author: linkPersonSchema.nullable(),
  channel: z.object({ id: z.string().min(1), name: z.string().nullable() }),
  href: z.string().min(1),
  kind: z.literal("slack_message"),
  postedAt: z.number().nullable(),
  // The server trims the message to at most 280 characters (with a trailing
  // ellipsis when it cut) so the card never carries a whole thread.
  text: z.string(),
});

const driveFilePreviewSchema = z.object({
  // Derived server-side from the Drive mimeType; unknown types are "file".
  fileKind: z.enum([
    "document",
    "spreadsheet",
    "presentation",
    "form",
    "folder",
    "pdf",
    "file",
  ]),
  href: z.string().min(1),
  kind: z.literal("google_drive_file"),
  modifiedAt: z.number().nullable(),
  owner: linkPersonSchema.nullable(),
  // Bytes. Google reports a string; the server parses it and sends null for
  // anything unparsable (folders, most Google-native files).
  size: z.number().int().nonnegative().nullable(),
  title: z.string().min(1),
});

// Outlook mail and events: only an exact, currently collected member item.
const outlookPreviewSchema = z.object({
  excerpt: z.string(),
  href: z.string().min(1),
  sender: z.string().nullable(),
  startsAt: z.number().nullable(),
  title: z.string().min(1),
});

export const linkPreviewSchema = z.discriminatedUnion("kind", [
  outlookPreviewSchema.extend({ kind: z.literal("outlook_message") }),
  outlookPreviewSchema.extend({ kind: z.literal("outlook_event") }),
  pullRequestPreviewSchema,
  linearIssuePreviewSchema,
  notionPagePreviewSchema,
  calendarEventPreviewSchema,
  slackMessagePreviewSchema,
  driveFilePreviewSchema,
]);

/** `/me/profile`: the signed-in account's profile. */
export const profileSchema = z
  .object({
    avatar_id: z.string().min(1).max(256).nullable().optional(),
    email: z.string(),
    id: z.string().min(1).max(256),
    name: z.string().min(1).max(200).nullable().optional(),
    locale: z.string().nullable().optional(),
  })
  .strip();

/** `/me/synchronicity/status`: the Workspace's network on the control plane. */
export const synchronicityStatusSchema = z
  .object({ status: z.enum(["unconfigured", "provisioning", "ready"]) })
  .strip();

/** `/me/synchronicity/devices/current`: this device, enrolled in the Workspace's network. */
export const synchronicityDeviceSchema = z.object({ domain: z.string() }).strip();

/** A session history's record, as the server gives it (fields the history does not use are dropped). */
export const historyRecordSchema = z
  .object({
    id: z.string().min(1),
    kind: z.string(),
    content: z.json(),
    input_text: z.string().optional(),
    input_source: z
      .object({
        provider: z
          .enum([
            "internal",
            "telegram",
            "slack",
            "feishu",
            "lark",
            "wechat",
            "imessage",
            "voice",
            "signal",
          ])
          .optional(),
        actor_type: z.enum(["user", "agent", "system"]).optional(),
        conversation_kind: z.enum(["user_chat", "agent_task"]).optional(),
        chat_type: z.enum(["private", "group", "supergroup", "channel"]).optional(),
      })
      .strip()
      .optional(),
    created_at: z.union([z.number(), z.string()]).nullish(),
    timestamp_ms: z.number().nullish(),
    execution: z
      .object({
        id: z.string(),
        lane: z.enum(["model", "tool"]),
        started_at_ms: z.number(),
        first_token_at_ms: z.number().nullish(),
        observed_at_ms: z.number(),
        completed_at_ms: z.number().nullable(),
        duration_ms: z.number().nonnegative(),
        live: z.boolean().optional(),
      })
      .nullish(),
  })
  .strip();

/** A page of a session history (newest last), and the cursor of the one before it. */
export const historyPageSchema = z
  .object({
    conversation_id: z.string(),
    participant_id: z.string(),
    records: z.array(historyRecordSchema).max(50),
    has_more: z.boolean(),
    next_before: z.string().nullish(),
  })
  .strip();

/** A frame of a session history's live stream (`event: history`). */
export const historyFrameSchema = z
  .object({
    conversation_id: z.string(),
    participant_id: z.string(),
    records: z.array(historyRecordSchema).max(50),
    live_records: z.array(historyRecordSchema),
    server_time_ms: z.number(),
    phase: z.enum(["recent", "update", "checkpoint"]),
    checkpoint: z.string().nullable(),
  })
  .strip();
