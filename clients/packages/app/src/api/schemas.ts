import { z } from "zod";
import { supportedLocales } from "@comma/i18n";
import {
  recommendationEnvelopeSchema,
  type RecommendationSettings,
} from "@comma/recommendation-contract";
export {
  recommendationEnvelopeSchema as commaRecommendationEnvelopeSchema,
  recommendationSettingsSchema as commaRecommendationSettingsSchema,
} from "@comma/recommendation-contract";
export type {
  RecommendationEnvelope as CommaRecommendationEnvelope,
  RecommendationSettings as CommaRecommendationSettings,
} from "@comma/recommendation-contract";

const PUBLIC_ACTIVITY_PROSE_MAX_CODEPOINTS = 512;

// Implementation anchor: summary-class admission, public-history authority,
// and non-public egress sanitization are modeled in
// tla/salix/ActivitySummaryAuthority.tla.

const jsonValueSchema: z.ZodType<JsonValue> = z.lazy(() =>
  z.union([
    z.string(),
    z.number(),
    z.boolean(),
    z.null(),
    z.array(jsonValueSchema),
    z.record(z.string(), jsonValueSchema),
  ])
);

export type JsonValue =
  | string
  | number
  | boolean
  | null
  | JsonValue[]
  | { [key: string]: JsonValue };

export const commaWorkspaceSchema = z
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

export const commaUserProfileSchema = z
  .object({
    avatar_id: z.string().min(1).max(256).nullable().optional(),
    email: z.string().email(),
    id: z.string().min(1).max(256),
    // Reads retain the physical/import compatibility bound. Self-service
    // writes are still limited to 64 characters by the UI and server command.
    name: z.string().min(1).max(200).nullable().optional(),
    // The account's app language, shared by every device. Null until the
    // first signed-in client reports its language.
    locale: z.enum(supportedLocales).nullable().optional(),
  })
  .strip();

/** `GET /v1/comma/me/synchronicity/status`: the Workspace's provisioning on the control plane. */
export const commaSynchronicityStatusSchema = z
  .object({
    configured: z.boolean(),
    network_id: z.string().nullable().optional(),
    provisioned: z.boolean(),
    status: z.enum(["unconfigured", "provisioning", "ready"]),
  })
  .strip();

export type CommaSynchronicityStatus = z.output<typeof commaSynchronicityStatusSchema>;

/** `PUT /v1/comma/me/synchronicity/devices/current`: this device, enrolled in the Workspace's network. */
export const commaSynchronicityDeviceSchema = z
  .object({
    created: z.boolean(),
    device_id: z.string(),
    /** `<network>.<org-slug>.<apex>`, the membership domain the node binds to. */
    domain: z.string(),
    network: z.string(),
  })
  .strip();

export type CommaSynchronicityDevice = z.output<typeof commaSynchronicityDeviceSchema>;

export const commaWorkspaceBootstrapSchema = z.discriminatedUnion("status", [
  z
    .object({
      status: z.literal("ready"),
      workspace: commaWorkspaceSchema,
    })
    .passthrough(),
  z
    .object({
      retry_after_seconds: z.number().int().positive(),
      status: z.literal("provisioning"),
      workspace: commaWorkspaceSchema,
    })
    .passthrough(),
]);

export const commaTelegramLinkSchema = z
  .object({
    telegram_user_id: z.string().min(1),
    telegram_username: z.string().min(1).nullable(),
    connection_id: z.string().optional(),
    connected_at: z.number().int(),
    updated_at: z.number().int(),
  })
  .strip();

export const commaIMessageClaimSchema = z
  .object({
    code: z.string().min(1),
    expires_at: z.number().int(),
  })
  .strip();

export const commaIMessageIntegrationStateSchema = z
  .object({
    configured: z.boolean(),
    shared_handle: z.string().nullable(),
    shared_identity: z.string(),
    workspace_id: z.string().min(1),
    connection_active: z.boolean(),
    relay_online: z.boolean(),
    pending_claim: commaIMessageClaimSchema.nullable(),
    link: z
      .object({
        sender_handle: z.string().min(1),
        sender_label: z.string().nullable(),
        connection_id: z.string().min(1),
        connected_at: z.number().int(),
        updated_at: z.number().int(),
      })
      .strip()
      .nullable(),
  })
  .strip();

export type CommaIMessageIntegrationState = z.output<
  typeof commaIMessageIntegrationStateSchema
>;
export type CommaIMessageClaim = z.output<typeof commaIMessageClaimSchema>;

export const commaWeChatConnectionSchema = z
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
export const commaWeChatIntegrationStateSchema = z
  .object({
    connection: commaWeChatConnectionSchema.nullable(),
    pending: commaWeChatConnectionSchema.nullable(),
  })
  .strip();
export type CommaWeChatConnection = z.output<typeof commaWeChatConnectionSchema>;
export type CommaWeChatIntegrationState = z.output<
  typeof commaWeChatIntegrationStateSchema
>;

export const commaTelegramIntegrationStateSchema = z
  .object({
    bot_url: z.string().url().nullable(),
    bot_username: z.string().min(1).nullable(),
    configured: z.boolean(),
    link: commaTelegramLinkSchema.nullable(),
    connection_active: z.boolean().optional(),
    official_login_available: z.boolean(),
    workspace_id: z.string().min(1),
    workspace_name: z.string().min(1),
  })
  .strip();

export const commaTelegramConnectAttemptSchema = z
  .object({
    authorization_url: z.string().url(),
    expires_in_seconds: z.number().int().positive(),
    workspace_id: z.string().min(1),
  })
  .strip();

export const commaTelegramDisconnectSchema = z
  .object({ disconnected: z.boolean() })
  .strip();

export const commaBillingPlanSchema = z
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

export const commaBillingSummarySchema = z
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
        plan: commaBillingPlanSchema.nullable().optional(),
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

export const commaBillingSessionSchema = z
  .object({ id: z.string(), provider: z.literal("stripe"), url: z.url() })
  .strip();

export const commaBillingChangePreviewSchema = z
  .object({
    amount_minor: z.number().int(),
    currency: z.string(),
    proration_date: z.number().int(),
    current_price_id: z.string(),
    period_end: z.number().int(),
    effect: z.enum(["upgrade", "downgrade", "keep_current"]),
  })
  .strip();
export const commaBillingChangeSchema = z
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
export type CommaBillingChangePreview = z.output<
  typeof commaBillingChangePreviewSchema
>;
export type CommaBillingChange = z.output<typeof commaBillingChangeSchema>;

export const commaRedemptionResultSchema = z
  .object({
    idempotent: z.boolean().optional(),
    grant: z
      .object({ remaining_credits: z.number().int().nonnegative() })
      .passthrough()
      .nullable()
      .optional(),
  })
  .passthrough();

export type CommaBillingPlan = z.output<typeof commaBillingPlanSchema>;
export type CommaBillingSummary = z.output<typeof commaBillingSummarySchema>;
export type CommaBillingSession = z.output<typeof commaBillingSessionSchema>;
export type CommaRedemptionResult = z.output<typeof commaRedemptionResultSchema>;

export const salixContentBlockSchema = z
  .object({
    type: z.string(),
  })
  .passthrough();

export const salixBlobRefSchema = z
  .object({
    hash: z.string().regex(/^[0-9a-f]{64}$/),
    kind: z.literal("blob"),
    size: z.number().int().nonnegative(),
    uuid: z.string().regex(/^[0-9a-f]{32}$/),
  })
  .strict();

export const commaSkillSchema = z
  .object({
    skill_id: z.string(),
    name: z.string(),
    description: z.string().optional(),
    location: z.string(),
    source: z.string().optional(),
  })
  .passthrough();

export const commaSkillDetailSchema = commaSkillSchema.extend({
  content: z.string(),
  files: z.array(z.string()),
});

export const commaSkillFileSchema = z
  .object({
    content: z.string(),
    path: z.string(),
  })
  .strip();

export const commaPluginResourceSchema = z
  .object({
    id: z.string(),
    name: z.string(),
  })
  .strip();

export const commaPluginSchema = z
  .object({
    id: z.string(),
    name: z.string(),
    summary: z.string(),
    description: z.string().optional(),
    brand: z.string().nullable().optional(),
    category: z.string(),
    installed: z.boolean(),
    locked: z.boolean(),
    mcps: z.array(commaPluginResourceSchema),
    skills: z.array(commaPluginResourceSchema),
  })
  .strip();

export const commaPluginAuthorizationSchema = z
  .object({
    authorizationUrl: z.url().optional(),
    state: z.string().min(1),
  })
  .strip();

export const commaPluginInstallResultSchema = z
  .object({
    plugin: commaPluginSchema,
    authorization: commaPluginAuthorizationSchema.nullable(),
  })
  .strip();

export const commaPluginPersonalSourcesSchema = z.object({
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
      /** MCP OAuth grants name the plugin MCPs they authorize. */
      mcpIds: z.array(z.string()).optional(),
    })
  ),
});

export const commaPluginAccountConfirmationSchema = z.object({
  state: z.string().min(1),
  toolkit: z.string(),
  connectionId: z.string(),
  identity: z.string(),
});

export const commaPluginConfirmedAccountSchema = z.object({
  state: z.literal("ready"),
  toolkit: z.string(),
  connectionId: z.string(),
});

export const commaGroupFileSchema = z
  .object({
    path: z.string(),
    name: z.string(),
    size: z.number(),
  })
  .passthrough();

export const salixMessageMetadataSchema = z.object({}).passthrough();

export const salixMessageSchema = z
  .object({
    message_id: z.string().min(1),
    reply_to_message_id: z.string().min(1).optional(),
    thread_root_message_id: z.string().min(1).optional(),
    kind: z.string().min(1),
    actor_type: z.string().min(1),
    agent_id: z.string().min(1).optional(),
    user_id: z.string().min(1).optional(),
    role_label: z.string().min(1).optional(),
    content: z.array(salixContentBlockSchema),
    platform_message: z
      .object({
        provider: z.string().min(1).max(64),
        role: z.enum(["user", "assistant"]),
        content: z.array(salixContentBlockSchema),
      })
      .optional(),
    metadata: salixMessageMetadataSchema.optional(),
    client_request_id: z.string().optional(),
    created_at: z.number().optional(),
  })
  .passthrough();

export const commaConversationKindSchema = z.enum(["user_chat", "agent_task"]);

export const commaConversationSchema = z
  .object({
    group_id: z.string(),
    id: z.string(),
    title: z.string(),
    status: z.string(),
    archived_at: z.number().optional(),
    archived_from_status: z.string().optional(),
    archive_availability: z
      .object({ allowed: z.boolean(), reason: z.string().nullable() })
      .optional(),
    kind: commaConversationKindSchema,
    freshness: z
      .object({
        state: z.enum(["fresh", "stale", "unknown"]),
        refreshed_at: z.number().optional(),
      })
      .optional(),
    schedule: jsonValueSchema.optional(),
    review_version: z.number().int().positive().optional(),
    activity_status: z.string().optional(),
    message_count: z.number().optional(),
    messages: z.array(salixMessageSchema).optional(),
    /** Label ids from the Group catalog (`commaTaskLabelCatalogSchema`). */
    labels: z.array(z.string()).optional(),
    /** Where the Task was asked for: an IM provider name, or `comma` for the client. */
    origin: z.string().optional(),
    /** Client platform of the requesting Comma session, when it was a Comma client. */
    client_platform: z.string().optional(),
    created_at: z.number().optional(),
    updated_at: z.number().optional(),
    /** An `agent_task` has an active public share link. */
    shared: z.boolean().optional(),
  })
  .passthrough();

/** The owner's view of a Task's public share link. */
export const commaTaskShareSchema = z
  .object({
    url: z.string().url(),
    created_at: z.number(),
    shared_at: z.number(),
    message_count: z.number().int().nonnegative(),
    artifact_count: z.number().int().nonnegative(),
    has_newer_messages: z.boolean(),
  })
  .strip();

export type CommaTaskShare = z.output<typeof commaTaskShareSchema>;

/** One active link in the owner's list of a Group's shares. */
export const commaTaskShareEntrySchema = z
  .object({
    conversation: commaConversationSchema,
    url: z.string().url(),
    created_at: z.number(),
    shared_at: z.number(),
    message_count: z.number().int().nonnegative(),
    artifact_count: z.number().int().nonnegative(),
  })
  .strip();

export type CommaTaskShareEntry = z.output<typeof commaTaskShareEntrySchema>;

export const commaTaskSharePageSchema = z.object({
  data: z.array(commaTaskShareEntrySchema),
  has_more: z.boolean(),
  next_cursor: z.string().nullable(),
});

const commaBoundWorkerSchema = z.object({
  participant_id: z.string().min(1),
  actor_id: z.string().optional(),
  name: z.string(),
});

export const commaConversationPreviewSchema = z
  .object({
    activity_status: z.string(),
    freshness: z.object({
      state: z.enum(["fresh", "stale", "unknown"]),
      refreshed_at: z.number().optional(),
    }),
    id: z.string(),
    group_id: z.string(),
    kind: z.literal("agent_task"),
    status: z.string(),
    title: z.string(),
    updated_at: z.number(),
    /** Label ids from the Group catalog; the hover card draws them as chips. */
    labels: z.array(z.string()).optional(),
    /** Where the Task was asked for: an IM provider name, or `comma`. */
    origin: z.string().optional(),
    /** Included only when the caller requests the Task's Worker identity. */
    bound_worker: commaBoundWorkerSchema.nullable().optional(),
  })
  .strip();

const commaTaskSearchHighlightSchema = z
  .object({
    end: z.number().int().nonnegative(),
    start: z.number().int().nonnegative(),
  })
  .strip();

const commaTaskSearchContentMatchSchema = z
  .object({
    highlights: z.array(commaTaskSearchHighlightSchema),
    snippet: z.string(),
  })
  .strip()
  .superRefine((match, context) => {
    validateTaskSearchHighlights(match.highlights, match.snippet, context);
  });

export const commaTaskSearchResultSchema = z
  .object({
    content_match: commaTaskSearchContentMatchSchema.optional(),
    conversation_id: z.string().min(1),
    highlights: z.array(commaTaskSearchHighlightSchema),
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
  highlights: readonly z.output<typeof commaTaskSearchHighlightSchema>[],
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

export const commaTaskOrderSchema = z
  .object({
    orders: z.record(z.string(), z.array(z.string())),
  })
  .strip();

export const commaTaskParticipantStatusesSchema = z
  .object({
    type: z.literal("task_participant_statuses"),
    group_id: z.string().min(1),
    conversation_id: z.string().min(1),
    bound_worker: commaBoundWorkerSchema.nullable().optional(),
    participants: z
      .array(
        z.object({
          conversation_id: z.string().min(1),
          participant_id: z.string().min(1),
          name: z.string(),
          actor_id: z.string().optional(),
          actor_role: z.enum(["router", "worker"]).optional(),
          state: z.enum(["active", "error", "stopped"]),
          status: z.string(),
          updated_at: z.number(),
          issue: z.string().optional(),
        })
      )
      .max(2),
  })
  .superRefine((event, context) => {
    if (
      event.participants.some((p) => p.conversation_id !== event.conversation_id) ||
      new Set(event.participants.map((p) => p.participant_id)).size !==
        event.participants.length
    ) {
      context.addIssue({
        code: "custom",
        message:
          "Task Participant snapshot must have unique, exact Conversation identities",
      });
    }
  });
export type CommaTaskParticipantStatuses = z.output<
  typeof commaTaskParticipantStatusesSchema
>;

export const commaConversationEventSchema = z
  .object({
    type: z.string(),
    action: z.string().optional(),
    client_request_id: z.string().optional(),
    delta: z.string().optional(),
    draft_id: z.string().optional(),
    conversation_id: z.string().optional(),
    goal: z.string().optional(),
    message_id: z.string().optional(),
    participant_id: z.string().min(1).optional(),
    // Realtime decoding must not make the independently owned canonical
    // transcript unavailable. Invalid/absent draft data fails closed locally.
    participant_draft: z
      .object({
        conversation_id: z.string().min(1),
        draft_id: z.string().min(1),
        response_key: z.string().min(1).max(128),
        revision: z.number().int().nonnegative(),
        source_message_ids: z.array(z.string().min(1)).min(1),
        text: z.string(),
      })
      .nullish()
      .catch(undefined),
    participant_status: z
      .object({
        conversation_id: z.string().min(1),
        participant_id: z.string().min(1),
        state: z.enum(["active", "error", "stopped"]),
        status: z.string(),
        updated_at: z.number(),
        issue: z.string().optional(),
        working_provider: z.string().optional(),
        loop_wake: z.boolean().optional(),
      })
      .nullish()
      .catch(undefined),
    producer_epoch: z.string().min(1).max(128).optional(),
    response_key: z.string().min(1).max(128).optional(),
    revision: z.number().int().nonnegative().optional(),
    role: z.string().optional(),
    phase: z.string().optional(),
    sequence: z.number().int().positive().optional(),
    source_message_ids: z.array(z.string().min(1)).optional(),
    summary: z.string().optional(),
    summary_class: z.enum(["none", "generic", "public"]).optional(),
    text: z.string().optional(),
    group_id: z.string().optional(),
    title: z.string().optional(),
    status: z.string().optional(),
    state: z.enum(["active", "error", "stopped"]).optional(),
    tool_name: z.string().optional(),
    updated_at: z.number().optional(),
    messages: z.array(salixMessageSchema).optional(),
  })
  .passthrough()
  .superRefine((event, context) => {
    if (event.type === "participant_status_cleared") {
      const requiredParticipantClearFields: Array<[boolean, string]> = [
        [event.conversation_id !== undefined, "conversation_id"],
        [event.participant_id !== undefined, "participant_id"],
        [event.reason === "owner_unavailable", "reason"],
      ];

      for (const [valid, field] of requiredParticipantClearFields) {
        if (!valid) {
          context.addIssue({
            code: "custom",
            message: `Participant status clear requires ${field}`,
            path: [field],
          });
        }
      }
      return;
    }

    if (event.type === "participant_status") {
      const requiredParticipantStatusFields: Array<[boolean, string]> = [
        [event.conversation_id !== undefined, "conversation_id"],
        [event.participant_id !== undefined, "participant_id"],
        [event.state !== undefined, "state"],
        [event.status !== undefined, "status"],
        [event.updated_at !== undefined, "updated_at"],
      ];

      for (const [valid, field] of requiredParticipantStatusFields) {
        if (!valid) {
          context.addIssue({
            code: "custom",
            message: `Participant status requires ${field}`,
            path: [field],
          });
        }
      }
      return;
    }

    if (event.type !== "activity") {
      return;
    }

    const exactSourceIds =
      event.source_message_ids !== undefined &&
      event.source_message_ids.length > 0 &&
      new Set(event.source_message_ids).size === event.source_message_ids.length;

    const requiredActivityV2Fields: Array<[boolean, string]> = [
      [event.response_key !== undefined, "response_key"],
      [exactSourceIds, "source_message_ids"],
      [event.producer_epoch !== undefined, "producer_epoch"],
      [event.sequence !== undefined, "sequence"],
      [event.summary_class !== undefined, "summary_class"],
    ];

    for (const [valid, field] of requiredActivityV2Fields) {
      if (!valid) {
        context.addIssue({
          code: "custom",
          message: `Activity v2 requires ${field}`,
          path: [field],
        });
      }
    }

    const summaryClass = event.summary_class;
    if (summaryClass === undefined) return;

    const boundedPublicProse = (value: string | undefined, required: boolean) =>
      value === undefined
        ? !required
        : value.trim() !== "" &&
          Array.from(value).length <= PUBLIC_ACTIVITY_PROSE_MAX_CODEPOINTS;
    const rejectContradictoryAuthority = () =>
      context.addIssue({
        code: "custom",
        message: "Activity v2 summary_class contradicts phase/status/payload",
        path: ["summary_class"],
      });

    if (summaryClass === "generic") {
      if (event.phase === "thinking" && event.status === "failed") {
        if (
          event.action !== undefined ||
          event.summary !== undefined ||
          event.goal !== undefined ||
          event.tool_name !== undefined
        ) {
          rejectContradictoryAuthority();
        }
        return;
      }

      const copy = event.phase === "thinking" ? "Thinking" : "Typing";
      if (
        event.status !== "running" ||
        (event.phase !== "thinking" && event.phase !== "messaging") ||
        event.action !== copy ||
        event.summary !== copy ||
        event.goal !== undefined ||
        event.tool_name !== undefined
      ) {
        rejectContradictoryAuthority();
      }
      return;
    }

    if (summaryClass === "public") {
      if (
        !(
          (event.phase === "thinking" && event.status === "running") ||
          (event.phase === "execution" &&
            (event.status === "running" || event.status === "failed"))
        ) ||
        !boundedPublicProse(event.summary, true) ||
        !boundedPublicProse(event.action, false) ||
        !boundedPublicProse(event.goal, false) ||
        !boundedPublicProse(event.tool_name, false)
      ) {
        rejectContradictoryAuthority();
      }
      return;
    }

    if (
      event.phase !== "idle" ||
      event.status !== "idle" ||
      event.action !== undefined ||
      event.summary !== undefined ||
      event.goal !== undefined ||
      event.tool_name !== undefined
    ) {
      rejectContradictoryAuthority();
    }
  });

export const commaConversationListEventSchema = z.discriminatedUnion("type", [
  z
    .object({
      type: z.literal("conversation_list_resync_required"),
      group_id: z.string().min(1),
      kind: z.literal("agent_task"),
      version: z.string().min(1).max(128),
    })
    .strip(),
  z
    .object({
      type: z.literal("conversation_list_invalidated"),
      group_id: z.string().min(1),
      kind: z.literal("agent_task"),
      version: z.string().min(1).max(128),
    })
    .strip(),
]);

export const commaConnectorTokenSchema = z
  .object({
    token: z.string(),
    server: z.string(),
    connect_url: z.string().optional(),
    device_id: z.string().optional(),
    name: z.string().optional(),
    alias: z.string().optional(),
    scope: z.string().optional(),
    expires_at: z.number().nullish(),
    registration_expires_at: z.number().optional(),
    install_command: z.string().optional(),
    env: z.record(z.string(), z.string()).optional(),
  })
  .strip();

export const commaConnectorTokenRevocationSchema = z
  .object({
    revoked: z.boolean(),
  })
  .strip();

// An inbound API key: what an external service presents to post a message to
// this workspace's Router (docs/product-features.md). The
// plaintext exists only in the creation response.
export const commaRouterApiKeySchema = z
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

export const commaRouterApiKeyCreatedSchema = commaRouterApiKeySchema
  .extend({
    key: z.string().min(1),
    post_message_url: z.string().min(1),
  })
  .strip();

export const commaRouterApiKeyDeletionSchema = z
  .object({
    deleted: z.boolean(),
  })
  .strip();

// A voice agent API key: the `voice` kind of the same Group API key record.
// It opens only the voice readiness and session routes
// (docs/messaging-voice.md). The plaintext exists only in the creation response.
export const commaVoiceApiKeySchema = z
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

export const commaVoiceApiKeyCreatedSchema = commaVoiceApiKeySchema
  .extend({
    key: z.string().min(1),
    sessions_url: z.string().min(1),
  })
  .strip();

// One caller number verified for the workspace's voice line. The PIN itself
// never leaves the server; only whether one is set.
export const commaVoiceNumberSchema = z
  .object({
    e164: z.string().min(1),
    carrier: z.string().nullish(),
    line: z.string().nullish(),
    verified_at: z.number().nullish(),
    pin_set: z.boolean(),
    pin_locked_until: z.number().nullish(),
    status: z.enum(["verified", "locked"]),
  })
  .strip();

export const commaVoiceIntegrationSchema = z
  .object({
    /** The platform numbers a verified caller dials. */
    lines: z.array(z.string()),
    numbers: z.array(commaVoiceNumberSchema),
    readiness: z
      .object({
        ready: z.boolean(),
        reason: z.string().nullish(),
      })
      .strip(),
    sessions_url: z.string().nullish(),
    readiness_url: z.string().nullish(),
  })
  .strip();

export const commaVoiceVerificationSchema = z
  .object({
    e164: z.string().min(1),
    line: z.string().nullish(),
    status: z.string(),
  })
  .strip();

/** A Signal account as Comma shows it: its number and whether it serves now. */
export const commaSignalAccountSchema = z
  .object({
    e164: z.string().nullish(),
    state: z.string().nullish(),
    scope: z.string().nullish(),
  })
  .strip();

export const commaSignalBindingSchema = z
  .object({
    binding_id: z.string().min(1),
    kind: z.enum(["user", "group"]),
    peer: z.string().min(1),
    display_name: z.string().nullish(),
    bound_at: z.number().nullish(),
    /** The Signal number the chat talks with. */
    number: z.string().nullish(),
  })
  .strip();

export const commaSignalIntegrationSchema = z
  .object({
    /** The account that new connection codes use; null when none is set. */
    account: commaSignalAccountSchema.nullish(),
    bindings: z.array(commaSignalBindingSchema),
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

export const commaSignalNumberSchema = z
  .object({
    override: commaSignalAccountSchema.nullish(),
    platform: commaSignalAccountSchema.nullish(),
    effective: commaSignalAccountSchema.nullish(),
  })
  .strip();

export const commaApiErrorBodySchema = z
  .object({
    error: z.string().optional(),
  })
  .passthrough();

// A settings write carries the schedule and the auto-enable choice, and only
// the source flags the member changed; the server keys sources by connection
// id and keeps the flag of every source the request does not name.
export type CommaRecommendationSettingsPatch = Omit<
  RecommendationSettings,
  "sourceRevision" | "sources" | "sourcesCheckedAt"
> & {
  sources?: Array<{ connectionId: string; enabled: boolean }>;
};

export const commaRecommendationRefreshSchema = z.object({
  envelope: recommendationEnvelopeSchema,
  run: z.object({
    generation: z.number().int().positive(),
    id: z.string().min(1),
    sourceRevision: z.number().int().nonnegative(),
    status: z.enum(["pending", "running", "published", "superseded", "failed"]),
    trigger: z.enum(["manual", "schedule", "agent_tool"]),
  }),
});

// Hover metadata for a recommendation inline link, read live through the
// link's own connected account. Only these link shapes resolve; the server
// answers 404 for everything else (Gmail on purpose) and the client keeps
// its generic destination card.
const commaRecommendationLinkPersonSchema = z.object({
  avatarUrl: z.string().nullable(),
  name: z.string().min(1),
});

export const commaRecommendationPullRequestPreviewSchema = z.object({
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

export const commaRecommendationLinearIssuePreviewSchema = z.object({
  assignee: commaRecommendationLinkPersonSchema.nullable(),
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

export const commaRecommendationNotionPagePreviewSchema = z.object({
  archived: z.boolean(),
  createdAt: z.number().nullable(),
  href: z.string().min(1),
  icon: z.string().nullable(),
  kind: z.literal("notion_page"),
  parent: z.enum(["workspace", "database", "page"]),
  title: z.string().min(1),
  updatedAt: z.number().nullable(),
});

export const commaRecommendationCalendarEventPreviewSchema = z.object({
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

export const commaRecommendationSlackMessagePreviewSchema = z.object({
  author: commaRecommendationLinkPersonSchema.nullable(),
  channel: z.object({ id: z.string().min(1), name: z.string().nullable() }),
  href: z.string().min(1),
  kind: z.literal("slack_message"),
  postedAt: z.number().nullable(),
  // The server trims the message to at most 280 characters (with a trailing
  // ellipsis when it cut) so the card never carries a whole thread.
  text: z.string(),
});

export const commaRecommendationDriveFilePreviewSchema = z.object({
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
  owner: commaRecommendationLinkPersonSchema.nullable(),
  // Bytes. Google reports a string; the server parses it and sends null for
  // anything unparsable (folders, most Google-native files).
  size: z.number().int().nonnegative().nullable(),
  title: z.string().min(1),
});

export const commaRecommendationLinkPreviewSchema = z.discriminatedUnion("kind", [
  commaRecommendationPullRequestPreviewSchema,
  commaRecommendationLinearIssuePreviewSchema,
  commaRecommendationNotionPagePreviewSchema,
  commaRecommendationCalendarEventPreviewSchema,
  commaRecommendationSlackMessagePreviewSchema,
  commaRecommendationDriveFilePreviewSchema,
]);
export type CommaRecommendationLinkPreview = z.output<
  typeof commaRecommendationLinkPreviewSchema
>;

export function commaPageSchema<T extends z.ZodType>(itemSchema: T) {
  return z
    .object({
      data: z.array(itemSchema),
      has_more: z.boolean().optional(),
      next_cursor: z.string().nullable().optional(),
    })
    .passthrough();
}

export type CommaWorkspace = z.output<typeof commaWorkspaceSchema>;
export type CommaUserProfile = z.output<typeof commaUserProfileSchema>;
export type CommaWorkspaceBootstrap = z.output<typeof commaWorkspaceBootstrapSchema>;
export type CommaTelegramIntegrationState = z.output<
  typeof commaTelegramIntegrationStateSchema
>;
export type CommaTelegramConnectAttempt = z.output<
  typeof commaTelegramConnectAttemptSchema
>;
export type SalixContentBlock = z.output<typeof salixContentBlockSchema>;
export type SalixBlobRef = z.output<typeof salixBlobRefSchema>;
export type CommaSkill = z.output<typeof commaSkillSchema>;
export type CommaSkillDetail = z.output<typeof commaSkillDetailSchema>;
export type CommaSkillFile = z.output<typeof commaSkillFileSchema>;
export type CommaPluginResource = z.output<typeof commaPluginResourceSchema>;
export type CommaPlugin = z.output<typeof commaPluginSchema>;
export type CommaPluginInstallResult = z.output<typeof commaPluginInstallResultSchema>;
export type CommaPluginPersonalSources = z.output<
  typeof commaPluginPersonalSourcesSchema
>;
export type CommaPluginAccountConfirmation = z.output<
  typeof commaPluginAccountConfirmationSchema
>;
export type CommaPluginConfirmedAccount = z.output<
  typeof commaPluginConfirmedAccountSchema
>;
export type CommaGroupFile = z.output<typeof commaGroupFileSchema>;
export type SalixMessage = z.output<typeof salixMessageSchema>;
export type CommaConversationKind = z.output<typeof commaConversationKindSchema>;
export type CommaConversation = z.output<typeof commaConversationSchema>;

export const commaTaskLabelColorSchema = z.enum([
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

export const commaTaskLabelSchema = z
  .object({
    id: z.string().min(1),
    name: z.string(),
    color: z.string(),
    description: z.string().optional(),
    created_at: z.number().optional(),
    updated_at: z.number().optional(),
  })
  .passthrough();

export const commaTaskLabelProposalSchema = z
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
      .catchall(jsonValueSchema),
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

export const commaTaskLabelCatalogSchema = z
  .object({
    approval_policy: z.enum(["ask", "auto"]).default("ask"),
    labels: z.array(commaTaskLabelSchema),
    proposals: z.array(commaTaskLabelProposalSchema).default([]),
    colors: z.array(z.string()).default([]),
    updated_at: z.number().optional(),
  })
  .passthrough();

export const commaDeviceSchema = z.object({
  disconnected_at: z.number().nullish(),
  system_info: z
    .object({
      client_source: z
        .enum(["comma_dev", "comma_staging", "comma", "connector"])
        .optional(),
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
export const commaDevicePageSchema = z.object({
  devices: z.array(commaDeviceSchema),
  next_cursor: z.string().nullable(),
});
export type CommaDevice = z.output<typeof commaDeviceSchema>;
export type CommaDevicePage = z.output<typeof commaDevicePageSchema>;

export type CommaTaskLabelColor = z.output<typeof commaTaskLabelColorSchema>;
export type CommaTaskLabel = z.output<typeof commaTaskLabelSchema>;
export type CommaTaskLabelProposal = z.output<typeof commaTaskLabelProposalSchema>;
export type CommaTaskLabelCatalog = z.output<typeof commaTaskLabelCatalogSchema>;
export type CommaTaskLabelApprovalPolicy = CommaTaskLabelCatalog["approval_policy"];
export type CommaConversationPreview = z.output<typeof commaConversationPreviewSchema>;
export type CommaTaskSearchResult = z.output<typeof commaTaskSearchResultSchema>;
export type CommaTaskOrder = z.output<typeof commaTaskOrderSchema>;
export type CommaConversationEvent = z.output<typeof commaConversationEventSchema>;
export type CommaConversationListEvent = z.output<
  typeof commaConversationListEventSchema
>;
export type CommaConnectorToken = z.output<typeof commaConnectorTokenSchema>;
export type CommaRouterApiKey = z.output<typeof commaRouterApiKeySchema>;
export type CommaRouterApiKeyCreated = z.output<typeof commaRouterApiKeyCreatedSchema>;
export type CommaVoiceApiKey = z.output<typeof commaVoiceApiKeySchema>;
export type CommaVoiceApiKeyCreated = z.output<typeof commaVoiceApiKeyCreatedSchema>;
export type CommaVoiceNumber = z.output<typeof commaVoiceNumberSchema>;
export type CommaVoiceIntegration = z.output<typeof commaVoiceIntegrationSchema>;
export type CommaVoiceVerification = z.output<typeof commaVoiceVerificationSchema>;
export type CommaSignalBinding = z.output<typeof commaSignalBindingSchema>;
export type CommaSignalIntegration = z.output<typeof commaSignalIntegrationSchema>;
export type CommaSignalNumber = z.output<typeof commaSignalNumberSchema>;
export type CommaApiErrorBody = z.output<typeof commaApiErrorBodySchema>;
export type CommaPage<T> = {
  data: T[];
  has_more?: boolean;
  next_cursor?: string | null;
};
