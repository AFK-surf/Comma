import { z } from "zod";
import { supportedLocales } from "@comma/i18n";
import type { RecommendationSettings } from "@comma/recommendation-contract";
import { pullRequestSchema, usageSchema } from "../coding-wire.ts";
import { computeWorkloadSchema } from "./schemas.ts";
export { recommendationSettingsSchema as commaRecommendationSettingsSchema } from "@comma/recommendation-contract";
export type {
  RecommendationEnvelope as CommaRecommendationEnvelope,
  RecommendationSettings as CommaRecommendationSettings,
} from "@comma/recommendation-contract";
export { taskLoop } from "./task-loop.ts";

/** What a member can fix after a funding stop; published only with its issue. */
const participantIssueDetailSchema = z
  .object({
    source: z.string().min(1).optional(),
    profile_id: z.string().min(1).optional(),
    profile_name: z.string().min(1).optional(),
    reset_at: z.number().positive().optional(),
  })
  .optional()
  .catch(undefined);

const PUBLIC_ACTIVITY_PROSE_MAX_CODEPOINTS = 512;

// These schemas enforce summary-class admission, public-history authority,
// and non-public egress sanitization.

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
    activation: z.string().optional(),
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
        agent_id: z.string().min(1).optional(),
        content: z.array(salixContentBlockSchema),
      })
      .optional(),
    metadata: salixMessageMetadataSchema.optional(),
    client_request_id: z.string().optional(),
    created_at: z.number().optional(),
  })
  .passthrough();

export const commaChatSuggestionSchema = z
  .object({
    id: z.string().min(1),
    label: z.string().min(1),
    prompt: z.string().min(1),
  })
  .passthrough();

export const commaConversationKindSchema = z.enum(["user_chat", "agent_task"]);

/**
 * Where a Task runs and the model it runs, which Task panels show instead of
 * its Agent. A server before it sends none; a value of an unknown kind is
 * dropped.
 */
const commaTaskRunSchema = z
  .object({
    place: z.discriminatedUnion("kind", [
      z.object({ kind: z.literal("salix") }).strip(),
      z.object({ kind: z.literal("cloud_vm") }).strip(),
      z
        .object({
          kind: z.literal("station"),
          device_id: z.string().min(1),
          name: z.string().nullable().optional(),
        })
        .strip(),
      // A coding Task: its own cloud sandbox, with a GitHub repository checked out.
      z
        .object({
          kind: z.literal("sandbox"),
          repo: z
            .object({
              owner: z.string(),
              name: z.string(),
              base_ref: z.string().optional(),
              branch: z.string().optional(),
            })
            .strip(),
          state: z.string(),
          reason: z.string().nullable().optional(),
        })
        .strip(),
    ]),
    model: z
      .discriminatedUnion("kind", [
        z.object({ kind: z.literal("platform") }).strip(),
        z
          .object({
            kind: z.literal("catalog"),
            name: z.string().min(1),
            vendor: z.string().nullable().optional(),
          })
          .strip(),
        z
          .object({
            kind: z.literal("runtime"),
            provider: z.string().nullable().optional(),
            name: z.string().nullable().optional(),
            vendor: z.string().nullable().optional(),
          })
          .strip(),
      ])
      .nullable()
      .optional(),
    // A coding Task's: what its sandbox and GitHub answered last, each part once read. One the client cannot read
    // leaves the run as it is.
    facts: z
      .object({
        usage: usageSchema.nullable().optional(),
        changes: z
          .object({ files: z.number(), additions: z.number(), deletions: z.number() })
          .strip()
          .optional(),
        pull_request: pullRequestSchema.nullable().optional(),
      })
      .strip()
      .optional()
      .catch(undefined),
  })
  .strip();
export type CommaTaskRun = z.output<typeof commaTaskRunSchema>;
const optionalTaskRunSchema = commaTaskRunSchema.optional().catch(undefined);

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
    /** A Loop Task's Loop; read it with `taskLoop`. */
    loop: jsonValueSchema.optional(),
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
    /** A coding Task's run (its sandbox and model) with its detail; other Tasks' runs come with the status stream. */
    run: optionalTaskRunSchema,
    /** On a send's answer: the message the send made (sent again under its request, the same one). */
    accepted_message_id: z.string().min(1).optional(),
  })
  .passthrough();

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
    /** Comes with `bound_worker`: where the Task runs and its model. */
    run: optionalTaskRunSchema,
    /** Comes with `bound_worker`: a Loop Task's Loop; read it with `taskLoop`. */
    loop: jsonValueSchema.optional(),
  })
  .strip();

export const commaTaskParticipantStatusesSchema = z
  .object({
    type: z.literal("task_participant_statuses"),
    group_id: z.string().min(1),
    conversation_id: z.string().min(1),
    bound_worker: commaBoundWorkerSchema.nullable().optional(),
    run: optionalTaskRunSchema,
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
          issue_detail: participantIssueDetailSchema,
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
    target: z.string().optional(),
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
        issue_detail: participantIssueDetailSchema,
        working_provider: z.string().optional(),
        loop_wake: z.boolean().optional(),
        working_conversation_ids: z.array(z.string()).optional(),
        waiting: z.boolean().optional(),
        wait_tool: z.string().optional(),
        wait_started_at: z.number().optional(),
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
    // Experimental station cutover (docs/compute-devices.md): this workspace's
    // device Workers run as station chats, so the desktop Connector keeps
    // local-file access only.
    station_device_cutover: z.boolean().optional(),
  })
  .strip();

// Under the station cutover, `installation: true` answers the one-line station
// enrollment command instead of a Connector credential.
export const commaStationDeviceInstallSchema = z
  .object({
    kind: z.literal("station"),
    install_command: z.string().min(1),
    expires_at: z.number().optional(),
  })
  .strip();

export const commaDeviceInstallSchema = z.union([
  commaStationDeviceInstallSchema,
  commaConnectorTokenSchema,
]);

export const commaConnectorTokenRevocationSchema = z
  .object({
    revoked: z.boolean(),
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

// A link's rich preview, as the core reads it.
export type { LinkPreview as CommaRecommendationLinkPreview } from "@comma/core/contract";

const commaSeqRangeSchema = z.object({
  first: z.number().int().positive(),
  last: z.number().int().positive(),
});

/** `GET …/conversations/:id/messages`: a page by seq, the range it proves read and the conversation's bounds. */
export const commaMessagePageSchema = z
  .object({
    data: z.array(salixMessageSchema),
    covered: commaSeqRangeSchema.nullable().optional(),
    bounds: commaSeqRangeSchema.nullable().optional(),
    has_older: z.boolean().optional(),
  })
  .passthrough();

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
export type SalixContentBlock = z.output<typeof salixContentBlockSchema>;
export type SalixBlobRef = z.output<typeof salixBlobRefSchema>;
export type CommaSkill = z.output<typeof commaSkillSchema>;
export type CommaSkillDetail = z.output<typeof commaSkillDetailSchema>;
export type CommaSkillFile = z.output<typeof commaSkillFileSchema>;
export type CommaGroupFile = z.output<typeof commaGroupFileSchema>;
export type SalixMessage = z.output<typeof salixMessageSchema>;
export type CommaChatSuggestion = z.output<typeof commaChatSuggestionSchema>;
export type CommaConversationKind = z.output<typeof commaConversationKindSchema>;
export type CommaConversation = z.output<typeof commaConversationSchema>;

// The Task label catalog is the client core's (taskLabels); these names stay for the UI that shows it.
export type {
  TaskLabel as CommaTaskLabel,
  TaskLabelProposal as CommaTaskLabelProposal,
  TaskLabelCatalog as CommaTaskLabelCatalog,
} from "@comma/core/contract";
export type CommaTaskLabelColor =
  | "gray"
  | "blue"
  | "indigo"
  | "purple"
  | "pink"
  | "orange"
  | "warning"
  | "success"
  | "error"
  | "brand";
export type CommaCondensedWorkspaceOperation =
  | { op: "add"; text: string }
  | { op: "replace"; id: string; text: string }
  | { op: "remove"; id: string };
export type { TaskLabelApprovalPolicy as CommaTaskLabelApprovalPolicy } from "@comma/core/contract";
export type CommaConversationPreview = z.output<typeof commaConversationPreviewSchema>;
export type CommaConversationEvent = z.output<typeof commaConversationEventSchema>;
export type CommaConversationListEvent = z.output<
  typeof commaConversationListEventSchema
>;
export type CommaConnectorToken = z.output<typeof commaConnectorTokenSchema>;
export type CommaDeviceInstall = z.output<typeof commaDeviceInstallSchema>;
export type CommaApiErrorBody = z.output<typeof commaApiErrorBodySchema>;
export type CommaPage<T> = {
  data: T[];
  has_more?: boolean;
  next_cursor?: string | null;
};

// A compute node's install operation and its recovery (`/v1/comma/workspaces/:id/compute-nodes/agent-vmm/…`).

export const computeInstallDescriptorSchema = z.strictObject({
  exchange_url: z.string().url(),
  expires_at: z.string().min(1),
  one_time_secret: z.string().min(1).max(128),
  operation_id: z.string().min(1).max(128),
  version: z.literal(1),
});

export const computeInstallAuthorizationSchema = z.strictObject({
  descriptor: computeInstallDescriptorSchema,
  operation: z
    .object({
      id: z.string().min(1).max(160),
      registration_id: z.string().min(1).max(160),
    })
    .passthrough(),
});

export const computeLocalWorkloadTargetSchema = z.object({
  registration_id: z.string().min(1).max(200),
  allocation_id: z.string().min(1).max(200),
  generation: z
    .string()
    .max(20)
    .regex(/^[1-9][0-9]*$/),
});
export type ComputeLocalWorkloadTarget = z.output<
  typeof computeLocalWorkloadTargetSchema
>;

export const computeLocalMappingsSchema = z.object({
  mappings: z
    .array(
      computeLocalWorkloadTargetSchema.extend({
        can_read: z.boolean(),
        can_operate: z.boolean(),
      })
    )
    .max(32),
});
export type ComputeLocalMapping = z.output<
  typeof computeLocalMappingsSchema
>["mappings"][number];

export const computeLocalWorkloadsSchema = z.object({
  workloads: z
    .array(
      z.object({
        id: z.string().min(1).max(200),
        kind: z.string().max(80),
        observed_state: z.string().max(80),
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
          ])
          .optional(),
        updated_at: z.string().optional(),
        location: z
          .object({
            provider: z.string().max(80),
            device_id: z.string().max(200).optional(),
          })
          .optional(),
        problem: computeWorkloadSchema.shape.problem,
      })
    )
    .max(32),
  next_cursor: z.string().max(200).nullable().optional(),
});
export type ComputeLocalWorkloads = z.output<typeof computeLocalWorkloadsSchema>;

export const computeRecoveredBindingSchema = z
  .object({
    id: z.string().min(1).max(160),
    registration_id: z.string().min(1).max(160),
    scope_key: z.string().min(1).max(160),
    authorization_status: z.literal("handed_off"),
    status: z.enum(["processing", "ready", "stopped", "action_required"]),
    environment_id: z.string().min(1).max(160),
  })
  .passthrough();
export type ComputeRecoveredBinding = z.output<typeof computeRecoveredBindingSchema>;

export const computeRecoveryChallengeSchema = z
  .object({
    operation_id: z.string(),
    registration_id: z.string(),
    challenge: z
      .object({
        purpose: z.literal("agent-vmm/comma-recovery/1"),
        audience: z.string(),
        subject: z.string(),
        session_id: z.string(),
        tenant_id: z.string(),
        group_id: z.string(),
        scope_key: z.string(),
        environment_id: z.string(),
        operation_id: z.string(),
        registration_id: z.string(),
        nonce: z.string(),
        revision: z.number().int().positive().max(Number.MAX_SAFE_INTEGER),
        expires_at: z.number().int().positive(),
      })
      .strict(),
  })
  .strict();
export type ComputeRecoveryChallenge = z.output<typeof computeRecoveryChallengeSchema>;
