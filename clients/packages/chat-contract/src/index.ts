import { z } from "zod";

export const chatProtocolVersion = 3 as const;
export const chatSurfaceProjectionLimit = 8 as const;
export const chatAttachmentUploadLimit = 8 as const;
export const chatAttachmentUploadMaxBytes = 10_000_000 as const;
/**
 * The most a client reads of a file whole into memory (`files.read`) or hands to a native save as bytes. An attachment
 * may be larger: it downloads in ranges (`fileStream`) instead.
 */
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
  target: z.string().optional(),
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
  /** The text as the core parsed it so far (`@comma/core/markdown`'s tree): blocks still open are `loading`. */
  markdown: z.array(z.json()).optional().meta({ "x-comma-native-omit": true }),
});

export const chatBoundWorkerSchema = z.object({
  participantId: z.string().min(1),
  actorId: z.string().optional(),
  name: z.string(),
});

/**
 * What a coding Task's sandbox and GitHub answered last, as the server keeps it from the end of the Worker's last turn
 * or a surface's last read: the Task's panel shows it until its own reads answer. A part is there once it was read.
 */
export const chatCodingFactsSchema = z.object({
  /** The tokens the Session's model calls used (input includes the cached part); null when it made none. */
  usage: z
    .object({
      modelCalls: z.number(),
      inputTokens: z.number(),
      cachedTokens: z.number(),
      outputTokens: z.number(),
      model: z.string().nullable(),
    })
    .nullable()
    .optional(),
  /** What the whole branch changes against its base: how many files, and the lines they add and remove. */
  changes: z
    .object({ files: z.number(), additions: z.number(), deletions: z.number() })
    .optional(),
  /** The branch's pull request as GitHub had it, without its description; null when it had none. */
  pullRequest: z
    .object({
      url: z.string(),
      number: z.number().nullable(),
      title: z.string().nullable(),
      body: z.null(),
      headSha: z.string().nullable(),
      state: z.enum(["open", "draft", "merged", "closed"]),
      mergeable: z.enum(["mergeable", "conflicting", "unknown"]),
      checks: z
        .object({
          passed: z.number(),
          failed: z.number(),
          skipped: z.number(),
          total: z.number(),
        })
        .nullable(),
      newCommits: z.boolean(),
    })
    .nullable()
    .optional(),
});
export type ChatCodingFacts = z.infer<typeof chatCodingFactsSchema>;

/** Where a Task runs and the model it runs: what its panels show instead of its Agent. */
export const chatTaskRunSchema = z.object({
  place: z.discriminatedUnion("kind", [
    z.object({ kind: z.literal("salix") }),
    z.object({ kind: z.literal("cloud_vm") }),
    z.object({
      kind: z.literal("station"),
      deviceId: z.string().min(1),
      name: z.string().optional(),
    }),
    /** A coding Task's own cloud sandbox: its repository and session branch, and where the sandbox stands. */
    z.object({
      kind: z.literal("sandbox"),
      repo: z.object({
        owner: z.string(),
        name: z.string(),
        baseRef: z.string().optional(),
        branch: z.string().optional(),
      }),
      state: z.string(),
      reason: z.string().optional(),
    }),
  ]),
  model: z
    .discriminatedUnion("kind", [
      z.object({ kind: z.literal("platform") }),
      z.object({ kind: z.literal("catalog"), name: z.string().min(1) }),
      z.object({
        kind: z.literal("runtime"),
        provider: z.string().optional(),
        name: z.string().optional(),
      }),
    ])
    .optional(),
  /**
   * The maker of the model (`anthropic`, `openai`, …; `comma` for Comma's own), whose logo every client shows for
   * the Task's Worker. Absent when the server has not said.
   */
  vendor: z.string().optional(),
  /** A coding Task's (`place` `sandbox`): what its sandbox and GitHub answered last. */
  facts: chatCodingFactsSchema.optional(),
});
export type ChatTaskRun = z.infer<typeof chatTaskRunSchema>;

/**
 * What a person does to a Task from its list or its page, beyond its conversation: archive it, pin it, share a link to
 * it, or switch where it runs and its model (`run`), its place among them (`move`: one that cannot is switched only to
 * another runtime or model where it runs), inside Comma among those places (`comma`: with Comma's own model or on the
 * Cloud VM; one that cannot runs on computers alone).
 */
export const chatTaskActionSchema = z.enum([
  "archive",
  "pin",
  "share",
  "run",
  "move",
  "comma",
]);
export type ChatTaskAction = z.infer<typeof chatTaskActionSchema>;

/**
 * Where a Task is to run from now on and its model (`chatView.setTaskRun`): inside Comma with a catalog model, or the
 * workspace's default Task model (`model` null); on the Cloud VM or a computer with a model of its runtime, or the
 * runtime's default (no `model`), or the place's default (`model` null).
 */
export const chatTaskRunChoiceSchema = z.object({
  runsOn: z.discriminatedUnion("kind", [
    z.object({ kind: z.literal("salix") }),
    z.object({ kind: z.literal("cloud_vm") }),
    z.object({ kind: z.literal("station"), deviceId: z.string().min(1) }),
  ]),
  model: z
    .discriminatedUnion("kind", [
      z.object({
        kind: z.literal("catalog"),
        model: z.string().min(1),
        reasoningEffort: z.string().min(1).optional(),
      }),
      z.object({
        kind: z.literal("runtime"),
        provider: z.enum(["codex", "claude"]),
        model: z.string().min(1).optional(),
      }),
    ])
    .nullable(),
});
export type ChatTaskRunChoice = z.infer<typeof chatTaskRunChoiceSchema>;

export const chatParticipantStatusSchema = z.object({
  workingProvider: z.enum(["wechat", "telegram", "signal"]).optional(),
  loopWake: z.boolean().optional(),
  workingConversationIds: z.array(z.string().min(1)).optional(),
  waiting: z.boolean().optional(),
  waitTool: z.string().optional(),
  waitStartedAt: z.number().optional(),
  actorId: z.string().optional(),
  actorRole: z.enum(["router", "worker"]).optional(),
  conversationId: z.string().min(1),
  // Stable reason code published only alongside the error state; clients key
  // localized copy off it instead of showing the runtime's own English text.
  issue: z.string().min(1).optional(),
  // What a member can fix after a funding stop: the provider source and their
  // own Profile, or when their own subscription resets (Unix seconds).
  issueDetail: z
    .object({
      source: z.string().min(1).optional(),
      profileId: z.string().min(1).optional(),
      profileName: z.string().min(1).optional(),
      resetAt: z.number().positive().optional(),
    })
    .optional(),
  participantId: z.string().min(1),
  name: z.string().optional(),
  state: z.enum(["active", "error", "stopped"]),
  status: z.string(),
  updatedAt: z.number(),
});

export const chatConversationRefSchema = z.object({
  activityStatus: z.string().optional(),
  conversationId: z.string(),
  kind: z.string().optional(),
  status: z.string().optional(),
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
  /** Pixel size, when the block declares one: a list reserves the right shape before the image loads. */
  height: z.number().int().min(1).optional(),
  localFileRef: z.string().optional(),
  mimeType: z.string().optional(),
  size: z.number().optional(),
  title: z.string().optional(),
  /**
   * A file still uploading with its message: the draft attachment it was, whose bytes the core still holds
   * (`chat.readGroupImage`, source `draft-upload`). Absent once it uploaded.
   */
  uploadingId: z.string().optional(),
  width: z.number().int().min(1).optional(),
  workspacePath: z.string().optional(),
});

/**
 * An offer to set up a Comma device found near a phone, as the server keeps it. The offer a message shows is its
 * latest revision: a later `device_setup_offer.updated` event replaces what the message itself carried.
 */
export const chatDeviceSetupOfferSchema = z.object({
  expiresAt: z.number().int().min(1),
  model: z.string().min(1),
  name: z.string().min(1),
  offerId: z.string().min(1),
  reporterDeviceId: z.string().min(1),
  revision: z.number().int().min(1).optional(),
  /** Four hexadecimal digits, upper case: the end of the device's Bluetooth name. */
  shortId: z.string().length(4),
  status: z.string().min(1),
});

export type ChatDeviceSetupOffer = z.infer<typeof chatDeviceSetupOfferSchema>;

const chatAgentImageBlobRefSchema = chatAgentBlobRefSchema.extend({
  size: z.number().int().positive().max(chatAttachmentUploadMaxBytes),
});

export const chatInlineTaskSchema = z.object({
  activityStatus: z.string().optional(),
  conversationId: z.string().optional(),
  status: z.string().optional(),
  /** The section `status` folds into on every client (`taskStatusBucket` in `@comma/i18n`). */
  statusBucket: z
    .enum(["in_progress", "needs_review", "done", "cancelled", "archived"])
    .optional(),
  title: z.string().optional(),
  unavailable: z.boolean(),
  updatedAt: z.number().optional(),
});

/** One choice an Agent's question card offers. */
export const chatQuestionChoiceSchema = z.object({
  id: z.string().min(1).max(32),
  label: z.string().min(1),
  description: z.string().optional(),
  /** What the answer says for the person when they pick it; the label when absent. */
  reply: z.string().optional(),
  recommended: z.boolean().optional(),
});

/**
 * Where a question card stands, read by the core from the transcript: still open, being answered from this
 * device (or that answer failed), answered on the card, skipped, answered by writing in the chat, or replaced by
 * a later question before any answer.
 */
export const chatQuestionStateSchema = z.object({
  status: z.enum([
    "open",
    "sending",
    "failed",
    "answered",
    "skipped",
    "replied",
    "replaced",
  ]),
  /** The choices the answer picked, and its other text, when it was given on the card. */
  choiceIds: z.array(z.string()).optional(),
  other: z.string().optional(),
  /** Why this device's answer was not sent. */
  error: z.string().optional(),
});

/** One item an Agent made or found in an app on the user's Mac, drawn as that app draws it. */
export const chatMacAppItemSchema = z.object({
  app: z.enum(["calendar", "reminders", "notes", "contacts", "maps"]),
  itemId: z.string().optional(),
  title: z.string(),
  start: z.string().optional(),
  end: z.string().optional(),
  allDay: z.boolean().optional(),
  calendar: z.string().optional(),
  color: z.string().optional(),
  location: z.string().optional(),
  due: z.string().optional(),
  completed: z.boolean().optional(),
  list: z.string().optional(),
  folder: z.string().optional(),
  detail: z.string().optional(),
  address: z.string().optional(),
  latitude: z.number().optional(),
  longitude: z.number().optional(),
  category: z.string().optional(),
});
export type ChatMacAppItem = z.infer<typeof chatMacAppItemSchema>;

export const chatMessagePartSchema = z.discriminatedUnion("kind", [
  z.object({
    kind: z.literal("mac-app-item"),
    item: chatMacAppItemSchema,
    task: z.never().optional(),
    text: z.never().optional(),
  }),
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
    kind: z.literal("mini-app"),
    /** The Mini App and the Version the Task's agent deployed (a preview until it is published). */
    appId: z.string().min(1).max(256),
    appVersion: z.number().int().positive(),
    name: z.string().max(200),
    /** Equals the message's text; Task Share shows only this. */
    summary: z.string().max(4000),
    conversationId: z.string(),
    messageId: z.string(),
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
  z.object({
    kind: z.literal("device-setup-offer"),
    offer: chatDeviceSetupOfferSchema,
    task: z.never().optional(),
    text: z.never().optional(),
  }),
  z.object({
    kind: z.literal("question"),
    /** The Agent message that asks; the answer replies to it. */
    messageId: z.string(),
    prompt: z.string().min(1),
    choices: z.array(chatQuestionChoiceSchema).min(2).max(6),
    multiSelect: z.boolean(),
    allowOther: z.boolean(),
    state: chatQuestionStateSchema,
    task: z.never().optional(),
    text: z.never().optional(),
  }),
  z.object({
    kind: z.literal("question-answer"),
    questionMessageId: z.string(),
    choiceIds: z.array(z.string()),
    other: z.string().optional(),
    skipped: z.boolean(),
    task: z.never().optional(),
    text: z.never().optional(),
  }),
]);

/** What a person's message says, read out of its wire text by the core (`decodeUserMessage`). */
export const chatUserMessageDisplaySchema = z.object({
  /** The person's own words: what Copy copies. */
  body: z.string(),
  quotes: z.array(z.string()),
  /** Text attached as a block, such as a Routine item, and the app it came from. */
  texts: z
    .array(z.object({ source: z.string().optional(), text: z.string() }))
    .optional(),
  /** Workspace files the message's attachment list names. */
  files: z.array(z.object({ name: z.string(), path: z.string() })),
  /** The body is this command, shown as `/command`. */
  command: z.string().optional(),
});

/** The milestones an Agent recorded with a message (`milestone` blocks), in order. */
export const chatMessageMilestonesSchema = z.object({
  titles: z.array(z.string()),
  /** The message holds nothing else; no transcript shows it. */
  standalone: z.boolean(),
});

export const chatTaskActivityEntrySchema = z.object({
  title: z.string(),
  /** When the Agent recorded it (its message's `createdAt`). */
  at: z.number().optional(),
  /** The transcript message to show for it: the Agent's result after it, else the last one before it. */
  messageId: z.string().optional(),
});

export const chatTaskActivityGroupSchema = z.object({
  /**
   * What the milestones follow: the Task's brief, a later message of a person, a request the Router handed in, or
   * a Loop Task's run. Absent for milestones recorded before any of them the transcript holds.
   */
  request: z
    .object({
      /** The request's message; a run has none. */
      messageId: z.string().optional(),
      kind: z.enum(["brief", "follow_up", "run"]),
      /** A follow-up's first line, or the Router's for a request it handed in; empty for the brief and a run, which clients name themselves. */
      text: z.string(),
      /** When it was made; a run's wake time. */
      at: z.number().optional(),
    })
    .optional(),
  entries: z.array(chatTaskActivityEntrySchema),
});

/** A Task's milestones as its Activity, grouped by request or Loop run. `key` is its value, for keeping one object while it holds. */
export const chatTaskActivitySchema = z.object({
  key: z.string(),
  groups: z.array(chatTaskActivityGroupSchema),
  /**
   * The Task's history before what the core holds, while the Activity does not have it yet: `reading` while
   * `chatView.readTaskActivity` reads it, `unread` when a read stopped before the Task's first message (the next call
   * goes on from there). Absent once read, and while nothing was asked.
   */
  earlier: z.enum(["reading", "unread"]).optional(),
});

export const chatMessageSchema = z
  .object({
    actorId: z.string().min(1).optional(),
    actorRole: z.enum(["router", "worker"]).optional(),
    /** Who wrote the canonical message. A system message is a notice, not a reply. */
    actorType: z.enum(["user", "agent", "system"]).optional(),
    attachments: z.array(chatAttachmentSchema),
    blocksKey: z.string().optional(),
    /**
     * The instructions a Task works from: the brief that opens it (`task_command`, or an older Task's request id
     * `delegate-task-<task id>`) or a meeting's saved recording (`meeting_recording`).
     */
    brief: z.boolean().optional(),
    clientRequestId: z.string().optional(),
    // The Comma app a user sent this message from, for display only.
    clientSource: z
      .enum(["iphone", "watch", "android", "mac", "windows", "linux", "web"])
      .optional(),
    createdAt: z.number().optional(),
    createdBy: z.string().optional(),
    /**
     * The Tasks a message announces, each once in order: its inline Task chips that can be opened, then its Task
     * references. A person's mention of a Task is no creation; a person's Quick Chat message (`messageType`
     * `quick_chat`) announces the Task it started, and always carries the field (empty when that Task is unavailable).
     */
    createdTasks: z
      .array(
        z.object({
          conversationId: z.string(),
          title: z.string().optional(),
          updatedAt: z.number().optional(),
        })
      )
      .optional(),
    delivery: chatMessageDeliverySchema,
    /** A person's message as shown; absent on an agent's message and on one from another platform. */
    display: chatUserMessageDisplaySchema.optional(),
    error: z.string().optional(),
    failureAction: z.enum(["billing"]).optional(),
    messageId: z.string(),
    /**
     * What the server says the message is for, e.g. `task_command` on the brief that opens a Task, or `quick_chat` on
     * a person's words said to Quick Chat.
     */
    messageType: z.string().optional(),
    /** A `task_run_blocked` message: why the Task's model could not start, as its station said. */
    runBlockedError: z.string().optional(),
    /**
     * An agent's message as the core parsed it (`@comma/core/markdown`'s tree): text as itself, any other node
     * `[kind, attributes, children?]`, a Task chip or card `["comma-inline", { key }]` naming its part. Every client
     * draws this; none parses a message itself.
     */
    markdown: z.array(z.json()).optional().meta({ "x-comma-native-omit": true }),
    /**
     * The agent speaking to the person in its own words, worth a notification while they are away (the Router in
     * Home chat, or a Task's Router): `preview` is its text as plain words, empty when it sent files alone.
     */
    notice: z.object({ preview: z.string() }).optional(),
    /**
     * The milestones an Agent recorded with the message. A transcript never shows them; the Task's Activity
     * (`ConversationProjection.taskActivity`) does.
     */
    milestones: chatMessageMilestonesSchema
      .optional()
      .meta({ "x-comma-native-omit": true }),
    /**
     * A Router's message that hands a Task a request made elsewhere, such as in Home; the server marks it
     * (`metadata.task_request`). The Task's Activity starts a group at it.
     */
    routerRequest: z.literal(true).optional().meta({ "x-comma-native-omit": true }),
    replyToMessageId: z.string().optional(),
    threadRootMessageId: z.string().optional(),
    parts: z.array(chatMessagePartSchema).optional(),
    platformSource: z.string().min(1).max(64).optional(),
    refs: z.array(chatConversationRefSchema),
    role: z.string(),
    /** The canonical message's place in its conversation; a pending send has none. */
    seq: z.number().int().min(1).optional(),
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
  /** The question card this message answers. */
  questionAnswer: z
    .object({
      questionMessageId: z.string(),
      choiceIds: z.array(z.string()),
      other: z.string().optional(),
      skipped: z.boolean(),
    })
    .optional(),
  status: z.enum(["sending", "failed"]),
  text: z.string(),
});

export const chatDraftAttachmentSchema = z.object({
  /** A message's attachment the server stores by reference: no bytes are held, so it has a thumbnail once stored. */
  byReference: z.literal(true).optional(),
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

/**
 * Where the conversation's next reply stands, as every client shows it (the core's `replyState`): the facts the
 * typing bubble, the thinking line and the timeout notice each read.
 */
export const chatReplyStateSchema = z.object({
  /** A reply is on its way: a send not yet answered, a wait not timed out, or a reply streaming in. */
  coming: z.boolean(),
  /** This client's own send waits for its first answer: the optimistic thinking line. */
  thinking: z.boolean(),
  /** The reply streams in. */
  streaming: z.boolean(),
  /** The agent works on this conversation. */
  working: z.boolean(),
  /** The agent stopped with an error. */
  failed: z.boolean(),
  /** The wait for the reply ran past its bound without one. */
  timedOut: z.boolean(),
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
  /** Images added to a question card's other answer, by the question message: apart from the composer's draft. */
  questionAttachments: z
    .record(z.string(), z.array(chatDraftAttachmentSchema))
    .optional(),
  errorKind: chatErrorKindSchema.optional(),
  /**
   * How much of the conversation's history the transcript holds. `ranges`: the seq ranges read, oldest first; what
   * lies between two of them is a gap not read yet, which closes by itself. `hasOlder`: messages before the oldest
   * one held can be read (`chatView.older`).
   */
  history: z
    .object({
      hasOlder: z.boolean(),
      loadingOlder: z.boolean(),
      ranges: z.array(z.tuple([z.number().int().min(1), z.number().int().min(1)])),
    })
    .optional(),
  lastBackoffMs: z.number(),
  messages: z.array(chatMessageSchema),
  pending: z.array(chatPendingSendSchema),
  participantStatus: chatParticipantStatusSchema.optional(),
  participantStatuses: z.array(chatParticipantStatusSchema).max(2).optional(),
  boundWorker: chatBoundWorkerSchema.optional(),
  taskRun: chatTaskRunSchema.optional(),
  /** What this Task cannot take from here (a station-hosted one: archiving, pinning, a share link, another run). */
  unsupported: z.array(chatTaskActionSchema).optional(),
  /**
   * A Task whose model cannot start: the Worker's last word is its station saying so (a `task_run_blocked` message,
   * `error` why), and the Task has not been switched to another model since. Clients offer to switch it.
   */
  taskRunBlocked: z
    .object({ messageId: z.string().min(1), error: z.string().optional() })
    .optional(),
  reply: chatReplyStateSchema.optional(),
  serverMessages: z.array(chatMessageSchema),
  status: z.enum(["idle", "loading", "ready", "error"]),
  syncWarning: chatSyncWarningSchema.optional(),
  /**
   * A Task's Activity: its milestones by request or Loop run, read from the transcript the core holds and the history
   * before it that `chatView.readTaskActivity` reads.
   */
  taskActivity: chatTaskActivitySchema.optional().meta({ "x-comma-native-omit": true }),
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

/** The statuses a user can end an in-progress or in-review Task with by hand. */
export const manualTaskStatusSchema = z.enum(["completed", "cancelled"]);

export const chatLeasedSetTaskStatusInputSchema = chatLeasedTargetSchema.extend({
  expectedUpdatedAt: z.number().int().positive(),
  status: manualTaskStatusSchema,
});

export const chatLeasedSetTaskRunInputSchema = chatLeasedTargetSchema.extend({
  run: chatTaskRunChoiceSchema,
});

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
  /** Files that go with this message alone, apart from the draft: they upload, then the message lists them. */
  files: z
    .array(
      z.object({
        bytes: z.instanceof(Uint8Array),
        name: z.string().min(1),
        size: z.number().int().nonnegative(),
      })
    )
    .optional(),
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

/**
 * An attachment of a message in the Group, by its position there: the draft names it, and the server stores the same
 * blob as a composer file, so no bytes pass through the client and it has no size bound.
 */
export const chatConversationFileSchema = z
  .object({
    conversationId: z.string().min(1),
    messageId: z.string().min(1),
    index: z.number().int().nonnegative(),
    name: z.string().trim().min(1).max(1024),
    size: z.number().int().nonnegative(),
  })
  .strict();

const chatLeasedAttachConversationFilesInputSchema = chatTargetSchema
  .extend({
    files: z.array(chatConversationFileSchema).min(1),
    surfaceId: z.string().min(1),
  })
  .extend(chatLeaseSchema.shape);

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

export const chatLeasedSendInputSchema = chatSendInputSchema.extend({
  ...chatLeaseSchema.shape,
  /** The request id the message is sent under, when the window must know it before the message shows. */
  clientRequestId: z.string().min(8).max(128).optional(),
});

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

/** An image the core holds while it uploads, by its draft attachment id: shown before the server has it. */
export const chatReadDraftUploadImageInputSchema = z
  .object({
    attachmentId: z.string().min(1).max(160),
    groupId: z.string().min(1).max(160),
    source: z.literal("draft-upload"),
  })
  .strict();

/**
 * An image a message carries by its place in it (`ChatAttachment.attachmentIndex`), with no other source to preview it
 * from: read where its conversation keeps it (Comma's server, or the station of a Task one hosts).
 */
export const chatReadMessageImageInputSchema = z
  .object({
    conversationId: z.string().min(1).max(160),
    fileName: z.string().trim().min(1).max(255),
    groupId: z.string().min(1).max(160),
    index: z.number().int().nonnegative(),
    messageId: z.string().min(1).max(160),
    source: z.literal("attachment"),
  })
  .strict();

export const chatReadGroupImageInputSchema = z.discriminatedUnion("source", [
  chatReadUploadedGroupImageInputSchema,
  chatReadAgentBlobImageInputSchema,
  chatReadDraftUploadImageInputSchema,
  chatReadMessageImageInputSchema,
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

/**
 * One row of the macOS menu-bar menu, which the menu-bar helper draws so that
 * hovering it never waits on Electron Main. A shortcut is display text only;
 * the helper reports a chosen row by its opaque id and runs nothing itself.
 * A meter is a usage row that cannot be chosen: its title, its detail at the
 * right, and under them a bar filled to `fraction` when that is set.
 */
export const statusMenuRowSchema = z.object({
  id: z.string().min(1).max(256).optional(),
  kind: z.enum(["header", "item", "separator", "meter"]),
  shortcut: z.string().min(1).max(64).optional(),
  title: z.string().max(1024).optional(),
  // At the right: an item's status in a grey capsule ("Updated just now"), a
  // meter's figure as grey text.
  detail: z.string().min(1).max(128).optional(),
  fraction: z.number().min(0).max(1).optional(),
  // A meter that is nearly spent draws its bar red.
  tone: z.enum(["normal", "critical"]).optional(),
});

const statusMenuEnvelopeShape = {
  protocolVersion: z.literal(chatProtocolVersion),
  requestId: z.string().min(1),
} as const;

const statusMenuControlVariants = [
  z.object({
    // When set, the helper reports this id with status-menu.select each time the
    // menu closes, after the id of the row chosen from it.
    closeId: z.string().min(1).max(256).optional(),
    // When set, the helper reports this id with status-menu.select each time the
    // menu opens, and rows that arrive while it is open update the rows it shows
    // in place where they can: Main says its times from then.
    openId: z.string().min(1).max(256).optional(),
    iconPath: z.string().min(1).max(4096),
    kind: z.literal("status-menu.show"),
    rows: z.array(statusMenuRowSchema).max(64),
    toolTip: z.string().max(256),
    width: z.number().min(120).max(1200),
    ...statusMenuEnvelopeShape,
  }),
  z.object({
    kind: z.literal("status-menu.hide"),
    ...statusMenuEnvelopeShape,
  }),
] as const;

/** Main to the menu-bar helper. */
export const statusMenuHostFrameSchema = z.discriminatedUnion(
  "kind",
  statusMenuControlVariants
);

/** The menu-bar helper to Main: started, a chosen row, a command's result, or a frame it refused. */
export const statusMenuClientFrameSchema = z.discriminatedUnion("kind", [
  z.object({
    kind: z.literal("status-menu.ready"),
    ...statusMenuEnvelopeShape,
  }),
  z.object({
    id: z.string().min(1).max(256),
    kind: z.literal("status-menu.select"),
    ...statusMenuEnvelopeShape,
  }),
  z.object({
    error: z.string().optional(),
    kind: z.literal("status-menu.result"),
    ok: z.boolean(),
    ...statusMenuEnvelopeShape,
  }),
  z.object({
    error: z.string(),
    expectedProtocolVersion: z.literal(chatProtocolVersion),
    frameKind: z.string().optional(),
    kind: z.literal("status-menu.protocol-error"),
    protocolVersion: z.literal(chatProtocolVersion),
    receivedProtocolVersion: z.number().int().optional(),
  }),
]);

export type StatusMenuRow = z.infer<typeof statusMenuRowSchema>;
export type ChatActivity = z.infer<typeof chatActivitySchema>;
export type ChatAssistantDraft = z.infer<typeof chatAssistantDraftSchema>;
export type ChatInlineTask = z.infer<typeof chatInlineTaskSchema>;
export type ChatMessagePart = z.infer<typeof chatMessagePartSchema>;
export type ChatMessageMilestones = z.infer<typeof chatMessageMilestonesSchema>;
export type ChatTaskActivity = z.infer<typeof chatTaskActivitySchema>;
export type ChatTaskActivityGroup = z.infer<typeof chatTaskActivityGroupSchema>;
export type ChatTaskActivityEntry = z.infer<typeof chatTaskActivityEntrySchema>;
export type ChatInlineMessagePart = Exclude<ChatMessagePart, { kind: "markdown" }>;
export type ChatInlineMessagePartKind = ChatInlineMessagePart["kind"];
export type ChatQuestionPart = Extract<ChatMessagePart, { kind: "question" }>;
export type ChatQuestionAnswerPart = Extract<
  ChatMessagePart,
  { kind: "question-answer" }
>;
export type ChatQuestionChoice = z.infer<typeof chatQuestionChoiceSchema>;
export type ChatQuestionState = z.infer<typeof chatQuestionStateSchema>;
export type ChatMessage = z.infer<typeof chatMessageSchema>;
export type ChatPendingSend = z.infer<typeof chatPendingSendSchema>;
export type ChatReplyState = z.infer<typeof chatReplyStateSchema>;
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
export type ManualTaskStatus = z.infer<typeof manualTaskStatusSchema>;
export type ChatLeasedSetTaskStatusInput = z.infer<
  typeof chatLeasedSetTaskStatusInputSchema
>;
export type ChatLeasedSetTaskRunInput = z.infer<typeof chatLeasedSetTaskRunInputSchema>;
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
export type ChatConversationFile = z.infer<typeof chatConversationFileSchema>;
export type ChatLeasedAttachConversationFilesInput = z.infer<
  typeof chatLeasedAttachConversationFilesInputSchema
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
export type StatusMenuHostFrame = z.infer<typeof statusMenuHostFrameSchema>;
export type StatusMenuClientFrame = z.infer<typeof statusMenuClientFrameSchema>;

export const emptyChatRuntimeSnapshot: ChatRuntimeSnapshot = {
  protocolVersion: chatProtocolVersion,
  revision: 0,
  sessions: [],
};

export const emptyChatRuntimeDraftsSnapshot: ChatRuntimeDraftsSnapshot = {
  drafts: [],
  protocolVersion: chatProtocolVersion,
};
