import { z } from "zod";

export const chatProtocolVersion = 3 as const;
export const sideChatMessageWindow = 200 as const;
export const chatSurfaceProjectionLimit = 8 as const;
export const chatAttachmentUploadLimit = 8 as const;
export const chatAttachmentUploadMaxBytes = 10_000_000 as const;
/** Public Conversation attachment download bounds, shared with native saves. */
export const chatAttachmentDownloadMaxBytes = chatAttachmentUploadMaxBytes;
export const chatAttachmentDownloadMaxFileNameBytes = 1_024 as const;
/**
 * Transport bound for Main-rendered chat image previews. Previews ship at
 * source resolution — the render is a sanitizing decode/encode pass, not a
 * thumbnail step — so this bound must hold a full-resolution PNG re-encode
 * of a typical retina screenshot; Main steps the scale down only when even
 * that overflows.
 */
export const chatImagePreviewMaxBytes = 8_388_608 as const;

export const chatMessageDeliverySchema = z.enum(["sent", "sending", "failed"]);
export const chatConnectionSchema = z.enum([
  "idle",
  "connecting",
  "live",
  "reconnecting",
  "paused",
]);
export const chatErrorKindSchema = z.enum([
  "network",
  "unauthorized",
  "not-found",
  "forbidden",
]);
export const chatSyncWarningSchema = z.enum(["stale", "suspect-empty"]);

export const chatActivitySchema = z.object({
  action: z.string().optional(),
  conversationId: z.string().optional(),
  displayHoldMs: z.number().optional(),
  displayPriority: z.string().optional(),
  displayStrength: z.string().optional(),
  goal: z.string().optional(),
  ownerTurnKey: z.string().min(1),
  phase: z.string().optional(),
  producerEpoch: z.string().min(1).max(128),
  responseKey: z.string().min(1).max(128),
  sequence: z.number().int().positive(),
  sourceMessageIds: z.array(z.string().min(1)).min(1),
  status: z.string().optional(),
  streamIncarnation: z.number().int().positive(),
  summary: z.string().optional(),
  summaryClass: z.enum(["none", "generic", "public"]),
  toolName: z.string().optional(),
  updatedAt: z.number().optional(),
});

export const chatAssistantDraftSchema = z.object({
  conversationId: z.string(),
  draftId: z.string(),
  responseKey: z.string().min(1),
  revision: z.number().int().nonnegative().optional(),
  sourceMessageIds: z.array(z.string().min(1)).min(1),
  status: z.enum(["streaming", "completed"]),
  text: z.string(),
});

export const chatBoundWorkerSchema = z.object({
  participantId: z.string().min(1),
  actorId: z.string().optional(),
  name: z.string(),
});

export const chatParticipantStatusSchema = z.object({
  workingProvider: z.enum(["wechat", "telegram", "signal"]).optional(),
  loopWake: z.boolean().optional(),
  actorId: z.string().optional(),
  actorRole: z.enum(["router", "worker"]).optional(),
  conversationId: z.string().min(1),
  // Stable reason code published only alongside the error state; clients key
  // localized copy off it instead of showing the runtime's own English text.
  issue: z.string().min(1).optional(),
  participantId: z.string().min(1),
  name: z.string().optional(),
  state: z.enum(["active", "error", "stopped"]),
  status: z.string(),
  updatedAt: z.number(),
});

export const chatConversationRefSchema = z.object({
  conversationId: z.string(),
  kind: z.string().optional(),
  title: z.string().optional(),
});

export const chatAgentBlobRefSchema = z
  .object({
    hash: z.string().length(64),
    kind: z.literal("blob"),
    size: z
      .number()
      .int()
      .nonnegative()
      .max(512 * 1024 * 1024),
    uuid: z.string().length(32),
  })
  .strict();

export const chatAttachmentSchema = z.object({
  agentId: z.string().optional(),
  /**
   * Position of this attachment in its message, present only when the server
   * can serve its bytes. Absent means the attachment is descriptive only.
   */
  attachmentIndex: z.number().int().nonnegative().optional(),
  blockType: z.enum(["file", "image"]),
  blobRef: chatAgentBlobRefSchema.optional(),
  fileName: z.string().optional(),
  localFileRef: z.string().optional(),
  mimeType: z.string().optional(),
  size: z.number().optional(),
  title: z.string().optional(),
  workspacePath: z.string().optional(),
});

const chatAgentImageBlobRefSchema = chatAgentBlobRefSchema.extend({
  size: z.number().int().positive().max(chatAttachmentUploadMaxBytes),
});

export const chatInlineTaskSchema = z.object({
  activityStatus: z.string().optional(),
  conversationId: z.string().optional(),
  freshness: z.enum(["fresh", "stale", "unknown"]).optional(),
  status: z.string().optional(),
  title: z.string().optional(),
  unavailable: z.boolean(),
  updatedAt: z.number().optional(),
});

export const chatMessagePartSchema = z.discriminatedUnion("kind", [
  z.object({
    kind: z.literal("dynamic-ui"),
    uiRef: z.string().min(1).max(100),
    contentId: z.string().min(1),
    originTaskId: z.string().optional(),
    summary: z.string().max(4000),
    version: z.number().int(),
    conversationId: z.string(),
    messageId: z.string(),
    attachmentIndex: z.number().int().nonnegative(),
  }),
  z.object({
    kind: z.literal("markdown"),
    task: z.never().optional(),
    text: z.string(),
  }),
  z.object({
    kind: z.literal("inline-task"),
    task: chatInlineTaskSchema,
    text: z.never().optional(),
  }),
]);

export const chatMessageSchema = z
  .object({
    actorId: z.string().min(1).optional(),
    actorRole: z.enum(["router", "worker"]).optional(),
    attachments: z.array(chatAttachmentSchema),
    blocksKey: z.string().optional(),
    clientRequestId: z.string().optional(),
    createdAt: z.number().optional(),
    createdBy: z.string().optional(),
    delivery: chatMessageDeliverySchema,
    error: z.string().optional(),
    failureAction: z.enum(["billing"]).optional(),
    messageId: z.string(),
    replyToMessageId: z.string().optional(),
    threadRootMessageId: z.string().optional(),
    parts: z.array(chatMessagePartSchema).optional(),
    platformSource: z.string().min(1).max(64).optional(),
    refs: z.array(chatConversationRefSchema),
    role: z.string(),
    source: z.enum(["server", "pending"]),
    status: z.string().optional(),
    text: z.string(),
  })
  .meta({ id: "CommaChatMessage" });

export const chatPendingSendSchema = z.object({
  clientRequestId: z.string(),
  createdAt: z.number(),
  error: z.string().optional(),
  failureAction: z.enum(["billing"]).optional(),
  skills: z.array(z.object({ location: z.string() })).optional(),
  replyToMessageId: z.string().optional(),
  status: z.enum(["sending", "failed"]),
  text: z.string(),
});

export const chatDraftAttachmentSchema = z.object({
  error: z.string().optional(),
  id: z.string(),
  isImage: z.boolean(),
  name: z.string(),
  path: z.string().optional(),
  size: z.number(),
  status: z.enum(["uploading", "uploaded", "failed"]),
});

export const chatConversationSummarySchema = z.object({
  /** Device platform the Task was asked from; only meaningful with origin "comma". */
  clientPlatform: z.string().optional(),
  createdAt: z.number().optional(),
  groupId: z.string(),
  id: z.string(),
  kind: z.enum(["user_chat", "agent_task"]),
  /** Catalog label ids applied to the Task. */
  labels: z.array(z.string()).optional(),
  /** Where the Task was asked for: a provider ("slack", "telegram") or "comma". */
  origin: z.string().optional(),
  reviewVersion: z.number().int().positive().optional(),
  schedule: z.json().optional(),
  status: z.string(),
  title: z.string(),
  updatedAt: z.number().optional(),
  workspaceId: z.string(),
});

export const conversationProjectionSchema = z.object({
  activity: chatActivitySchema.optional(),
  assistantDraft: chatAssistantDraftSchema.optional(),
  /**
   * Whether Main still holds an unsettled attachment intake for this
   * conversation. This spans the whole claim — not just the open dialog,
   * since the files are imported after it closes. Renderer-side
   * single-flight is a UX convenience, never the boundary, so the control it
   * guards is driven by this authoritative signal rather than by a reply the
   * transport may never deliver.
   */
  attachmentIntakeInFlight: z.boolean().optional(),
  awaitingReply: z.boolean(),
  awaitingSince: z.number().optional(),
  awaitingTimedOut: z.boolean(),
  awaitingTurnKey: z.string().min(1).optional(),
  locallyAwaitingReply: z.boolean().optional(),
  connection: chatConnectionSchema,
  conversation: chatConversationSummarySchema.optional(),
  draft: z.string(),
  draftAttachments: z.array(chatDraftAttachmentSchema),
  errorKind: chatErrorKindSchema.optional(),
  lastBackoffMs: z.number(),
  messages: z.array(chatMessageSchema),
  pending: z.array(chatPendingSendSchema),
  participantStatus: chatParticipantStatusSchema.optional(),
  participantStatuses: z.array(chatParticipantStatusSchema).max(2).optional(),
  boundWorker: chatBoundWorkerSchema.optional(),
  serverMessages: z.array(chatMessageSchema),
  status: z.enum(["idle", "loading", "ready", "error"]),
  syncWarning: chatSyncWarningSchema.optional(),
});

export const chatSurfaceProjectionSchema = z.object({
  generation: z.number().int().nonnegative(),
  state: conversationProjectionSchema,
  subscriberId: z.string().min(1),
});

export const chatRuntimeSessionSchema = z.object({
  conversationId: z.string(),
  groupId: z.string(),
  draftEpoch: z.number().int().nonnegative().optional(),
  draftOwnerSurfaceId: z.string().optional(),
  key: z.string(),
  refs: z.number().int().nonnegative(),
  revision: z.number().int().nonnegative(),
  state: conversationProjectionSchema,
  surfaceProjections: z
    .array(chatSurfaceProjectionSchema)
    .max(chatSurfaceProjectionLimit)
    .optional(),
  workspaceId: z.string(),
});

export const chatRuntimeSnapshotSchema = z.object({
  protocolVersion: z.literal(chatProtocolVersion),
  revision: z.number().int().nonnegative(),
  sideChatSessionKey: z.string().optional(),
  sessions: z.array(chatRuntimeSessionSchema),
});

/**
 * One retained Conversation's composer draft, versioned by Main's draft epoch.
 * The epoch orders every change to Main's draft, including edits from other
 * surfaces and a send consuming it.
 */
export const chatRuntimeDraftSchema = z.object({
  draft: z.string(),
  draftEpoch: z.number().int().nonnegative(),
  key: z.string(),
});

/**
 * Every retained Conversation's draft, published apart from the runtime
 * snapshot. A keystroke is the runtime's most frequent change, so it must
 * cost O(drafts) rather than re-serializing every retained transcript. The
 * runtime snapshot still carries each draft for state reads and ordinary
 * publishes.
 */
export const chatRuntimeDraftsSnapshotSchema = z.object({
  drafts: z.array(chatRuntimeDraftSchema),
  protocolVersion: z.literal(chatProtocolVersion),
});

export const chatTargetSchema = z.object({
  conversationId: z.string().min(1),
  groupId: z.string().min(1),
  workspaceId: z.string().min(1),
});

export const chatSubscriberInputSchema = chatTargetSchema.extend({
  subscriberId: z.string().min(1),
});

export const chatLeaseSchema = z.object({
  leaseId: z.uuid(),
  subscriberId: z.string().min(1),
});

export const chatLeasedTargetSchema = chatTargetSchema.extend(chatLeaseSchema.shape);

export const chatRetainInputSchema = chatLeasedTargetSchema;

export const chatReleaseInputSchema = chatRetainInputSchema;

export const chatSetDraftInputSchema = chatTargetSchema.extend({
  draft: z.string(),
  surfaceId: z.string().min(1),
});

const chatSendIntentIdSchema = z.string().min(8).max(128);

export const chatBeginSendIntentInputSchema = chatTargetSchema.extend({
  sendIntentId: chatSendIntentIdSchema,
  surfaceId: z.string().min(1),
});

export const chatSendInputSchema = chatTargetSchema.extend({
  /**
   * Main-owned id returned by beginSendIntent. The reservation binds this
   * send to its exact click-sequenced draft epoch; send never trusts a
   * renderer-owned epoch shadow.
   */
  sendIntentId: chatSendIntentIdSchema,
  /**
   * An owning surface may opt out of consuming the shared draft. Omission keeps
   * the normal ownership-derived behavior. Main intersects any requested value
   * with ownership, so a non-owner can never acquire consumption authority.
   */
  consumeDraft: z.boolean().optional(),
  skills: z.array(z.object({ location: z.string() })).optional(),
  replyToMessageId: z.string().optional(),
  surfaceId: z.string().min(1),
  text: z.string(),
});

export const chatClientRequestInputSchema = chatTargetSchema.extend({
  clientRequestId: z.string().min(1),
});

/**
 * Acknowledges the terminal failure outcome of an attachment intake. Main
 * retains and projects a failed intake's outcome — blocking send — after the
 * exact surface lease confirms delivery. Acknowledgement never clears the
 * gate; only explicit remove/retry of the exact projected row does.
 */
export const chatAcknowledgeIntakeFailuresInputSchema = chatTargetSchema.extend({
  intakeId: z.string().min(1).max(128),
  surfaceId: z.string().min(1),
});

export const chatAttachInputSchema = chatTargetSchema.extend({
  bytes: z.instanceof(Uint8Array),
  name: z.string().min(1),
  size: z.number().int().nonnegative(),
  surfaceId: z.string().min(1),
});

export const chatLocalFileSchema = z
  .object({
    localFileRef: z.string().regex(/^lfi1_[A-Za-z0-9_-]{43}$/),
    mediaType: z.string().trim().min(1).max(255),
    name: z.string().trim().min(1).max(255),
    size: z
      .number()
      .int()
      .nonnegative()
      .max(512 * 1024 * 1024),
  })
  .strict();

export const chatAttachLocalFilesInputSchema = chatTargetSchema.extend({
  files: z.array(chatLocalFileSchema).min(1).max(50),
  surfaceId: z.string().min(1),
});

export const chatAttachmentSourceSchema = z.discriminatedUnion("kind", [
  z
    .object({
      kind: z.literal("path"),
      sourcePath: z.string().min(1).max(4096),
    })
    .strict(),
  z
    .object({
      kind: z.literal("upload"),
      name: z.string().min(1).max(255),
      bytes: z
        .instanceof(Uint8Array)
        .refine((bytes) => bytes.byteLength <= chatAttachmentUploadMaxBytes),
      size: z.number().int().nonnegative().max(chatAttachmentUploadMaxBytes),
    })
    .strict(),
]);
export type ChatAttachmentSource = z.infer<typeof chatAttachmentSourceSchema>;

export const chatPickAttachmentsInputSchema = chatTargetSchema.extend({
  maxFiles: z.number().int().min(0).max(50),
  maxTotalSize: z
    .number()
    .int()
    .min(0)
    .max(1024 * 1024 * 1024),
  maxUploadFiles: z.number().int().min(0).max(chatAttachmentUploadLimit),
  sources: z.array(chatAttachmentSourceSchema).min(1).max(58).optional(),
  surfaceId: z.string().min(1),
});

export const chatPickAttachmentErrorSchema = z
  .object({
    errorClass: z.enum([
      "connector_reconfiguration_required",
      "local_file_corrupt",
      "local_file_too_large",
      "local_file_unavailable",
      "local_file_unsupported",
      "too_many_local_files",
    ]),
    isImage: z.boolean().optional(),
    message: z.string().trim().min(1).max(160),
    name: z.string().trim().min(1).max(255).optional(),
    retryable: z.boolean(),
  })
  .strict();

export const chatAttachmentIdInputSchema = chatTargetSchema.extend({
  attachmentId: z.string().min(1),
  surfaceId: z.string().min(1),
});

export const chatLeasedSetDraftInputSchema = chatSetDraftInputSchema.extend(
  chatLeaseSchema.shape
);

export const chatLeasedBeginSendIntentInputSchema =
  chatBeginSendIntentInputSchema.extend(chatLeaseSchema.shape);

export const chatLeasedSendInputSchema = chatSendInputSchema.extend(
  chatLeaseSchema.shape
);

export const chatLeasedClientRequestInputSchema = chatClientRequestInputSchema.extend(
  chatLeaseSchema.shape
);

export const chatLeasedAttachInputSchema = chatAttachInputSchema.extend(
  chatLeaseSchema.shape
);

export const chatLeasedAttachLocalFilesInputSchema =
  chatAttachLocalFilesInputSchema.extend(chatLeaseSchema.shape);

export const chatLeasedPickAttachmentsInputSchema =
  chatPickAttachmentsInputSchema.extend(chatLeaseSchema.shape);

export const chatLeasedAttachmentIdInputSchema = chatAttachmentIdInputSchema.extend(
  chatLeaseSchema.shape
);

export const chatLeasedAcknowledgeIntakeFailuresInputSchema =
  chatAcknowledgeIntakeFailuresInputSchema.extend(chatLeaseSchema.shape);

export const chatWorkspaceResolutionSchema = z.discriminatedUnion("status", [
  z.object({ status: z.literal("hidden") }),
  z.object({ status: z.literal("unauthorized") }),
  z.object({
    groupId: z.string(),
    retryAfterSeconds: z.number().int().positive(),
    status: z.literal("provisioning"),
    workspaceId: z.string(),
  }),
  z.object({
    conversationId: z.string(),
    createdAt: z.number().finite().optional(),
    groupId: z.string(),
    status: z.literal("ready"),
    updatedAt: z.number().finite().optional(),
    workspaceId: z.string(),
  }),
]);

export const chatSkillSchema = z.object({
  description: z.string().optional(),
  location: z.string(),
  name: z.string(),
  skill_id: z.string(),
});

export const chatWorkspaceSkillsInputSchema = z.object({
  workspaceId: z.string().min(1),
});

export const chatReadUploadedGroupImageInputSchema = z
  .object({
    groupId: z.string().min(1).max(160),
    path: z
      .string()
      .min(1)
      .max(1024)
      .regex(/^\/uploads\/[A-Za-z0-9_-]{22}-[A-Za-z0-9._-]+\.(?:png|jpe?g|gif|webp)$/i),
    source: z.literal("group-file"),
  })
  .strict();

export const chatReadAgentBlobImageInputSchema = z
  .object({
    agentId: z.string().min(1).max(160),
    blobRef: chatAgentImageBlobRefSchema,
    fileName: z.string().trim().min(1).max(255),
    groupId: z.string().min(1).max(160),
    mediaType: z.enum(["image/png", "image/jpeg", "image/gif", "image/webp"]),
    source: z.literal("agent-blob"),
  })
  .strict();

export const chatReadGroupImageInputSchema = z.discriminatedUnion("source", [
  chatReadUploadedGroupImageInputSchema,
  chatReadAgentBlobImageInputSchema,
]);

export const chatGroupImagePreviewSchema = z.custom<Uint8Array>(
  (value) =>
    value instanceof Uint8Array && value.byteLength <= chatImagePreviewMaxBytes,
  "Expected preview bytes no larger than 8 MiB."
);

export const chatCommandReceiptSchema = z.object({
  /** Present on draft-mutating receipts: the resulting Main draft epoch. */
  draftEpoch: z.number().int().nonnegative().optional(),
  revision: z.number().int().nonnegative(),
});

export const chatBeginSendIntentReceiptSchema = chatCommandReceiptSchema
  .extend({
    draftEpoch: z.number().int().nonnegative(),
    sendIntentId: chatSendIntentIdSchema,
  })
  .strict();

export const chatPickAttachmentsResultSchema = chatCommandReceiptSchema
  .extend({
    cancelled: z.boolean(),
    errors: z.array(chatPickAttachmentErrorSchema).max(50),
    intakeId: z.string().min(1).max(128),
  })
  .strict();

export const sideChatSnapshotStatusSchema = z.enum([
  "signed-out",
  "resolving",
  "ready",
  "error",
  "unavailable",
]);

export const sideChatFrameSchema = z.object({
  height: z.number().nonnegative(),
  width: z.number().nonnegative(),
  x: z.number(),
  y: z.number(),
});

export const sideChatPresentationPhaseSchema = z.enum([
  "closed",
  "opening",
  "interactive",
  "open",
  "closing",
]);

/**
 * The native gesture partner owns reveal progress and screen placement, while
 * Electron owns the window, backdrop backing, and renderer. This snapshot is
 * the single hand-off point that keeps those three consumers in lockstep.
 * Frames use AppKit's global bottom-left coordinate space; Electron Main is
 * responsible for converting the window frame before applying BrowserWindow
 * bounds.
 */
export const sideChatPresentationSchema = z.object({
  availableContentHeight: z.number().nonnegative(),
  contentFrame: sideChatFrameSchema,
  displayId: z.number().int().nonnegative(),
  kind: z.literal("side-chat.presentation"),
  offsetX: z.number(),
  phase: sideChatPresentationPhaseSchema,
  progress: z.number().min(0).max(1),
  protocolVersion: z.literal(chatProtocolVersion),
  revision: z.number().int().nonnegative(),
  screenFrame: sideChatFrameSchema,
  windowFrame: sideChatFrameSchema,
});

export const sideChatContentSizeInputSchema = z.object({
  height: z.number().finite().min(40).max(4_096),
  // Omitted means the entire requested surface is visible (no resize reserve).
  visualHeight: z.number().finite().min(40).max(4_096).optional(),
  width: z.number().finite().min(120).max(1_024),
});

/**
 * Main-owned, ephemeral tuning values for the Electron Side Chat surface.
 * The ranges intentionally mirror the controls from the previous native
 * Debug settings tab. Motion constants are deliberately not part of this
 * contract because that tab never exposed them.
 */
export const sideChatDebugSettingsValuesSchema = z.object({
  allowsGroupBlending: z.boolean(),
  allowsInPlaceFiltering: z.boolean(),
  blurRadius: z.number().finite().min(0).max(90),
  bottomFeather: z.number().finite().min(0).max(220),
  bottomOffset: z.number().finite().min(-160).max(160),
  closedExtraOffset: z.number().finite().min(0).max(260),
  contentOffsetX: z.number().finite().min(-160).max(160),
  contentOffsetY: z.number().finite().min(-160).max(160),
  contentWidth: z.number().finite().min(260).max(620),
  disablesOccludedBackdropBlurs: z.boolean(),
  leftFeather: z.number().finite().min(0).max(220),
  maskGamma: z.number().finite().min(0.2).max(3),
  maxMaskAlpha: z.number().finite().min(0).max(1),
  openXOffset: z.number().finite().min(-220).max(120),
  rightFeather: z.number().finite().min(0).max(220),
  showBackdrop: z.boolean(),
  solidOutsetBottom: z.number().finite().min(-120).max(160),
  solidOutsetLeft: z.number().finite().min(-120).max(160),
  solidOutsetRight: z.number().finite().min(-120).max(160),
  solidOutsetTop: z.number().finite().min(-120).max(160),
  tintOpacity: z.number().finite().min(0).max(1),
  topFeather: z.number().finite().min(0).max(220),
  windowServerAware: z.boolean(),
});

export const sideChatGeometrySettingsSchema = sideChatDebugSettingsValuesSchema.pick({
  bottomFeather: true,
  bottomOffset: true,
  closedExtraOffset: true,
  contentOffsetX: true,
  contentOffsetY: true,
  contentWidth: true,
  leftFeather: true,
  openXOffset: true,
  rightFeather: true,
  solidOutsetBottom: true,
  solidOutsetLeft: true,
  solidOutsetRight: true,
  solidOutsetTop: true,
  topFeather: true,
});

export const sideChatInteractiveProgressInputSchema = z.object({
  progress: z.number().finite().min(0).max(1),
});

export const sideChatInteractiveCompletionInputSchema = z.object({
  shouldOpen: z.boolean(),
});

// Omitting keyCode unregisters the current hotkey; Main replays this cleared state.
export const sideChatShortcutRegistrationInputSchema = z.object({
  keyCode: z.number().int().nonnegative().max(127).optional(),
  modifiers: z.number().int().nonnegative().max(65_535),
});

/**
 * One row of the macOS menu-bar menu, which the Side Chat helper draws so that
 * hovering it never waits on Electron Main. A shortcut is display text only;
 * the helper reports a chosen row by its opaque id and runs nothing itself.
 */
export const statusMenuRowSchema = z.object({
  id: z.string().min(1).max(256).optional(),
  kind: z.enum(["header", "item", "separator"]),
  shortcut: z.string().min(1).max(64).optional(),
  title: z.string().max(1024).optional(),
});

/**
 * Deliberately smaller than ConversationProjection. Renderer-owned draft text,
 * local attachment paths, retry queues, cursors, and server caches must remain
 * in Electron Main and never cross into the native view helper.
 */
export const sideChatConversationProjectionSchema = z.object({
  assistantDraft: chatAssistantDraftSchema.optional(),
  awaitingReply: z.boolean(),
  errorKind: chatErrorKindSchema.optional(),
  messages: z.array(chatMessageSchema).max(sideChatMessageWindow),
});

export const sideChatSessionSchema = z.object({
  conversationId: z.string(),
  groupId: z.string(),
  revision: z.number().int().nonnegative(),
  state: sideChatConversationProjectionSchema,
  workspaceId: z.string(),
});

/**
 * The native helper is assigned exactly one target. Keep this projection
 * structurally single-session so an unrelated renderer conversation can never
 * cross the process boundary by accident.
 */
export const sideChatRuntimeSnapshotSchema = z.object({
  error: z.string().optional(),
  protocolVersion: z.literal(chatProtocolVersion),
  retryAt: z.number().optional(),
  revision: z.number().int().nonnegative(),
  session: sideChatSessionSchema.optional(),
  sessionEpoch: z.number().int().nonnegative(),
  status: sideChatSnapshotStatusSchema,
});

export const sideChatSnapshotEnvelopeSchema = z.object({
  kind: z.literal("chat.snapshot"),
  protocolVersion: z.literal(chatProtocolVersion),
  snapshot: sideChatRuntimeSnapshotSchema,
});

const sideChatCommandEnvelopeShape = {
  protocolVersion: z.literal(chatProtocolVersion),
  requestId: z.string().min(1),
} as const;

const sideChatSessionCommandEnvelopeShape = {
  ...sideChatCommandEnvelopeShape,
  sessionEpoch: z.number().int().nonnegative(),
} as const;

const sideChatCommandVariants = [
  z.object({
    kind: z.literal("side-chat.ready"),
    ...sideChatCommandEnvelopeShape,
  }),
  chatSubscriberInputSchema.extend({
    kind: z.literal("chat.retain"),
    ...sideChatSessionCommandEnvelopeShape,
  }),
  chatSubscriberInputSchema.extend({
    kind: z.literal("chat.release"),
    ...sideChatSessionCommandEnvelopeShape,
  }),
  chatSetDraftInputSchema.extend({
    kind: z.literal("chat.set-draft"),
    ...sideChatSessionCommandEnvelopeShape,
  }),
  chatSendInputSchema.extend({
    kind: z.literal("chat.send"),
    ...sideChatSessionCommandEnvelopeShape,
  }),
  chatTargetSchema.extend({
    kind: z.literal("chat.refresh"),
    ...sideChatSessionCommandEnvelopeShape,
  }),
  chatClientRequestInputSchema.extend({
    kind: z.literal("chat.retry"),
    ...sideChatSessionCommandEnvelopeShape,
  }),
  chatClientRequestInputSchema.extend({
    kind: z.literal("chat.discard"),
    ...sideChatSessionCommandEnvelopeShape,
  }),
] as const;

export const sideChatCommandSchema = z.discriminatedUnion(
  "kind",
  sideChatCommandVariants
);

export const sideChatCommandResultSchema = z.object({
  error: z.string().optional(),
  kind: z.literal("command.result"),
  ok: z.boolean(),
  protocolVersion: z.literal(chatProtocolVersion),
  requestId: z.string(),
});

export const sideChatProtocolErrorSchema = z.object({
  error: z.string(),
  expectedProtocolVersion: z.literal(chatProtocolVersion),
  frameKind: z.string().optional(),
  kind: z.literal("side-chat.protocol-error"),
  protocolVersion: z.literal(chatProtocolVersion),
  receivedProtocolVersion: z.number().int().optional(),
});

const sideChatSurfaceControlVariants = [
  z.object({
    kind: z.literal("side-chat.open"),
    ...sideChatCommandEnvelopeShape,
  }),
  z.object({
    kind: z.literal("side-chat.close"),
    ...sideChatCommandEnvelopeShape,
  }),
  z.object({
    kind: z.literal("side-chat.toggle"),
    ...sideChatCommandEnvelopeShape,
  }),
  z.object({
    kind: z.literal("side-chat.settings"),
    ...sideChatCommandEnvelopeShape,
  }),
  sideChatContentSizeInputSchema.omit({ visualHeight: true }).extend({
    debugSettings: sideChatGeometrySettingsSchema,
    kind: z.literal("side-chat.layout"),
    ...sideChatCommandEnvelopeShape,
  }),
  sideChatInteractiveProgressInputSchema.extend({
    kind: z.literal("side-chat.interactive-progress"),
    ...sideChatCommandEnvelopeShape,
  }),
  sideChatInteractiveCompletionInputSchema.extend({
    kind: z.literal("side-chat.interactive-complete"),
    ...sideChatCommandEnvelopeShape,
  }),
  sideChatShortcutRegistrationInputSchema.extend({
    kind: z.literal("side-chat.shortcut"),
    ...sideChatCommandEnvelopeShape,
  }),
  z.object({
    kind: z.literal("side-chat.stop"),
    ...sideChatCommandEnvelopeShape,
  }),
  // Off: the helper drops the edge gesture and the global shortcut, closes the
  // surface, and ignores open requests until turned on again.
  z.object({
    enabled: z.boolean(),
    kind: z.literal("side-chat.enabled"),
    ...sideChatCommandEnvelopeShape,
  }),
] as const;

export const sideChatSurfaceControlSchema = z.discriminatedUnion(
  "kind",
  sideChatSurfaceControlVariants
);

const statusMenuControlVariants = [
  z.object({
    iconPath: z.string().min(1).max(4096),
    kind: z.literal("status-menu.show"),
    rows: z.array(statusMenuRowSchema).max(64),
    toolTip: z.string().max(256),
    width: z.number().min(120).max(1200),
    ...sideChatCommandEnvelopeShape,
  }),
  z.object({
    kind: z.literal("status-menu.hide"),
    ...sideChatCommandEnvelopeShape,
  }),
] as const;

export const statusMenuSelectSchema = z.object({
  id: z.string().min(1).max(256),
  kind: z.literal("status-menu.select"),
  ...sideChatCommandEnvelopeShape,
});

export const sideChatClientFrameSchema = z.discriminatedUnion("kind", [
  ...sideChatCommandVariants,
  sideChatPresentationSchema,
  statusMenuSelectSchema,
  sideChatCommandResultSchema,
  sideChatProtocolErrorSchema,
]);

export const sideChatHostFrameSchema = z.discriminatedUnion("kind", [
  sideChatSnapshotEnvelopeSchema,
  ...sideChatSurfaceControlVariants,
  ...statusMenuControlVariants,
  sideChatCommandResultSchema,
]);

export type StatusMenuRow = z.infer<typeof statusMenuRowSchema>;
export type ChatActivity = z.infer<typeof chatActivitySchema>;
export type ChatAssistantDraft = z.infer<typeof chatAssistantDraftSchema>;
export type ChatInlineTask = z.infer<typeof chatInlineTaskSchema>;
export type ChatMessagePart = z.infer<typeof chatMessagePartSchema>;
export type ChatInlineMessagePart = Exclude<ChatMessagePart, { kind: "markdown" }>;
export type ChatInlineMessagePartKind = ChatInlineMessagePart["kind"];
export type ChatMessage = z.infer<typeof chatMessageSchema>;
export type ChatPendingSend = z.infer<typeof chatPendingSendSchema>;
export type ConversationProjection = z.infer<typeof conversationProjectionSchema>;
export type ChatSurfaceProjection = z.infer<typeof chatSurfaceProjectionSchema>;
export type ChatRuntimeSession = z.infer<typeof chatRuntimeSessionSchema>;
export type ChatRuntimeSnapshot = z.infer<typeof chatRuntimeSnapshotSchema>;
export type ChatRuntimeDraft = z.infer<typeof chatRuntimeDraftSchema>;
export type ChatRuntimeDraftsSnapshot = z.infer<typeof chatRuntimeDraftsSnapshotSchema>;
export type ChatTarget = z.infer<typeof chatTargetSchema>;
export type ChatSubscriberInput = z.infer<typeof chatSubscriberInputSchema>;
export type ChatLease = z.infer<typeof chatLeaseSchema>;
export type ChatLeasedTarget = z.infer<typeof chatLeasedTargetSchema>;
export type ChatRetainInput = z.infer<typeof chatRetainInputSchema>;
export type ChatReleaseInput = z.infer<typeof chatReleaseInputSchema>;
export type ChatSetDraftInput = z.infer<typeof chatSetDraftInputSchema>;
export type ChatBeginSendIntentInput = z.infer<typeof chatBeginSendIntentInputSchema>;
export type ChatSendInput = z.infer<typeof chatSendInputSchema>;
export type ChatClientRequestInput = z.infer<typeof chatClientRequestInputSchema>;
export type ChatAttachInput = z.infer<typeof chatAttachInputSchema>;
export type ChatLocalFile = z.infer<typeof chatLocalFileSchema>;
export type ChatAttachLocalFilesInput = z.infer<typeof chatAttachLocalFilesInputSchema>;
export type ChatPickAttachmentsInput = z.infer<typeof chatPickAttachmentsInputSchema>;
export type ChatPickAttachmentError = z.infer<typeof chatPickAttachmentErrorSchema>;
export type ChatAttachmentIdInput = z.infer<typeof chatAttachmentIdInputSchema>;
export type ChatLeasedSetDraftInput = z.infer<typeof chatLeasedSetDraftInputSchema>;
export type ChatLeasedBeginSendIntentInput = z.infer<
  typeof chatLeasedBeginSendIntentInputSchema
>;
export type ChatLeasedSendInput = z.infer<typeof chatLeasedSendInputSchema>;
export type ChatLeasedClientRequestInput = z.infer<
  typeof chatLeasedClientRequestInputSchema
>;
export type ChatLeasedAttachInput = z.infer<typeof chatLeasedAttachInputSchema>;
export type ChatLeasedAttachLocalFilesInput = z.infer<
  typeof chatLeasedAttachLocalFilesInputSchema
>;
export type ChatLeasedPickAttachmentsInput = z.infer<
  typeof chatLeasedPickAttachmentsInputSchema
>;
export type ChatLeasedAcknowledgeIntakeFailuresInput = z.infer<
  typeof chatLeasedAcknowledgeIntakeFailuresInputSchema
>;
export type ChatLeasedAttachmentIdInput = z.infer<
  typeof chatLeasedAttachmentIdInputSchema
>;
export type ChatWorkspaceResolution = z.infer<typeof chatWorkspaceResolutionSchema>;
export type ChatSkill = z.infer<typeof chatSkillSchema>;
export type ChatWorkspaceSkillsInput = z.infer<typeof chatWorkspaceSkillsInputSchema>;
export type ChatReadGroupImageInput = z.infer<typeof chatReadGroupImageInputSchema>;
export type ChatCommandReceipt = z.infer<typeof chatCommandReceiptSchema>;
export type ChatBeginSendIntentReceipt = z.infer<
  typeof chatBeginSendIntentReceiptSchema
>;
export type ChatPickAttachmentsResult = z.infer<typeof chatPickAttachmentsResultSchema>;
export type SideChatFrame = z.infer<typeof sideChatFrameSchema>;
export type SideChatPresentationPhase = z.infer<typeof sideChatPresentationPhaseSchema>;
export type SideChatPresentation = z.infer<typeof sideChatPresentationSchema>;
export type SideChatContentSizeInput = z.infer<typeof sideChatContentSizeInputSchema>;
export type SideChatDebugSettingsValues = z.infer<
  typeof sideChatDebugSettingsValuesSchema
>;
export type SideChatGeometrySettings = z.infer<typeof sideChatGeometrySettingsSchema>;
export type SideChatInteractiveProgressInput = z.infer<
  typeof sideChatInteractiveProgressInputSchema
>;
export type SideChatInteractiveCompletionInput = z.infer<
  typeof sideChatInteractiveCompletionInputSchema
>;
export type SideChatShortcutRegistrationInput = z.infer<
  typeof sideChatShortcutRegistrationInputSchema
>;
export type SideChatConversationProjection = z.infer<
  typeof sideChatConversationProjectionSchema
>;
export type SideChatSession = z.infer<typeof sideChatSessionSchema>;
export type SideChatRuntimeSnapshot = z.infer<typeof sideChatRuntimeSnapshotSchema>;
export type SideChatSnapshotEnvelope = z.infer<typeof sideChatSnapshotEnvelopeSchema>;
export type SideChatCommand = z.infer<typeof sideChatCommandSchema>;
export type SideChatCommandResult = z.infer<typeof sideChatCommandResultSchema>;
export type SideChatProtocolError = z.infer<typeof sideChatProtocolErrorSchema>;
export type SideChatSurfaceControl = z.infer<typeof sideChatSurfaceControlSchema>;
export type SideChatClientFrame = z.infer<typeof sideChatClientFrameSchema>;
export type SideChatHostFrame = z.infer<typeof sideChatHostFrameSchema>;

export const emptyChatRuntimeSnapshot: ChatRuntimeSnapshot = {
  protocolVersion: chatProtocolVersion,
  revision: 0,
  sessions: [],
};

export const emptyChatRuntimeDraftsSnapshot: ChatRuntimeDraftsSnapshot = {
  drafts: [],
  protocolVersion: chatProtocolVersion,
};
