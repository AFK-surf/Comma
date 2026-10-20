import { baseLocale, messages as commaMessages, type CommaLocale } from "@comma/i18n";
import {
  chatAttachmentDownloadMaxBytes,
  chatAttachmentDownloadMaxFileNameBytes,
  type ChatDeviceSetupOffer,
  type ChatMessage as ContractChatMessage,
  type ChatMessagePart,
  type ChatQuestionState,
  type ChatReplyState,
  type ChatTaskActivity,
  type ChatTaskRun,
  type ManualTaskStatus,
} from "@comma/chat-contract";
import type { CommaTaskRun } from "../../comma/api-schemas";
import {
  ChatError,
  CommaApiError,
  type CommaApiClient,
  type CommaLocalFileRef,
  type SalixContentBlock,
  type CommaConversation,
  type CommaConversationKind,
  type CommaConversationEvent,
  type CommaMessagePage,
  type SalixMessage,
} from "../api";
import type { Runner, Scoped } from "@comma/core-kernel";
import { Duration, Effect, Fiber, Queue } from "effect";
import { after, cancel, type ChatEnv, type TimerHandle } from "../env";
import {
  composeMessageWithAttachments,
  isAllowedAttachment,
  isCommaContextMessage,
  isImageAttachment,
  isTranscodedImageAttachment,
  MAX_ATTACHMENT_BYTES,
  MAX_ATTACHMENTS_PER_MESSAGE,
  stripCommaProtocolMarkers,
} from "./protocol";
import {
  beginVisibleReplyStream,
  conversationMessageTurnKey,
  initialResponseOwnerTurnKey,
  idleVisibleReplyPresentationState,
  reconcileVisibleReplySnapshot,
  reduceVisibleReplyDraft,
  visibleReplyIdentityKey,
  type VisibleReplyPresentationState,
  type VisibleReplyDraftFrame,
} from "./visibleReplyPresentation";
import {
  decodeInlineMessagePart,
  deviceSetupOfferReplaces,
  deviceSetupOfferValue,
  questionAnswerPartValue,
  questionPartValue,
} from "./inlineElementContract";
import { createQuestionStates } from "./questionStates";
import { SeqCoverage } from "./seqCoverage";
import {
  milestonesOfBlocks,
  shownInTranscript,
  taskActivity,
  transcriptMessages,
  withActivityHistory,
  withLoopRuns,
  type TaskLoopRun,
} from "./taskActivity";
import {
  modelMentionsAsWords,
  splitUserTaskMentionParts,
} from "./mentionSerialization";
import { decodeUserMessage, type UserMessageDisplay } from "./userMessageText";
import { messageMarkdown } from "../../markdown/message";
import { draftMarkdown } from "../../markdown/stream";

const HOT_STREAM_RECONNECT_MS = 250;
const WARM_STREAM_RECONNECT_MS = 3_000;
const INITIAL_BACKOFF_MS = 1_000;
const MAX_BACKOFF_MS = 15_000;
// A brief outage, such as a laptop waking while Wi-Fi rejoins, recovers
// silently. The stale-transcript warning appears only once the 1s, 2s and 4s
// retries have also failed and the next wait would be at least this long.
const STALE_WARNING_BACKOFF_MS = 8_000;
const AWAITING_TIMEOUT_MS = 150_000;
const TASK_EVENT_WAIT_MS = 30_000;
const ACTIVITY_TTL_MS = 150_000;
const PUBLIC_ACTIVITY_PROSE_MAX_CODEPOINTS = 512;
const PRESENTATION_INDEX_LIMIT = 1_000;

export type ConversationConnection =
  | "idle"
  | "connecting"
  | "live"
  | "reconnecting"
  | "paused";

export type ConversationErrorKind =
  | "network"
  | "unauthorized"
  | "not-found"
  | "forbidden";

export type PendingSendStatus = "sending" | "failed";
export type ChatMessage = ContractChatMessage;
export type ChatMessageDelivery = ChatMessage["delivery"];
export type ChatSyncWarning = "stale" | "suspect-empty";
export type DraftAttachmentStatus = "uploading" | "uploaded" | "failed";

export type AttachmentUploadInput = {
  data: Blob;
  name: string;
  size: number;
};

/**
 * Re-encodes an attachment the runtime cannot consume as-is (HEIC/HEIF) into
 * one it can, before upload. Only hosts with a native decoder install one.
 */
export type AttachmentTranscoder = (
  file: AttachmentUploadInput
) => Effect.Effect<AttachmentUploadInput, unknown>;

export type DraftAttachment = {
  error: string | undefined;
  id: string;
  isImage: boolean;
  name: string;
  path: string | undefined;
  size: number;
  status: DraftAttachmentStatus;
  /** Main-owned opaque local ref; generated chat projections strip this field. */
  localFile?: CommaLocalFileRef | undefined;
};

export type ChatActivity = {
  action?: string | undefined;
  conversationId?: string | undefined;
  displayHoldMs?: number | undefined;
  displayPriority?: string | undefined;
  displayStrength?: string | undefined;
  goal?: string | undefined;
  ownerTurnKey?: string | undefined;
  phase?: string | undefined;
  producerEpoch?: string | undefined;
  responseKey?: string | undefined;
  sequence?: number | undefined;
  sourceMessageIds?: string[] | undefined;
  status?: string | undefined;
  streamIncarnation?: number | undefined;
  summary?: string | undefined;
  summaryClass?: ActivitySummaryClass | undefined;
  toolName?: string | undefined;
  updatedAt?: number | undefined;
};

export type ActivitySummaryClass = "none" | "generic" | "public";

export type BoundChatActivity = ChatActivity & {
  ownerTurnKey: string;
  producerEpoch: string;
  responseKey: string;
  sequence: number;
  sourceMessageIds: string[];
  summaryClass: ActivitySummaryClass;
  streamIncarnation: number;
};

export type ChatAssistantDraft = {
  conversationId: string;
  draftId: string;
  responseKey: string;
  revision?: number | undefined;
  sourceMessageIds: string[];
  status: "streaming" | "completed";
  text: string;
  /** The text as the core parsed it so far: what every client draws (`draftMarkdown`). */
  markdown?: ContractChatMessage["markdown"];
};

export type ChatBoundWorker = {
  participantId: string;
  actorId?: string | undefined;
  name: string;
};

export type { ChatTaskRun };

export type ChatParticipantIssueDetail = {
  source?: string | undefined;
  profileId?: string | undefined;
  profileName?: string | undefined;
  /** Unix seconds when the member's own subscription limit resets. */
  resetAt?: number | undefined;
  /** What started the round of a failed model request, when not a person's message. */
  trigger?: "background" | "voice_call" | undefined;
};

export type ChatParticipantStatus = {
  workingProvider?: "wechat" | "telegram" | "signal" | undefined;
  loopWake?: boolean | undefined;
  /** Other Conversations, usually Tasks, whose input the Router now answers. */
  workingConversationIds?: string[] | undefined;
  /** The Router waits, for example for a delegated Task. The hint carries no reason. */
  waiting?: boolean | undefined;
  actorId?: string | undefined;
  actorRole?: "router" | "worker" | undefined;
  conversationId: string;
  issue?: string | undefined;
  /** What a member can fix after a funding stop; see `participantIssueDetail`. */
  issueDetail?: ChatParticipantIssueDetail | undefined;
  participantId: string;
  name?: string | undefined;
  state: "active" | "error" | "stopped";
  status: string;
  updatedAt: number;
};

export type ChatConversationRef = ChatMessage["refs"][number];
export type ChatAttachment = ChatMessage["attachments"][number];

export type AgentBlobImagePreviewRef = {
  agentId: string;
  blobRef: NonNullable<ChatAttachment["blobRef"]>;
  fileName: string;
  kind: "agent-blob";
  mediaType: "image/png" | "image/jpeg" | "image/gif" | "image/webp";
};

export type ChatImagePreviewRef = string | AgentBlobImagePreviewRef;

export type LocalFilePreview = {
  release(): void;
  url: string;
};

export type PendingSend = {
  clientDeviceId?: string | undefined;
  clientRequestId: string;
  createdAt: number;
  error: string | undefined;
  failureAction?: "billing" | undefined;
  skills: { location: string }[] | undefined;
  replyToMessageId?: string | undefined;
  localFiles?: CommaLocalFileRef[] | undefined;
  /** The question card this message answers. */
  questionAnswer?: QuestionAnswer | undefined;
  status: PendingSendStatus;
  /** The person's words, and the uploaded files' list once `uploads` is gone. */
  text: string;
  /**
   * The files the message took from the draft while one still uploaded: it goes out once each is uploaded, and
   * `text` then lists them.
   */
  uploads?: DraftAttachment[] | undefined;
};

/** How a person answers a question card: the choices picked, their own words, or a skip. */
export type QuestionAnswer = {
  questionMessageId: string;
  choiceIds: string[];
  other?: string | undefined;
  skipped: boolean;
};

export type ConversationChannelState = {
  activity: ChatActivity | undefined;
  assistantDraft: ChatAssistantDraft | undefined;
  awaitingReply: boolean;
  awaitingSince: number | undefined;
  awaitingTimedOut: boolean;
  awaitingTurnKey?: string | undefined;
  connection: ConversationConnection;
  conversation: CommaConversation | undefined;
  draft: string;
  draftAttachments: DraftAttachment[];
  /** Images added to a question card's other answer, by the question message: apart from the composer's draft. */
  questionAttachments?: Record<string, DraftAttachment[]> | undefined;
  errorKind: ConversationErrorKind | undefined;
  /**
   * How much of the conversation's history `serverMessages` holds: the seq ranges read (a gap lies between two of
   * them until paging closes it), and whether messages before the oldest held can be read (`loadOlder`).
   */
  history?: ConversationHistory | undefined;
  lastBackoffMs: number;
  /** A Loop Task's runs the read history proves, for its Activity; transcripts never show their wakes. */
  loopRuns?: readonly TaskLoopRun[] | undefined;
  /**
   * A Task's history before the transcript held, cut to what its Activity reads (`readActivityHistory`), oldest
   * first. No transcript shows it.
   */
  activityHistory?: readonly ChatMessage[] | undefined;
  /** Where reading `activityHistory` stands until it reaches the Task's first message (`ChatTaskActivity.earlier`). */
  activityEarlier?: "reading" | "unread" | undefined;
  /** Local send feedback until exact-source runtime feedback, outcome, or timeout. */
  locallyAwaitingReply?: boolean | undefined;
  messages: ChatMessage[];
  pending: PendingSend[];
  participantStatus: ChatParticipantStatus | undefined;
  participantStatuses?: ChatParticipantStatus[] | undefined;
  boundWorker?: ChatBoundWorker | undefined;
  /** Where a Task runs and its model, which its panels show instead of its Agent. */
  taskRun?: ChatTaskRun | undefined;
  /** Where the next reply stands (`replyState`), as the core sends it to every client. */
  reply?: ChatReplyState | undefined;
  serverMessages: ChatMessage[];
  status: "idle" | "loading" | "ready" | "error";
  syncWarning: ChatSyncWarning | undefined;
  /** A Task's Activity, as a window receives it; the core reads it from `serverMessages` when it projects. */
  taskActivity?: ChatTaskActivity | undefined;
};

/** Where the conversation's next reply stands: the one reading every client shows. */
export function replyState(
  state: Pick<
    ConversationChannelState,
    | "assistantDraft"
    | "awaitingReply"
    | "awaitingTimedOut"
    | "awaitingTurnKey"
    | "locallyAwaitingReply"
    | "participantStatus"
    | "pending"
  >
): ChatReplyState {
  const streaming = state.assistantDraft?.status === "streaming";
  const waiting =
    state.awaitingReply &&
    !state.awaitingTimedOut &&
    state.assistantDraft === undefined;
  // The send this client waits on failed: nothing is coming for it.
  const sendFailed =
    state.awaitingTurnKey !== undefined &&
    state.pending.some(
      (item) =>
        item.clientRequestId === state.awaitingTurnKey && item.status === "failed"
    );
  return {
    coming:
      state.pending.some((item) => item.status !== "failed") || waiting || streaming,
    thinking: waiting && state.locallyAwaitingReply === true && !sendFailed,
    streaming,
    working:
      state.participantStatus?.state === "active" &&
      state.participantStatus.loopWake !== true,
    failed: state.participantStatus?.state === "error",
    timedOut: state.awaitingReply && state.awaitingTimedOut,
  };
}

export type ConversationHistory = {
  hasOlder: boolean;
  loadingOlder: boolean;
  ranges: [number, number][];
};

/** Messages a page before the oldest held asks for. */
const OLDER_PAGE = 100;
/** An Activity history page; its messages are cut to a few fields, so it reads more than a transcript page. */
const ACTIVITY_PAGE = 200;
/** Messages a page that closes a gap asks for, and how many such pages one fill reads at most. */
const GAP_PAGE = 200;
const MAX_GAP_PAGES = 100;

export const idleConversationChannelState: ConversationChannelState = {
  activity: undefined,
  assistantDraft: undefined,
  awaitingReply: false,
  awaitingSince: undefined,
  awaitingTimedOut: false,
  awaitingTurnKey: undefined,
  connection: "idle",
  conversation: undefined,
  draft: "",
  draftAttachments: [],
  errorKind: undefined,
  lastBackoffMs: 0,
  locallyAwaitingReply: false,
  messages: [],
  pending: [],
  participantStatus: undefined,
  serverMessages: [],
  status: "idle",
  syncWarning: undefined,
};

/**
 * Ephemeral causal metadata owned by the channel that consumes the canonical
 * conversation log. It is deliberately kept out of the durable message model:
 * renderer surfaces use it only to materialize presentation projections such
 * as a surface's local Clear boundary.
 */
export type ConversationObservationState = {
  assistantDraftFirstObservedSequence: number | undefined;
  currentObservationSequence: number;
  messageFirstObservedSequences: ReadonlyMap<string, number>;
  pendingFirstObservedSequences: ReadonlyMap<string, number>;
};

export type ConversationVisibility = {
  isVisible(): boolean;
  subscribe(listener: () => void): () => void;
};

/** The channel's world: timers, the time and ids from the core (chat/env.ts); a host transcoder; visibility for a page. */
export type ConversationChannelEnv = {
  /** Where the channel's connection runs: the core's fibers on its Clock. */
  runner: Runner;
  createClientRequestId: () => string;
  jitterMs: (baseDelayMs: number) => number;
  now: () => number;
  transcodeAttachment: AttachmentTranscoder | undefined;
  visibility: ConversationVisibility | undefined;
};

/** The env a core gives a channel: its timers, time and randomness; always visible (a core is never a hidden page). */
export function channelEnv(
  env: ChatEnv,
  transcodeAttachment?: AttachmentTranscoder
): ConversationChannelEnv {
  return {
    createClientRequestId: () => env.uuid(),
    jitterMs: () => Math.floor(env.random() * 250),
    now: () => env.now(),
    runner: env.runner,
    transcodeAttachment,
    visibility: undefined,
  };
}

export type ConversationChannelOptions = {
  api: CommaApiClient;
  getClientDeviceId?: () => string | undefined;
  conversationId: string;
  groupId: string;
  env: ConversationChannelEnv;
  initialKind?: CommaConversationKind;
  initialState?: ConversationChannelState;
  locale?: CommaLocale;
  onCanonicalMessagesAppended?: (input: {
    conversation: CommaConversation;
    messages: readonly ChatMessage[];
  }) => void;
  onLocalFilesCommitted?: (
    files: readonly CommaLocalFileRef[],
    committedAtMs: number | undefined
  ) => void;
  workspaceId: string;
};

type Listener = () => void;

/** Why an upload failed, as the person reads it. */
type UploadFailure = { message: string };

/** What wakes a channel's connection (`kick`: restart the poll under way, or poll if none is). */
type ConnectionInput = "now" | "refresh" | "restart" | "kick";
/** When to poll next: in ms, or only once woken. */
type PollDelay = number | "idle";
/** How a poll ended: the delay to the next one, none ("stale": it was stopped or outdated), or not to retry. */
type PollOutcome = number | "stale" | "fatal";

/** A question card that takes no more answers: its images go (`withoutClosedCardImages`). */
const CLOSED_CARD: ReadonlySet<ChatQuestionState["status"]> = new Set([
  "answered",
  "skipped",
  "replied",
  "replaced",
]);

export class ConversationChannel {
  readonly conversationId: string;
  readonly groupId: string;
  readonly workspaceId: string;

  private readonly api: CommaApiClient;
  private readonly getClientDeviceId: (() => string | undefined) | undefined;
  private readonly env: ConversationChannelEnv;
  private readonly locale: CommaLocale;
  private readonly onCanonicalMessagesAppended:
    | ((input: {
        conversation: CommaConversation;
        messages: readonly ChatMessage[];
      }) => void)
    | undefined;
  private readonly onLocalFilesCommitted:
    | ((files: readonly CommaLocalFileRef[], committedAtMs: number | undefined) => void)
    | undefined;
  /** Each attachment's upload under way: a fiber, stopped when the attachment is removed or the channel stops. */
  private readonly uploads = new Map<string, Fiber.Fiber<void>>();
  private readonly attachmentFiles = new Map<string, AttachmentUploadInput>();
  /**
   * Messages that waited for their files and have not been answered yet: a message sent after one goes out after
   * it, so the server has them in the order the person sent them.
   */
  private readonly uploadingSends = new Set<string>();
  private readonly clientRequestFirstObservedSequences = new Map<string, number>();
  private readonly draftFirstObservedSequences = new Map<string, number>();
  private readonly listeners = new Set<Listener>();
  private readonly messageFirstObservedSequences = new Map<string, number>();
  private readonly canonicalMessageIdsByClientRequestId = new Map<string, string>();
  private readonly committedLocalFileRefs = new Set<string>();
  private readonly committingLocalFileRefs = new Set<string>();
  /** The poll under way's fence: aborted when it is stopped, which its callbacks check before they apply anything. */
  private abortController: AbortController | undefined;
  private active = false;
  /** The connection's worker and what wakes it, while the channel is started. */
  private connection:
    | { scoped: Scoped; inputs: Queue.Queue<ConnectionInput> }
    | undefined;
  private activityProducerEpoch: string | undefined;
  private activityProducerSequence: number | undefined;
  private activityRetiredProducerEpochs = new Set<string>();
  private activityCursorIncarnation: number | undefined;
  private activitySnapshotReadyIncarnation: number | undefined;
  private activityStreamIncarnation: number | undefined;
  private activityTimer: TimerHandle | undefined;
  private epoch = 0;
  private activeStreamIncarnation: number | undefined;
  private nextStreamIncarnation = 0;
  private observationSequence = 0;
  private locallyAwaitedClientRequestId: string | undefined;
  private locallyAwaitedSince: number | undefined;
  private localReplyTimer: TimerHandle | undefined;
  private visibleReplyPresentation: VisibleReplyPresentationState =
    idleVisibleReplyPresentationState;
  private taskDetailRefreshNeeded = true;
  private taskEtag: string | undefined;
  private taskListVersion: string | undefined;
  private transportMode: "unknown" | "events" | "task-events";
  private releaseVisibility: (() => void) | undefined;
  private serverMessages: ChatMessage[] = [];
  /** The seq ranges read, hidden messages included: what a snapshot or a page proved, never what is displayed. */
  private coverage = SeqCoverage.EMPTY;
  /** The conversation's first seq, once the server said it: nothing is older. */
  private historyHead: number | undefined;
  private loadingOlder = false;
  private fillingGaps = false;
  private readingActivity = false;
  /** The first seq the Activity history holds; it reads the pages before it. */
  private activityBefore: number | undefined;
  private activityHistoryRead = false;
  // The opening snapshot is the conversation's history, not an arrival, so
  // appends are only reported once one canonical set has been observed.
  private hasObservedCanonicalSnapshot = false;
  private streamWaitMs: number | undefined;
  private state: ConversationChannelState = {
    activity: undefined,
    assistantDraft: undefined,
    awaitingReply: false,
    awaitingSince: undefined,
    awaitingTimedOut: false,
    awaitingTurnKey: undefined,
    connection: "idle",
    conversation: undefined,
    draft: "",
    draftAttachments: [],
    errorKind: undefined,
    lastBackoffMs: 0,
    locallyAwaitingReply: false,
    messages: [],
    pending: [],
    participantStatus: undefined,
    participantStatuses: undefined,
    boundWorker: undefined,
    taskRun: undefined,
    serverMessages: [],
    status: "idle",
    syncWarning: undefined,
  };

  constructor(options: ConversationChannelOptions) {
    this.api = options.api;
    this.getClientDeviceId = options.getClientDeviceId;
    this.locale = options.locale ?? baseLocale;
    this.groupId = options.groupId;
    this.workspaceId = options.workspaceId;
    this.conversationId = options.conversationId;
    this.onLocalFilesCommitted = options.onLocalFilesCommitted;
    this.onCanonicalMessagesAppended = options.onCanonicalMessagesAppended;
    this.env = normalizeEnv(options.env);
    if (options.initialState) {
      this.state = options.initialState;
      this.serverMessages = options.initialState.serverMessages;
      this.coverage = SeqCoverage.of(options.initialState.history?.ranges ?? []);
      this.hasObservedCanonicalSnapshot = true;
    }
    this.transportMode =
      options.initialKind === "agent_task"
        ? "task-events"
        : options.initialKind
          ? "events"
          : "unknown";
  }

  start() {
    if (this.active) {
      return;
    }

    this.active = true;
    // A connection that ended on an error the channel cannot retry (it stopped being active) is let go first.
    this.closeConnection();
    const { runner } = this.env;
    const scoped = runner.child();
    const inputs = Effect.runSync(Queue.unbounded<ConnectionInput>());
    this.connection = { scoped, inputs };
    this.releaseVisibility = this.env.visibility?.subscribe(() => {
      if (!this.active || !this.env.visibility?.isVisible()) {
        return;
      }
      this.wake("now");
    });
    runner.fork(this.connect(inputs), scoped);
  }

  stop() {
    this.active = false;
    this.epoch += 1;
    this.activeStreamIncarnation = undefined;
    this.activityStreamIncarnation = undefined;
    this.activitySnapshotReadyIncarnation = undefined;
    this.activityProducerEpoch = undefined;
    this.activityProducerSequence = undefined;
    this.activityRetiredProducerEpochs.clear();
    this.activityCursorIncarnation = undefined;
    this.closeConnection();
    this.abortUploads();
    this.taskDetailRefreshNeeded = true;
    this.taskListVersion = undefined;
    this.clearLocalReplyWait();
    this.clearActivityTimer();
    this.visibleReplyPresentation = idleVisibleReplyPresentationState;
    this.releaseVisibility?.();
    this.releaseVisibility = undefined;
    this.setState({
      activity: undefined,
      assistantDraft: undefined,
      connection: "idle",
      locallyAwaitingReply: false,
      participantStatus: undefined,
      participantStatuses: undefined,
      boundWorker: undefined,
      taskRun: undefined,
    });
  }

  acceptTaskReview(reviewVersion: number): Effect.Effect<void, Error> {
    return this.applyTaskCommand(() =>
      this.api.acceptTaskReview(this.groupId, this.conversationId, reviewVersion)
    );
  }

  setTaskStatus(
    status: ManualTaskStatus,
    expectedUpdatedAt: number
  ): Effect.Effect<void, Error> {
    return this.applyTaskCommand(() =>
      this.api.setTaskStatus(
        this.groupId,
        this.conversationId,
        status,
        expectedUpdatedAt
      )
    );
  }

  private applyTaskCommand(
    command: () => Effect.Effect<CommaConversation, Error>
  ): Effect.Effect<void, Error> {
    return Effect.suspend(() => {
      if (!this.active)
        return Effect.fail(new ChatError("The chat session is no longer active."));
      const epoch = this.epoch;
      return command().pipe(
        Effect.tap((conversation) =>
          Effect.sync(() => {
            if (!this.active || this.epoch !== epoch) return;
            // Cancel any detail read captured before the mutation, then publish the
            // canonical command result before fetching subsequent invalidations.
            this.taskEtag = undefined;
            this.taskDetailRefreshNeeded = true;
            this.restartCurrentStreamOrPoll();
            if (
              !this.state.conversation ||
              (conversation.updated_at ?? 0) >=
                (this.state.conversation.updated_at ?? 0)
            ) {
              this.applyConversation(conversation);
            }
          })
        ),
        Effect.tapError(() =>
          Effect.sync(() => {
            if (this.active && this.epoch === epoch) this.refresh();
          })
        ),
        Effect.asVoid
      );
    });
  }

  refresh() {
    if (!this.active) {
      return;
    }

    if (this.transportMode === "task-events") {
      this.taskDetailRefreshNeeded = true;
    }

    this.wake("refresh");
  }

  subscribe(listener: Listener) {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  }

  getSnapshot() {
    return this.state;
  }

  getObservationState(): ConversationObservationState {
    const pendingFirstObservedSequences = new Map<string, number>();
    for (const pending of this.state.pending.slice(-PRESENTATION_INDEX_LIMIT)) {
      pendingFirstObservedSequences.set(
        pending.clientRequestId,
        this.clientRequestFirstObservedSequences.get(pending.clientRequestId) ?? 0
      );
    }

    const messageFirstObservedSequences = new Map<string, number>();
    for (const message of this.state.messages.slice(-PRESENTATION_INDEX_LIMIT)) {
      messageFirstObservedSequences.set(
        message.messageId,
        this.messageFirstObservedSequences.get(message.messageId) ??
          (message.clientRequestId
            ? this.clientRequestFirstObservedSequences.get(message.clientRequestId)
            : undefined) ??
          0
      );
    }
    for (const message of this.state.serverMessages.slice(-PRESENTATION_INDEX_LIMIT)) {
      if (!messageFirstObservedSequences.has(message.messageId)) {
        messageFirstObservedSequences.set(
          message.messageId,
          this.messageFirstObservedSequences.get(message.messageId) ?? 0
        );
      }
    }

    const assistantDraft = this.state.assistantDraft;
    return {
      assistantDraftFirstObservedSequence: assistantDraft
        ? (this.draftFirstObservedSequences.get(assistantDraft.draftId) ?? 0)
        : undefined,
      currentObservationSequence: this.observationSequence,
      messageFirstObservedSequences,
      pendingFirstObservedSequences,
    };
  }

  setDraft(draft: string) {
    // Draft-only fast path: no derived state (awaiting flags, combined
    // messages, activity presentation) reads the draft, so a keystroke must
    // not pay the full O(messages) rebuild pipeline. Every other field keeps
    // its identity, letting memoized subscribers skip the transcript.
    if (this.state.draft === draft) {
      return;
    }
    this.state = { ...this.state, draft };
    this.emit();
  }

  get transcodesImages() {
    return this.env.transcodeAttachment !== undefined;
  }

  /**
   * Adds files to the draft, or with `questionMessageId` to that question card's other answer: they upload at once
   * either way, and the card's stay apart from the draft (answering the card sends them, the composer's send does
   * not).
   */
  attachFiles(files: AttachmentUploadInput[], questionMessageId?: string) {
    if (files.length === 0) {
      return;
    }

    const nextAttachments: DraftAttachment[] = [];
    // The upload budget counts upload-class attachments only. Local refs have
    // their own 50-item budget, so a mixed selection admits identically
    // regardless of which class the dialog returned first.
    let projectedCount = this.attachmentsOf(questionMessageId).filter(
      (attachment) => attachment.localFile === undefined
    ).length;

    for (const file of files) {
      const id = this.createClientRequestId();
      const validationError = validateAttachment(
        file,
        projectedCount,
        this.locale,
        this.env.transcodeAttachment !== undefined
      );
      const attachment: DraftAttachment = {
        error: validationError,
        id,
        isImage: isImageAttachment(file.name) || isTranscodedImageAttachment(file.name),
        name: file.name,
        path: undefined,
        size: file.size,
        status: validationError ? "failed" : "uploading",
      };
      this.attachmentFiles.set(id, file);
      nextAttachments.push(attachment);
      projectedCount += 1;
    }

    this.setAttachmentsOf(questionMessageId, [
      ...this.attachmentsOf(questionMessageId),
      ...nextAttachments,
    ]);

    for (const attachment of nextAttachments) {
      if (attachment.status === "uploading") {
        this.startUpload(attachment.id);
      }
    }
  }

  attachLocalFiles(
    files: Array<{
      localFileRef: string;
      mediaType: string;
      name: string;
      size: number;
    }>
  ) {
    if (files.length === 0) return;

    const existingLocalFiles = this.state.draftAttachments.flatMap((attachment) =>
      attachment.localFile ? [attachment.localFile] : []
    );
    const existingRefs = new Set(
      existingLocalFiles.map((localFile) => localFile.localFileRef)
    );
    // The local-file budget counts local refs only; upload-class attachments
    // budget separately, keeping mixed admission order-independent.
    const projectedCount = existingLocalFiles.length + files.length;
    const projectedBytes = [
      ...existingLocalFiles.map((localFile) => localFile.size),
      ...files.map((file) => file.size),
    ].reduce((total, size) => total + size, 0);
    if (projectedCount > 50 || projectedBytes > 1024 * 1024 * 1024) {
      throw new Error("Local attachment draft limits exceeded.");
    }

    const additions = files.map<DraftAttachment>((file) => {
      if (existingRefs.has(file.localFileRef)) {
        throw new Error("Local attachment refs cannot be reused in one draft.");
      }
      existingRefs.add(file.localFileRef);
      return {
        error: undefined,
        id: file.localFileRef,
        isImage: isImageAttachment(file.name),
        localFile: {
          displayName: file.name,
          localFileRef: file.localFileRef,
          mediaType: file.mediaType,
          size: file.size,
        },
        name: file.name,
        path: undefined,
        size: file.size,
        status: "uploaded",
      };
    });
    this.setState({
      draftAttachments: [...this.state.draftAttachments, ...additions],
    });
  }

  /** Removes an attachment from the draft, or from question card `questionMessageId`. */
  removeAttachment(id: string, questionMessageId?: string) {
    this.stopUpload(id);
    this.attachmentFiles.delete(id);
    this.setAttachmentsOf(
      questionMessageId,
      this.attachmentsOf(questionMessageId).filter((attachment) => attachment.id !== id)
    );
  }

  /** Uploads a failed attachment of the draft, or of question card `questionMessageId`, again. */
  retryAttachment(id: string, questionMessageId?: string) {
    const file = this.attachmentFiles.get(id);
    if (!file) {
      return;
    }

    const attachments = this.attachmentsOf(questionMessageId);
    const existing = attachments.find((attachment) => attachment.id === id);
    if (!existing || existing.status !== "failed") {
      return;
    }

    // The retry re-validates against the upload-class count only — the same
    // per-class budget attachFiles admits under. Local refs must not consume
    // the image-upload allowance here either, or a retry could fail for a
    // selection that originally admitted.
    const validationError = validateAttachment(
      file,
      attachments.filter(
        (attachment) => attachment.id !== id && attachment.localFile === undefined
      ).length,
      this.locale,
      this.env.transcodeAttachment !== undefined
    );
    this.setAttachmentsOf(
      questionMessageId,
      replaceAttachment(attachments, {
        ...existing,
        error: validationError,
        status: validationError ? "failed" : "uploading",
      })
    );
    if (!validationError) this.startUpload(id);
  }

  /** The draft's attachments, or question card `questionMessageId`'s. */
  private attachmentsOf(questionMessageId: string | undefined) {
    return questionMessageId === undefined
      ? this.state.draftAttachments
      : this.questionAttachmentsOf(questionMessageId);
  }

  private setAttachmentsOf(
    questionMessageId: string | undefined,
    attachments: DraftAttachment[]
  ) {
    if (questionMessageId === undefined)
      this.setState({ draftAttachments: attachments });
    else this.setQuestionAttachments(questionMessageId, attachments);
  }

  /**
   * Puts the answer to a question card in the conversation as being sent: one message in the person's words that
   * replies to the question and says what was picked, with the images added to the card when it gives the other
   * answer. Its request id is the question's, so an answer another device already gave wins and this one is refused,
   * not added twice. An answer that failed is replaced. Undefined when the question is not in the conversation, an answer is on its way, an
   * image is not uploaded yet, or the answer says nothing.
   */
  enqueueAnswer(answer: QuestionAnswer): PendingSend | undefined {
    const question = this.state.messages
      .find((message) => message.messageId === answer.questionMessageId)
      ?.parts?.find((part) => part.kind === "question");
    if (!question || question.kind !== "question") return undefined;
    const clientRequestId = `question-answer:${answer.questionMessageId}`;
    const earlier = this.state.pending.find(
      (item) => item.clientRequestId === clientRequestId
    );
    if (earlier?.status === "sending") return undefined;

    // The card's images belong to its other answer: an answer without one (a skip, or picks after the person left
    // Other) neither sends them nor waits for them.
    const attachments =
      answer.skipped || answer.other === undefined
        ? []
        : this.questionAttachmentsOf(answer.questionMessageId);
    if (attachments.some((attachment) => attachment.status !== "uploaded"))
      return undefined;
    const picked = question.choices.filter((choice) =>
      answer.choiceIds.includes(choice.id)
    );
    const other = answer.skipped ? undefined : answer.other?.trim() || undefined;
    if (!answer.skipped && picked.length === 0 && !other && attachments.length === 0) {
      return undefined;
    }

    // Several picks join with the locale's separator, not Intl.ListFormat: the Hermes that runs the core on Android
    // and iOS has no ListFormat.
    const words = answer.skipped
      ? commaMessages.chat_question_skip_reply({}, { locale: this.locale })
      : [
          picked.length === 1
            ? (picked[0]!.reply ?? picked[0]!.label)
            : picked
                .map((choice) => choice.label)
                .join(
                  commaMessages.chat_question_choice_separator(
                    {},
                    { locale: this.locale }
                  )
                ),
          other,
        ]
          .filter((part): part is string => Boolean(part))
          .join("\n\n");
    const text = composeMessageWithAttachments(
      words,
      attachments.flatMap((attachment) =>
        attachment.path ? [{ name: attachment.name, path: attachment.path }] : []
      )
    );
    const pending: PendingSend = {
      clientDeviceId: this.getClientDeviceId?.(),
      clientRequestId,
      createdAt: this.env.now(),
      error: undefined,
      questionAnswer: {
        questionMessageId: answer.questionMessageId,
        choiceIds: answer.skipped ? [] : picked.map((choice) => choice.id),
        ...(other !== undefined || (!answer.skipped && picked.length === 0)
          ? { other: other ?? "" }
          : {}),
        skipped: answer.skipped,
      },
      replyToMessageId: answer.questionMessageId,
      skills: undefined,
      status: "sending",
      text,
    };
    this.beginLocalReplyWait(clientRequestId);
    const firstObservedSequence = this.nextObservationSequence();
    setBoundedObservation(
      this.clientRequestFirstObservedSequences,
      clientRequestId,
      firstObservedSequence
    );
    setBoundedObservation(
      this.messageFirstObservedSequences,
      `pending:${clientRequestId}`,
      firstObservedSequence
    );
    this.state = {
      ...this.state,
      activity: undefined,
      ...(this.state.participantStatus?.state !== "active"
        ? { participantStatus: undefined }
        : {}),
      pending: earlier
        ? replacePending(this.state.pending, pending)
        : [...this.state.pending, pending],
    };
    this.rebuildState({ emit: true });
    this.wake("now");
    return pending;
  }

  /**
   * Answers a question card (`enqueueAnswer`) and sends the answer. The card keeps its images while the answer is
   * on its way or failed, so a retry sends them again; they go when the card closes (`withoutClosedCardImages`).
   */
  answerQuestion(
    answer: QuestionAnswer
  ): Effect.Effect<CommaConversation | undefined, Error> {
    return Effect.suspend(() => {
      const pending = this.enqueueAnswer(answer);
      return pending ? this.transmit(pending) : Effect.succeed(this.state.conversation);
    });
  }

  /**
   * The cards' images without those of cards that closed however they closed: answered here or on another device,
   * skipped, answered by writing in the chat, or replaced by a later question. Their uploads stop and their bytes go.
   */
  private withoutClosedCardImages(
    messages: readonly ChatMessage[]
  ): ConversationChannelState["questionAttachments"] {
    const held = this.state.questionAttachments;
    if (!held) return held;
    let kept: Record<string, DraftAttachment[]> | undefined;
    for (const message of messages) {
      const question = message.parts?.find((part) => part.kind === "question");
      if (question?.kind !== "question" || !CLOSED_CARD.has(question.state.status))
        continue;
      const images = held[question.messageId];
      if (!images) continue;
      for (const image of images) {
        this.stopUpload(image.id);
        this.attachmentFiles.delete(image.id);
      }
      kept ??= { ...held };
      delete kept[question.messageId];
    }
    if (!kept) return held;
    return Object.keys(kept).length > 0 ? kept : undefined;
  }

  private questionAttachmentsOf(questionMessageId: string) {
    return this.state.questionAttachments?.[questionMessageId] ?? [];
  }

  private setQuestionAttachments(
    questionMessageId: string,
    attachments: DraftAttachment[]
  ) {
    const next = { ...this.state.questionAttachments };
    if (attachments.length > 0) next[questionMessageId] = attachments;
    else delete next[questionMessageId];
    this.setState({
      questionAttachments: Object.keys(next).length > 0 ? next : undefined,
    });
  }

  refreshDerivedState() {
    this.rebuildState({ emit: true });
  }

  /**
   * Puts a message in the conversation as being sent (the draft consumed with it, unless `consumeDraft` is false), at
   * once: what the send is from that point. Undefined when there is nothing to send, or an attachment is not ready.
   * `transmit` sends it.
   */
  enqueueSend(
    text: string,
    options: {
      consumeDraft?: boolean;
      clientRequestId?: string;
      /** Files for this message alone, apart from the draft: they upload now and the message waits for them. */
      files?: AttachmentUploadInput[];
      skills?: { location: string }[];
      replyToMessageId?: string;
    } = {}
  ): PendingSend | undefined {
    const consumeDraft = options.consumeDraft ?? true;
    const trimmed = text.trim();
    // A file still uploading goes with the message: it waits for the file, not the person.
    const draftUploads = consumeDraft
      ? this.state.draftAttachments.filter(
          (attachment) =>
            attachment.localFile === undefined &&
            (attachment.status === "uploading" ||
              (attachment.status === "uploaded" && attachment.path))
        )
      : [];
    // A file of the message's own that could never upload stays out of it; the rest of the message still goes.
    const ownUploads: { attachment: DraftAttachment; file: AttachmentUploadInput }[] =
      [];
    for (const file of options.files ?? []) {
      const invalid = validateAttachment(
        file,
        draftUploads.length + ownUploads.length,
        this.locale,
        this.env.transcodeAttachment !== undefined
      );
      if (invalid) continue;
      ownUploads.push({
        attachment: {
          error: undefined,
          id: this.createClientRequestId(),
          isImage:
            isImageAttachment(file.name) || isTranscodedImageAttachment(file.name),
          name: file.name,
          path: undefined,
          size: file.size,
          status: "uploading",
        },
        file,
      });
    }
    const hasBlockedAttachment =
      consumeDraft &&
      this.state.draftAttachments.some((attachment) => attachment.status === "failed");
    const uploads = [
      ...draftUploads,
      ...ownUploads.map(({ attachment }) => attachment),
    ];
    const uploading = uploads.some((attachment) => attachment.status === "uploading");
    const localFiles = consumeDraft
      ? this.state.draftAttachments.flatMap((attachment) =>
          attachment.status === "uploaded" && attachment.localFile
            ? [{ ...attachment.localFile }]
            : []
        )
      : [];
    if (
      hasBlockedAttachment ||
      (!trimmed && uploads.length === 0 && localFiles.length === 0)
    ) {
      return undefined;
    }

    const sendText = uploading ? text : composeUploadedMessage(text, uploads);
    const pending: PendingSend = {
      clientDeviceId: this.getClientDeviceId?.(),
      clientRequestId: options.clientRequestId ?? this.createClientRequestId(),
      createdAt: this.env.now(),
      error: undefined,
      localFiles: localFiles.length > 0 ? localFiles : undefined,
      skills: options.skills?.length ? options.skills : undefined,
      replyToMessageId: options.replyToMessageId,
      status: "sending",
      text: sendText,
      uploads: uploading ? uploads : undefined,
    };
    if (uploading) this.uploadingSends.add(pending.clientRequestId);
    const firstObservedSequence = this.nextObservationSequence();
    this.beginLocalReplyWait(pending.clientRequestId);
    setBoundedObservation(
      this.clientRequestFirstObservedSequences,
      pending.clientRequestId,
      firstObservedSequence
    );
    setBoundedObservation(
      this.messageFirstObservedSequences,
      `pending:${pending.clientRequestId}`,
      firstObservedSequence
    );
    if (consumeDraft) {
      for (const attachment of this.state.draftAttachments) {
        // A file the message waits for keeps its upload, and its bytes for a retry.
        if (uploading && pending.uploads?.includes(attachment)) continue;
        this.attachmentFiles.delete(attachment.id);
        this.uploads.delete(attachment.id);
      }
    }
    this.state = {
      ...this.state,
      activity: undefined,
      draftAttachments: consumeDraft ? [] : this.state.draftAttachments,
      // The previous turn's terminal error describes a transcript position this
      // send just advanced, and the runtime clears it for the same reason. Held
      // until the next status arrives it reads as though the new message failed
      // too, so it goes out with the activity frame it mirrors.
      ...(this.state.participantStatus?.state !== "active"
        ? { participantStatus: undefined }
        : {}),
      pending: [...this.state.pending, pending],
      draft: consumeDraft ? "" : this.state.draft,
    };
    this.rebuildState({ emit: true });
    for (const { attachment, file } of ownUploads) {
      this.attachmentFiles.set(attachment.id, file);
      this.startUpload(attachment.id);
    }
    this.wake("now");
    return pending;
  }

  /** Enqueues a message and sends it: the conversation as the server has it then (as it was, with nothing to send). */
  send(
    text: string,
    options: {
      consumeDraft?: boolean;
      clientRequestId?: string;
      files?: AttachmentUploadInput[];
      skills?: { location: string }[];
      replyToMessageId?: string;
    } = {}
  ): Effect.Effect<CommaConversation | undefined, Error> {
    return Effect.suspend(() => {
      const pending = this.enqueueSend(text, options);
      return pending ? this.transmit(pending) : Effect.succeed(this.state.conversation);
    });
  }

  /** Sends a failed message again, with its request id. */
  retry(clientRequestId: string): Effect.Effect<CommaConversation | undefined, Error> {
    return Effect.suspend(() => this.#retry(clientRequestId));
  }

  #retry(clientRequestId: string): Effect.Effect<CommaConversation | undefined, Error> {
    const pending = this.state.pending.find(
      (item) => item.clientRequestId === clientRequestId
    );
    if (!pending) {
      return Effect.succeed(this.state.conversation);
    }

    const retrying = {
      ...pending,
      error: undefined,
      failureAction: undefined,
      status: "sending" as const,
      // A file that failed uploads again, if its bytes are still here; one that is not fails the send again.
      uploads: pending.uploads?.map((attachment) =>
        attachment.status === "failed" && this.attachmentFiles.has(attachment.id)
          ? { ...attachment, error: undefined, status: "uploading" as const }
          : attachment
      ),
    };
    this.beginLocalReplyWait(retrying.clientRequestId);
    this.state = {
      ...this.state,
      pending: replacePending(this.state.pending, retrying),
    };
    this.rebuildState({ emit: true });
    this.wake("now");
    if (retrying.uploads) this.uploadingSends.add(retrying.clientRequestId);
    for (const attachment of retrying.uploads ?? []) {
      if (attachment.status === "uploading" && !this.uploads.has(attachment.id)) {
        this.startUpload(attachment.id);
      }
    }

    return this.transmit(retrying);
  }

  discard(clientRequestId: string) {
    if (this.locallyAwaitedClientRequestId === clientRequestId) {
      this.clearLocalReplyWait();
    }
    const discarded = this.state.pending.find(
      (item) => item.clientRequestId === clientRequestId
    );
    for (const attachment of discarded?.uploads ?? []) {
      this.stopUpload(attachment.id);
      this.attachmentFiles.delete(attachment.id);
    }
    this.state = {
      ...this.state,
      pending: this.state.pending.filter(
        (pending) => pending.clientRequestId !== clientRequestId
      ),
    };
    this.rebuildState({ emit: true });
  }

  /** Sends an enqueued message: the conversation the server answered with; a failure marks the message failed. */
  transmit(pending: PendingSend): Effect.Effect<CommaConversation, Error> {
    return this.awaitUploads(pending).pipe(
      Effect.flatMap((ready) => this.transmitReady(ready)),
      Effect.tapError((error) =>
        Effect.sync(() => {
          const current = this.state.pending.find(
            (item) => item.clientRequestId === pending.clientRequestId
          );
          // A message discarded meanwhile stays gone.
          if (!current) return;
          if (this.locallyAwaitedClientRequestId === pending.clientRequestId) {
            this.clearLocalReplyWait();
          }
          const failed = {
            ...current,
            error: sendErrorDetail(error, this.locale),
            failureAction: sendFailureAction(error),
            status: "failed" as const,
          };
          this.state = {
            ...this.state,
            pending: replacePending(this.state.pending, failed),
          };
          this.rebuildState({ emit: true });
        })
      ),
      Effect.ensuring(
        Effect.sync(() => {
          // A message held behind this one goes now.
          if (this.uploadingSends.delete(pending.clientRequestId)) this.emit();
        })
      )
    );
  }

  /**
   * The message once every file it waits for is uploaded and every message sent before it that waited for its own
   * files was answered; fails when one of its files failed, or the message went.
   */
  private awaitUploads(pending: PendingSend): Effect.Effect<PendingSend, Error> {
    return Effect.gen({ self: this }, function* () {
      for (;;) {
        const current = this.state.pending.find(
          (item) => item.clientRequestId === pending.clientRequestId
        );
        if (!current) {
          return yield* new ChatError("This message was discarded.");
        }
        if (!current.uploads) {
          const index = this.state.pending.indexOf(current);
          const behind = this.state.pending
            .slice(0, index)
            .some((item) => this.uploadingSends.has(item.clientRequestId));
          if (!behind) return current;
          yield* this.changed();
          continue;
        }
        const failed = current.uploads.find(
          (attachment) => attachment.status === "failed"
        );
        if (failed) {
          return yield* new ChatError(
            failed.error ??
              commaMessages.chat_upload_failed({}, { locale: this.locale })
          );
        }
        if (
          !current.uploads.some(
            (attachment) =>
              attachment.status === "uploading" && this.uploads.has(attachment.id)
          )
        ) {
          // Nothing uploads any more (the channel stopped): nothing would end the wait.
          return yield* new ChatError(
            commaMessages.chat_upload_failed({}, { locale: this.locale })
          );
        }
        yield* this.changed();
      }
    });
  }

  /** Waits for the channel's next change. */
  private changed(): Effect.Effect<void> {
    return Effect.callback<void>((resume) => {
      const unsubscribe = this.subscribe(() => resume(Effect.void));
      return Effect.sync(unsubscribe);
    });
  }

  private transmitReady(pending: PendingSend): Effect.Effect<CommaConversation, Error> {
    const attrs: {
      clientRequestId: string;
      clientDeviceId?: string;
      localFiles?: CommaLocalFileRef[];
      skills?: { location: string }[];
      replyToMessageId?: string;
      questionAnswer?: QuestionAnswer;
      text: string;
    } = {
      text: pending.text,
      clientRequestId: pending.clientRequestId,
    };
    if (pending.replyToMessageId) attrs.replyToMessageId = pending.replyToMessageId;
    if (pending.questionAnswer) attrs.questionAnswer = pending.questionAnswer;
    if (pending.clientDeviceId) attrs.clientDeviceId = pending.clientDeviceId;
    if (pending.skills?.length) {
      attrs.skills = pending.skills;
    }
    if (pending.localFiles?.length) {
      attrs.localFiles = pending.localFiles;
    }
    return this.api.sendMessage(this.groupId, this.conversationId, attrs).pipe(
      Effect.tap((conversation) =>
        Effect.sync(() => {
          if (conversation.kind === "agent_task") {
            this.transportMode = "task-events";
            this.taskEtag = undefined;
            this.taskDetailRefreshNeeded = true;
          }
          this.applyConversation(conversation);
          if (conversation.kind === "agent_task") this.restartCurrentStream();
          else this.wake("now");
        })
      )
    );
  }

  private startUpload(id: string) {
    this.stopUpload(id);
    // The upload can end before `fork` returns (a failure it meets at once): it is then never kept.
    let upload: Fiber.Fiber<void> | undefined;
    upload = this.env.runner.fork(
      this.upload(id).pipe(
        Effect.ensuring(
          Effect.sync(() => {
            if (upload !== undefined && this.uploads.get(id) === upload)
              this.uploads.delete(id);
          })
        )
      )
    );
    if (!upload.pollUnsafe()) this.uploads.set(id, upload);
  }

  private stopUpload(id: string) {
    const upload = this.uploads.get(id);
    if (!upload) return;
    this.uploads.delete(id);
    this.env.runner.interrupt(upload);
  }

  /** The bytes of a file the channel still uploads, or holds for its draft: what shows it before the server has it. */
  heldUpload(id: string): AttachmentUploadInput | undefined {
    return this.attachmentFiles.get(id);
  }

  /** The attachment uploading as `id`: in the draft, added to a question card, or in a message that took it. */
  private findUpload(id: string): DraftAttachment | undefined {
    return (
      this.state.draftAttachments.find((item) => item.id === id) ??
      Object.values(this.state.questionAttachments ?? {})
        .flat()
        .find((item) => item.id === id) ??
      this.state.pending
        .flatMap((pending) => pending.uploads ?? [])
        .find((item) => item.id === id)
    );
  }

  /**
   * Records how an upload went, where the attachment is now. A message whose files are all uploaded lists them in
   * its text: it is then what it would have been had it been sent after the uploads.
   */
  private settleUpload(id: string, change: Partial<DraftAttachment>) {
    if (this.state.draftAttachments.some((item) => item.id === id)) {
      this.setState({
        draftAttachments: this.state.draftAttachments.map((item) =>
          item.id === id ? { ...item, ...change } : item
        ),
      });
      return;
    }
    const card = Object.entries(this.state.questionAttachments ?? {}).find(
      ([, attachments]) => attachments.some((item) => item.id === id)
    );
    if (card) {
      this.setQuestionAttachments(
        card[0],
        card[1].map((item) => (item.id === id ? { ...item, ...change } : item))
      );
      return;
    }
    const owner = this.state.pending.find((pending) =>
      pending.uploads?.some((item) => item.id === id)
    );
    if (!owner?.uploads) return;
    const uploads = owner.uploads.map((item) =>
      item.id === id ? { ...item, ...change } : item
    );
    const settled = uploads.every((item) => item.status === "uploaded");
    if (settled) for (const item of uploads) this.attachmentFiles.delete(item.id);
    this.setState({
      pending: replacePending(
        this.state.pending,
        settled
          ? {
              ...owner,
              text: composeUploadedMessage(owner.text, uploads),
              uploads: undefined,
            }
          : { ...owner, uploads }
      ),
    });
  }

  /** Uploads an attachment (an image transcoded first, when it needs to be), and says how it went. */
  private upload(id: string): Effect.Effect<void> {
    return Effect.suspend(() => {
      const file = this.attachmentFiles.get(id);
      const attachment = this.findUpload(id);
      if (!file || !attachment || attachment.status !== "uploading") return Effect.void;
      const transcode = this.env.transcodeAttachment;
      const source: Effect.Effect<AttachmentUploadInput, UploadFailure> =
        !isTranscodedImageAttachment(file.name)
          ? Effect.succeed(file)
          : transcode
            ? transcode(file).pipe(
                // A decoder failure is not an upload outcome the server named; the
                // user retries or removes the file either way.
                Effect.mapError(() => ({
                  message: commaMessages.chat_upload_failed(
                    {},
                    { locale: this.locale }
                  ),
                }))
              )
            : Effect.fail({
                message: commaMessages.chat_unsupported_attachment(
                  {},
                  { locale: this.locale }
                ),
              });
      return source.pipe(
        Effect.flatMap((ready) =>
          this.api
            .uploadGroupFile(this.groupId, { data: ready.data, name: ready.name })
            .pipe(
              Effect.mapError(
                (error): UploadFailure => ({
                  message: uploadErrorMessage(error, this.locale),
                })
              )
            )
        ),
        Effect.match({
          onSuccess: (uploaded) => {
            if (!this.attachmentFiles.has(id)) return;
            this.settleUpload(id, {
              error: undefined,
              isImage: isImageAttachment(uploaded.name),
              name: uploaded.name,
              path: uploaded.path,
              size: uploaded.size,
              status: "uploaded",
            });
          },
          onFailure: (failure) => {
            if (!this.attachmentFiles.has(id)) return;
            this.settleUpload(id, { error: failure.message, status: "failed" });
          },
        })
      );
    });
  }

  /** Wakes the connection: `now` polls at once if it waits; `refresh` also polls again once a poll under way ends. */
  private wake(input: "now" | "refresh") {
    if (this.connection) Effect.runSync(Queue.offer(this.connection.inputs, input));
  }

  /** Restarts the poll under way, or polls at once if none is. */
  private restartCurrentStreamOrPoll() {
    this.activeStreamIncarnation = undefined;
    if (this.connection) Effect.runSync(Queue.offer(this.connection.inputs, "kick"));
  }

  private closeConnection() {
    const connection = this.connection;
    if (!connection) return;
    this.connection = undefined;
    this.env.runner.close(connection.scoped);
  }

  /**
   * The connection: one fiber polls, one poll at a time, and waits between polls (the reconnect delay, a backoff
   * after a network error) until the delay passes or something wakes it. A restart stops the poll under way and
   * polls again at once; one that comes while it waits polls again right after the next poll. It ends with the
   * channel's scope, or on an error it cannot retry.
   */
  private connect(inputs: Queue.Queue<ConnectionInput>): Effect.Effect<void> {
    return Effect.gen({ self: this }, function* () {
      let delay: PollDelay = 0;
      let restartAfter = false;
      for (;;) {
        if (delay !== 0) {
          const until = delay === "idle" ? undefined : this.env.now() + delay;
          for (;;) {
            const wait =
              until === undefined
                ? Effect.never
                : Effect.sleep(Duration.millis(Math.max(0, until - this.env.now())));
            const woke = yield* Effect.raceFirst(
              wait.pipe(Effect.as("timer" as const)),
              Queue.take(inputs)
            );
            if (woke !== "restart") break;
            restartAfter = true;
          }
        }
        if (!this.active) return;
        if (!this.env.visibility?.isVisible()) {
          this.setState({ connection: "paused" });
          delay = "idle";
          continue;
        }
        let refreshAfter = false;
        // The poll's identity as well as its cancel: its callbacks check it (`abortController`), and a restart aborts it
        // before the fiber is stopped, so nothing the old poll still delivers lands.
        // @effect-diagnostics-next-line abortControllerInEffect:off
        const controller = new AbortController();
        const poll = yield* Effect.forkChild(
          this.pollOnce(controller),
          // The poll starts as it is asked for, as a call would: what it sends goes out now.
          { startImmediately: true }
        );
        let outcome: PollOutcome = "stale";
        for (;;) {
          const next = yield* Effect.raceFirst(
            Fiber.join(poll).pipe(Effect.map((done) => ({ done }))),
            Queue.take(inputs).pipe(Effect.map((input) => ({ input })))
          );
          if ("done" in next) {
            outcome = next.done;
            break;
          }
          if (next.input === "now") continue;
          if (next.input === "refresh") {
            refreshAfter = true;
            if (this.transportMode !== "task-events") continue;
          }
          // A restart (a kick, or a refresh of a task's detail): the poll under way stops (its callbacks fenced
          // first), and another starts at once. What else its caller asks in the same turn rides on that one poll.
          this.activeStreamIncarnation = undefined;
          controller.abort();
          yield* Effect.promise(() => Promise.resolve());
          for (const input of yield* Queue.clear(inputs))
            if (input === "refresh") refreshAfter = true;
          yield* Fiber.interrupt(poll);
          restartAfter = true;
          break;
        }
        if (outcome === "fatal") return;
        if (refreshAfter && this.transportMode === "task-events")
          this.taskDetailRefreshNeeded = true;
        delay =
          refreshAfter || restartAfter ? 0 : outcome === "stale" ? "idle" : outcome;
        restartAfter = false;
      }
    });
  }

  /** One poll: the conversation's detail and its stream; when to poll next, as far as it says. */
  private pollOnce(controller: AbortController): Effect.Effect<PollOutcome> {
    return Effect.suspend(() => {
      const pollEpoch = this.epoch;
      let streamIncarnation: number | undefined;
      this.abortController = controller;
      this.setState({
        connection:
          this.state.lastBackoffMs > 0
            ? "reconnecting"
            : this.state.connection === "live"
              ? "live"
              : "connecting",
        status: this.state.conversation ? "ready" : "loading",
        syncWarning:
          this.state.syncWarning === "suspect-empty" ? "suspect-empty" : undefined,
      });

      return Effect.gen({ self: this }, function* () {
        if (this.transportMode !== "events") {
          const taskHandled =
            this.transportMode === "task-events" && !this.taskDetailRefreshNeeded
              ? true
              : yield* this.pollDetail(controller, pollEpoch);

          if (taskHandled) {
            if (controller.signal.aborted) return "stale" as const;
            yield* this.streamTaskInvalidations(controller, pollEpoch);

            if (this.active && pollEpoch === this.epoch && !controller.signal.aborted) {
              this.setState({
                connection: "live",
                errorKind: undefined,
                lastBackoffMs: 0,
                status: "ready",
              });
              // A task's invalidation stream ended: the next one opens at once.
              return 0;
            }
            return "stale" as const;
          }
        }

        const currentStreamIncarnation = ++this.nextStreamIncarnation;
        streamIncarnation = currentStreamIncarnation;
        this.activeStreamIncarnation = currentStreamIncarnation;
        this.activityStreamIncarnation = currentStreamIncarnation;
        this.activitySnapshotReadyIncarnation = undefined;
        // The producer cursor is a high watermark that must survive reconnects:
        // clearing it here would let a stale same-epoch frame with a lower
        // sequence, or the first frame of a retired epoch, re-establish an old
        // baseline and roll the Activity presentation backwards.
        this.visibleReplyPresentation = beginVisibleReplyStream(
          this.visibleReplyPresentation,
          currentStreamIncarnation
        );

        const streamOpts: Parameters<CommaApiClient["streamConversationEvents"]>[2] = {
          onEvent: (event, eventName) => {
            if (
              this.active &&
              pollEpoch === this.epoch &&
              this.activeStreamIncarnation === currentStreamIncarnation &&
              !controller.signal.aborted
            ) {
              if (this.state.connection !== "live" || this.state.lastBackoffMs !== 0) {
                this.setState({
                  connection: "live",
                  lastBackoffMs: 0,
                  status: "ready",
                });
              }
              this.handleEvent(event, eventName, currentStreamIncarnation);
            }
          },
        };
        if (this.streamWaitMs !== undefined) {
          streamOpts.waitMs = this.streamWaitMs;
        }

        yield* this.api.streamConversationEvents(
          this.groupId,
          this.conversationId,
          streamOpts
        );

        if (
          !this.active ||
          pollEpoch !== this.epoch ||
          this.activeStreamIncarnation !== currentStreamIncarnation
        ) {
          return "stale" as const;
        }

        this.setState({
          connection: "live",
          lastBackoffMs: 0,
          status: "ready",
          syncWarning:
            this.state.syncWarning === "suspect-empty" ? "suspect-empty" : undefined,
        });
        return this.nextStreamDelay();
      }).pipe(
        Effect.catch((error: Error) =>
          Effect.sync(() =>
            !this.active || pollEpoch !== this.epoch || controller.signal.aborted
              ? ("stale" as const)
              : this.handlePollError(error)
          )
        ),
        Effect.ensuring(
          Effect.sync(() => {
            if (
              streamIncarnation !== undefined &&
              this.activeStreamIncarnation === streamIncarnation
            ) {
              this.activeStreamIncarnation = undefined;
            }
            if (this.abortController === controller) {
              this.abortController = undefined;
            }
          })
        )
      );
    });
  }

  private pollDetail(
    controller: AbortController,
    pollEpoch: number
  ): Effect.Effect<boolean, Error> {
    return Effect.gen({ self: this }, function* () {
      const result = yield* this.api.pollConversation(
        this.groupId,
        this.conversationId,
        this.taskEtag ? { etag: this.taskEtag } : {}
      );

      if (!this.active || pollEpoch !== this.epoch || controller.signal.aborted) {
        return true;
      }

      if (result.conversation) {
        this.applyConversation(result.conversation, {
          emit: result.conversation.kind !== "agent_task",
        });
        this.transportMode =
          result.conversation.kind === "agent_task" ? "task-events" : "events";
      }

      if (this.transportMode !== "task-events") {
        return false;
      }

      this.taskEtag = result.etag;
      this.taskDetailRefreshNeeded = false;
      this.setState({
        connection: "live",
        errorKind: undefined,
        lastBackoffMs: 0,
        status: "ready",
        syncWarning:
          this.state.syncWarning === "suspect-empty" ? "suspect-empty" : undefined,
      });

      return true;
    });
  }

  private streamTaskInvalidations(
    controller: AbortController,
    pollEpoch: number
  ): Effect.Effect<void, Error> {
    // Keep the last reliable snapshot through finite-wait EOF and reconnect.
    // Only this incarnation can replace it; stop/auth loss clears the scope.
    return this.api.streamConversationListEvents(this.groupId, {
      conversationId: this.conversationId,
      onParticipantStatuses: (event) => {
        if (
          !this.active ||
          this.abortController !== controller ||
          pollEpoch !== this.epoch ||
          controller.signal.aborted ||
          event.group_id !== this.groupId ||
          event.conversation_id !== this.conversationId
        )
          return;
        this.setState({
          boundWorker: event.bound_worker
            ? {
                participantId: event.bound_worker.participant_id,
                actorId: event.bound_worker.actor_id,
                name: event.bound_worker.name,
              }
            : undefined,
          taskRun: taskRun(event.run),
          participantStatuses: event.participants.map((p) => ({
            conversationId: p.conversation_id,
            participantId: p.participant_id,
            actorId: p.actor_id,
            actorRole: p.actor_role,
            name: p.name,
            state: p.state,
            status: p.status,
            updatedAt: p.updated_at,
            ...(p.issue ? { issue: p.issue } : {}),
            ...(p.issue && participantIssueDetail(p.issue_detail)
              ? { issueDetail: participantIssueDetail(p.issue_detail) }
              : {}),
          })),
        });
      },
      waitMs: TASK_EVENT_WAIT_MS,
      onEvent: (event) => {
        if (
          !this.active ||
          this.abortController !== controller ||
          pollEpoch !== this.epoch ||
          controller.signal.aborted ||
          event.group_id !== this.groupId ||
          event.kind !== "agent_task"
        ) {
          return;
        }

        if (this.state.connection !== "live" || this.state.lastBackoffMs !== 0) {
          this.setState({
            connection: "live",
            errorKind: undefined,
            lastBackoffMs: 0,
            status: "ready",
          });
        }

        if (event.version === this.taskListVersion) return;

        this.taskListVersion = event.version;
        this.taskDetailRefreshNeeded = true;
        this.restartCurrentStream();
      },
    });
  }

  private handleEvent(
    event: CommaConversationEvent,
    eventName: string,
    streamIncarnation: number
  ) {
    if (eventName === "participant_status" || event.type === "participant_status") {
      this.applyParticipantStatus(event, streamIncarnation);
      return;
    }

    if (
      eventName === "participant_status_cleared" ||
      event.type === "participant_status_cleared"
    ) {
      this.applyParticipantStatusClear(event, streamIncarnation);
      return;
    }

    if (eventName === "activity" || event.type === "activity") {
      this.applyActivity(event, streamIncarnation);
      return;
    }

    if (isAssistantDraftEvent(event, eventName)) {
      this.applyAssistantDraft(event, streamIncarnation);
      return;
    }

    if (isUserMessageCreated(event, eventName)) {
      this.recordMessageObservation(event);
      return;
    }

    if (isAssistantMessageCreated(event, eventName)) {
      this.recordMessageObservation(event);
      this.restartCurrentStream();
      return;
    }

    if (
      eventName === "conversation_invalidated" ||
      event.type === "conversation_invalidated"
    ) {
      this.restartCurrentStream();
      return;
    }

    if (eventName !== "snapshot" && event.type !== "snapshot") {
      return;
    }

    const raw = event as CommaConversationEvent & Record<string, unknown>;
    this.detectStreamCapability(event);
    const nextConversation: CommaConversation = {
      group_id: event.group_id ?? this.state.conversation?.group_id ?? this.groupId,
      id: event.conversation_id ?? this.state.conversation?.id ?? this.conversationId,
      // `/events` is a user_chat-only contract; agent_task detail follows the
      // Group Task-list invalidation stream and exact conditional reads.
      kind: "user_chat",
      title: stringValue(raw.title) ?? this.state.conversation?.title ?? "",
      status: event.status ?? this.state.conversation?.status ?? "completed",
      activity_status:
        stringValue(raw.activity_status) ?? this.state.conversation?.activity_status,
      messages: event.messages ?? this.state.conversation?.messages ?? [],
      created_at: this.state.conversation?.created_at,
      updated_at: this.state.conversation?.updated_at,
    };

    this.applyConversation(nextConversation, {
      eventStatus: event.status,
      streamIncarnation,
      participantDraft: this.snapshotParticipantDraft(event),
      participantStatus: participantStatusValue(
        event.participant_status,
        this.conversationId
      ),
    });
    this.activitySnapshotReadyIncarnation = streamIncarnation;
  }

  private snapshotParticipantDraft(
    event: CommaConversationEvent
  ): VisibleReplyDraftFrame | null | undefined {
    const draft = event.participant_draft;
    if (!draft) return draft;
    const sourceMessageIds = exactOrderedStringArrayValue(draft.source_message_ids);
    if (
      draft.conversation_id !== this.conversationId ||
      sourceMessageIds.length === 0
    ) {
      return undefined;
    }
    return {
      conversationId: draft.conversation_id,
      draftId: draft.draft_id,
      responseKey: draft.response_key,
      revision: draft.revision,
      sourceMessageIds,
      kind: "started",
      text: draft.text,
    };
  }

  private applyParticipantStatus(
    event: CommaConversationEvent,
    streamIncarnation: number
  ) {
    if (
      this.activityStreamIncarnation !== streamIncarnation ||
      this.activitySnapshotReadyIncarnation !== streamIncarnation
    ) {
      return;
    }
    const participantStatus = participantStatusValue(event, this.conversationId);
    if (participantStatus) this.setState({ participantStatus });
  }

  private applyParticipantStatusClear(
    event: CommaConversationEvent,
    streamIncarnation: number
  ) {
    const raw = event as CommaConversationEvent & Record<string, unknown>;
    const conversationId = stringValue(raw.conversation_id);
    const participantId = stringValue(raw.participant_id);

    if (
      this.activityStreamIncarnation !== streamIncarnation ||
      this.activitySnapshotReadyIncarnation !== streamIncarnation ||
      conversationId !== this.conversationId ||
      participantId === undefined ||
      raw.reason !== "owner_unavailable"
    ) {
      return;
    }

    this.clearActivity();
    if (this.state.participantStatus !== undefined) {
      this.setState({ participantStatus: undefined });
    }
  }

  private detectStreamCapability(event: CommaConversationEvent) {
    const raw = event as CommaConversationEvent & Record<string, unknown>;
    const stream = objectValue(raw.stream);
    if (!stream) {
      return;
    }

    const waitMs = numberValue(stream.window_ms);
    this.streamWaitMs =
      stream.drafts === true && waitMs !== undefined ? waitMs : undefined;
  }

  private applyAssistantDraft(
    event: CommaConversationEvent,
    streamIncarnation: number
  ) {
    const raw = event as CommaConversationEvent & Record<string, unknown>;
    const conversationId = stringValue(raw.conversation_id);
    if (conversationId && conversationId !== this.conversationId) {
      return;
    }

    const draftId = stringValue(raw.draft_id);
    const responseKey = stringValue(raw.response_key);
    const sourceMessageIds = exactOrderedStringArrayValue(raw.source_message_ids);
    const kind = visibleReplyDraftFrameKind(raw);
    if (!draftId || !responseKey || sourceMessageIds.length === 0 || !kind) {
      return;
    }

    const reduction = reduceVisibleReplyDraft(
      this.visibleReplyPresentation,
      streamIncarnation,
      {
        conversationId: conversationId ?? this.conversationId,
        delta: stringValue(raw.delta),
        draftId,
        kind,
        responseKey,
        revision: nonNegativeIntegerValue(raw.revision),
        sourceMessageIds,
        text: stringValue(raw.text) ?? "",
      }
    );
    if (reduction.presentation !== this.visibleReplyPresentation) {
      this.visibleReplyPresentation = reduction.presentation;
      this.settleLocallyAwaitedReplyForSources(sourceMessageIds);
      if (
        reduction.presentation.activeDraft &&
        !this.draftFirstObservedSequences.has(draftId)
      ) {
        setBoundedObservation(
          this.draftFirstObservedSequences,
          draftId,
          this.nextObservationSequence()
        );
      }

      this.setState({
        assistantDraft: this.visibleReplyPresentation.activeDraft,
      });
    }

    if (reduction.restartStream) {
      this.restartCurrentStream();
    }
  }

  private applyActivity(event: CommaConversationEvent, streamIncarnation: number) {
    const raw = event as CommaConversationEvent & Record<string, unknown>;
    const conversationId = stringValue(raw.conversation_id);

    if (conversationId && conversationId !== this.conversationId) {
      return;
    }

    // Activity v2 is source-bound presentation state, not an aggregate hint.
    // The first conversation snapshot authorizes one local SSE incarnation;
    // callbacks from old streams are already fenced by handleEvent.
    if (
      this.activityStreamIncarnation !== streamIncarnation ||
      this.activitySnapshotReadyIncarnation !== streamIncarnation
    ) {
      return;
    }

    // Validate summary authority before accepting the producer cursor.
    const producerEpoch = stringValue(raw.producer_epoch);
    const responseKey = stringValue(raw.response_key);
    const sequence = positiveIntegerValue(raw.sequence);
    const sourceMessageIds = exactOrderedStringArrayValue(raw.source_message_ids);
    const summaryClass = activitySummaryClassValue(raw.summary_class);
    const payload =
      summaryClass === undefined ? undefined : activityPayloadValue(raw, summaryClass);
    if (
      producerEpoch === undefined ||
      responseKey === undefined ||
      sequence === undefined ||
      sourceMessageIds.length === 0 ||
      summaryClass === undefined ||
      payload === undefined
    ) {
      return;
    }

    if (
      !this.acceptActivityProducerCursor(producerEpoch, sequence, streamIncarnation)
    ) {
      return;
    }

    const responseIdentityKey = visibleReplyIdentityKey(responseKey, sourceMessageIds);
    const current = isBoundChatActivity(this.state.activity)
      ? this.state.activity
      : undefined;
    const sameResponse =
      current !== undefined &&
      visibleReplyIdentityKey(current.responseKey, current.sourceMessageIds) ===
        responseIdentityKey;
    const ownerTurnKey = sameResponse
      ? current.ownerTurnKey
      : initialResponseOwnerTurnKey(
          this.state.messages,
          responseIdentityKey,
          sourceMessageIds
        );

    // The local indicator bridges send admission to actual runtime feedback.
    // Only this exact source binding can hand it over; Participant stopped
    // replays and timestamps cannot identify which local send was handled.
    const handedOffLocalReply =
      this.settleLocallyAwaitedReplyForSources(sourceMessageIds);

    if (payload.status === "idle") {
      if (!sameResponse) {
        if (handedOffLocalReply) this.rebuildState({ emit: true });
        return;
      }
      // Preserve a failure frame emitted immediately before the terminal idle
      // signal. It is the only user-visible outcome when the model failed
      // before committing an assistant message.
      if (isFailedActivity(current)) {
        return;
      }
      this.clearActivity();
      if (handedOffLocalReply) this.rebuildState({ emit: true });
      return;
    }

    const activity: BoundChatActivity = {
      action: payload.action,
      conversationId: conversationId ?? this.conversationId,
      displayHoldMs: numberValue(raw.display_hold_ms),
      displayPriority: stringValue(raw.display_priority),
      displayStrength: stringValue(raw.display_strength),
      goal: payload.goal,
      ownerTurnKey,
      phase: payload.phase,
      producerEpoch,
      responseKey,
      sequence,
      sourceMessageIds,
      status: payload.status,
      streamIncarnation,
      summary: payload.summary,
      summaryClass,
      toolName: payload.toolName,
      updatedAt: numberValue(raw.updated_at),
    };

    this.clearActivityTimer();
    if (isFailedActivity(activity)) {
      this.setState({ activity });
      return;
    }
    this.setState({ activity });
    this.activityTimer = after(this.env, ACTIVITY_TTL_MS, () => {
      this.activityTimer = undefined;
      this.clearActivity();
    });
  }

  private acceptActivityProducerCursor(
    producerEpoch: string,
    sequence: number,
    streamIncarnation: number
  ) {
    if (this.activityProducerEpoch === undefined) {
      this.activityProducerEpoch = producerEpoch;
      this.activityProducerSequence = sequence;
      this.activityCursorIncarnation = streamIncarnation;
      return true;
    }

    if (producerEpoch === this.activityProducerEpoch) {
      // Same epoch continuing (possibly across a reconnect): the sequence
      // watermark survives, so replayed or reordered frames cannot roll the
      // presentation backwards. A new snapshot-first incarnation may replay
      // the frame AT the watermark once — the local TTL can have cleared the
      // presentation while the frame is still the producer's current state,
      // and rejecting the equal-sequence replay would leave the surface
      // empty until the next producer step. Admission is commit-on-accept:
      // a rejected lower frame cannot consume this incarnation's one baseline
      // slot before the equal current frame arrives.
      const firstFrameOfIncarnation =
        streamIncarnation !== this.activityCursorIncarnation;
      if (
        this.activityProducerSequence !== undefined &&
        (firstFrameOfIncarnation
          ? sequence < this.activityProducerSequence
          : sequence <= this.activityProducerSequence)
      ) {
        return false;
      }
      this.activityCursorIncarnation = streamIncarnation;
      this.activityProducerSequence = sequence;
      return true;
    }

    if (this.activityRetiredProducerEpochs.has(producerEpoch)) {
      // A retired epoch can never re-establish a baseline, not even as the
      // first frame after a reconnect.
      return false;
    }

    if (streamIncarnation !== this.activityCursorIncarnation) {
      // First sight of a genuinely new producer epoch inside a new
      // snapshot-first incarnation: turn the cursor over and retire the old
      // epoch so its stale frames stay rejected.
      this.activityRetiredProducerEpochs.add(this.activityProducerEpoch);
      if (this.activityRetiredProducerEpochs.size > 32) {
        const oldest = this.activityRetiredProducerEpochs.values().next().value;
        if (oldest !== undefined) this.activityRetiredProducerEpochs.delete(oldest);
      }
      this.activityProducerEpoch = producerEpoch;
      this.activityProducerSequence = sequence;
      this.activityCursorIncarnation = streamIncarnation;
      return true;
    }

    // A mid-stream epoch change is authorized only by a new snapshot-first
    // SSE incarnation. Reject this frame and reconnect; the next
    // incarnation's first v2 activity turns the cursor over.
    this.restartCurrentStream();
    return false;
  }

  private applyConversation(
    conversation: CommaConversation,
    opts: {
      emit?: boolean;
      eventStatus?: string | undefined;
      streamIncarnation?: number | undefined;
      participantDraft?: VisibleReplyDraftFrame | null | undefined;
      participantStatus?: ChatParticipantStatus | undefined;
    } = {}
  ) {
    if (
      conversation.group_id !== this.groupId ||
      conversation.id !== this.conversationId
    ) {
      throw new Error("Conversation response crossed its canonical Group boundary.");
    }
    const nextRawMessages = conversation.messages ?? [];
    const suspiciousEmpty =
      this.serverMessages.length > 0 && nextRawMessages.length === 0;
    const nextServerMessages = suspiciousEmpty
      ? this.serverMessages
      : normalizeServerMessages(
          nextRawMessages,
          this.serverMessages,
          conversation.kind,
          conversation.id
        );

    // Streamed deltas live in the assistant draft, so a message id reaching
    // serverMessages is always a committed message. The baseline separates the
    // first history snapshot from later appends.
    const hadCanonicalBaseline = this.hasObservedCanonicalSnapshot;
    const previousServerMessages = this.serverMessages;

    if (!suspiciousEmpty) {
      this.recordConversationObservations(nextServerMessages);
      this.settleLocallyAwaitedReplyFromTranscript(nextServerMessages);
      this.notifyCommittedLocalFiles(nextRawMessages);
    }

    this.serverMessages = nextServerMessages;
    if (!suspiciousEmpty) {
      this.hasObservedCanonicalSnapshot = true;
      this.coverage = this.coverage.addRuns(messageSeqs(nextRawMessages));
    }

    if (!suspiciousEmpty && hadCanonicalBaseline && this.onCanonicalMessagesAppended) {
      const knownMessageIds = new Set(
        previousServerMessages.map((message) => message.messageId)
      );
      const appended = nextServerMessages.filter(
        (message) => !knownMessageIds.has(message.messageId)
      );
      if (appended.length > 0) {
        this.onCanonicalMessagesAppended({ conversation, messages: appended });
      }
    }
    if (opts.streamIncarnation !== undefined) {
      this.visibleReplyPresentation = reconcileVisibleReplySnapshot(
        this.visibleReplyPresentation,
        opts.streamIncarnation,
        nextServerMessages,
        opts.participantDraft
      );
      const draft = this.visibleReplyPresentation.activeDraft;
      if (draft) {
        this.settleLocallyAwaitedReplyForSources(draft.sourceMessageIds);
        if (!this.draftFirstObservedSequences.has(draft.draftId)) {
          setBoundedObservation(
            this.draftFirstObservedSequences,
            draft.draftId,
            this.nextObservationSequence()
          );
        }
      }
    }

    const reconciledPending = reconcilePending(this.state.pending, nextServerMessages);
    const snapshotSettledActivity = isSettledActivityStatus(
      conversation.activity_status
    );
    const preserveFailureActivity = isFailedActivity(this.state.activity);

    if (snapshotSettledActivity && !preserveFailureActivity) {
      this.clearActivityTimer();
    }

    this.state = {
      ...this.state,
      activity:
        snapshotSettledActivity && !preserveFailureActivity
          ? undefined
          : this.state.activity,
      conversation,
      pending: reconciledPending,
      // The owner status and draft share the snapshot's Participant read. A
      // canonical reply must not inherit the previous feed's active owner
      // while its current stopped status waits in a separate SSE frame.
      participantStatus: opts.participantStatus ?? this.state.participantStatus,
      assistantDraft: this.visibleReplyPresentation.activeDraft,
      serverMessages: nextServerMessages,
      ...(suspiciousEmpty ? {} : this.loopRunsOf(nextRawMessages)),
      history: this.historyState(),
      status: "ready",
      syncWarning: suspiciousEmpty ? "suspect-empty" : undefined,
    };
    this.rebuildState({ emit: opts.emit !== false });
    this.fillGaps();
  }

  // --- History: pages by seq --------------------------------------------------------------------------------------

  private historyState(): ConversationHistory | undefined {
    const ranges = this.coverage.ranges;
    if (ranges.length === 0) return undefined;
    const first = ranges[0]![0];
    return {
      hasOlder: this.historyHead === undefined ? first > 1 : first > this.historyHead,
      loadingOlder: this.loadingOlder,
      ranges: ranges.map(([from, to]) => [from, to]),
    };
  }

  /** Holds a page's messages and the seq it proves read. */
  private applyPage(page: CommaMessagePage) {
    const bounds = page.bounds;
    let coverage = this.coverage;
    // History before the server's first message is gone; the ranges cannot claim it.
    if (bounds && coverage.ranges.some((range) => range[0] < bounds.first))
      coverage = coverage.clip(bounds.first, Number.MAX_SAFE_INTEGER);
    if (page.covered) coverage = coverage.add(page.covered.first, page.covered.last);
    this.coverage = coverage;
    if (bounds) this.historyHead = bounds.first;
    const kind = this.state.conversation?.kind ?? "user_chat";
    this.serverMessages = normalizeServerMessages(
      page.messages,
      this.serverMessages,
      kind,
      this.conversationId
    );
    this.state = {
      ...this.state,
      history: this.historyState(),
      pending: reconcilePending(this.state.pending, this.serverMessages),
      serverMessages: this.serverMessages,
      ...this.loopRunsOf(page.messages),
    };
    this.rebuildState({ emit: true });
  }

  /** The Loop runs held, with those a page of raw messages adds; a Task holds them only once it has some. */
  private loopRunsOf(
    raw: readonly SalixMessage[]
  ): Pick<ConversationChannelState, "loopRuns"> {
    const held = this.state.loopRuns ?? [];
    const runs = withLoopRuns(held, raw);
    return runs.length === 0 ? {} : { loopRuns: runs };
  }

  /**
   * Reads the page before the oldest message held. One at a time; a failure leaves the transcript as it is, and the
   * next call asks again.
   */
  loadOlder() {
    const first = this.coverage.ranges[0]?.[0];
    // An API given without pages (a test's) has none to read.
    if (typeof this.api.listMessages !== "function") return;
    if (this.loadingOlder || first === undefined || !this.historyState()?.hasOlder)
      return;
    const epoch = this.epoch;
    this.loadingOlder = true;
    this.state = { ...this.state, history: this.historyState() };
    this.rebuildState({ emit: true });
    this.env.runner.fork(
      this.api
        .listMessages(this.groupId, this.conversationId, {
          before: first,
          limit: OLDER_PAGE,
        })
        .pipe(
          Effect.match({
            onSuccess: (page) => {
              this.loadingOlder = false;
              if (this.epoch !== epoch) return;
              // An empty page means nothing precedes the oldest message held.
              if (!page.covered && !page.hasOlder && !page.bounds)
                this.historyHead = first;
              this.applyPage(page);
            },
            onFailure: () => {
              this.loadingOlder = false;
              if (this.epoch !== epoch) return;
              this.state = { ...this.state, history: this.historyState() };
              this.rebuildState({ emit: true });
            },
          })
        )
    );
  }

  /**
   * Reads a Task's history before the transcript held, for its Activity: pages cut to what it reads
   * (`view=activity`), newest first, back to the Task's first message. It is read only once it reaches that message.
   * One read at a time; a failure, or a page that reaches no further back, keeps what was read, and the next call
   * goes on from there.
   */
  readActivityHistory() {
    if (this.state.conversation?.kind !== "agent_task") return;
    if (typeof this.api.listMessages !== "function") return;
    if (this.readingActivity || this.activityHistoryRead) return;
    if (this.activityBefore === undefined && !this.historyState()?.hasOlder) return;
    const epoch = this.epoch;
    this.readingActivity = true;
    this.state = { ...this.state, activityEarlier: "reading" };
    this.rebuildState({ emit: true });
    const read = Effect.gen({ self: this }, function* () {
      for (;;) {
        const before = this.activityBefore ?? this.coverage.ranges[0]?.[0];
        if (before === undefined) return;
        const page = yield* this.api.listMessages(this.groupId, this.conversationId, {
          before,
          limit: ACTIVITY_PAGE,
          view: "activity",
        });
        if (this.epoch !== epoch) return;
        // A page that reaches no further back would read the same page forever.
        if (page.covered && page.covered.first >= before) return;
        if (page.covered) this.activityBefore = page.covered.first;
        const older = normalizeServerMessages(
          page.messages,
          [],
          "agent_task",
          this.conversationId
        );
        this.state = {
          ...this.state,
          activityHistory: [...older, ...(this.state.activityHistory ?? [])],
          ...this.loopRunsOf(page.messages),
        };
        this.rebuildState({ emit: true });
        if (!page.covered || !page.hasOlder) {
          this.activityHistoryRead = true;
          this.state = { ...this.state, activityEarlier: undefined };
          this.rebuildState({ emit: true });
          return;
        }
      }
    });
    this.env.runner.fork(
      read.pipe(
        Effect.ignore,
        Effect.ensuring(
          Effect.sync(() => {
            this.readingActivity = false;
            // Stopped short of the first message: the Activity shows it and the next call goes on.
            if (!this.activityHistoryRead && this.state.activityEarlier === "reading") {
              this.state = { ...this.state, activityEarlier: "unread" };
              this.rebuildState({ emit: true });
            }
          })
        )
      )
    );
  }

  /**
   * Closes the gaps between the ranges read, newest first, by paging forward from the end of the range below each.
   * One fill at a time; the next snapshot starts another when a gap is left.
   */
  private fillGaps() {
    if (this.fillingGaps || this.coverage.beforeTail === undefined) return;
    if (typeof this.api.listMessages !== "function") return;
    const epoch = this.epoch;
    this.fillingGaps = true;
    const fill = Effect.gen({ self: this }, function* () {
      for (let pages = 0; pages < MAX_GAP_PAGES; pages++) {
        const watermark = this.coverage.beforeTail?.[1];
        if (watermark === undefined || this.epoch !== epoch) return;
        const page = yield* this.api.listMessages(this.groupId, this.conversationId, {
          after: watermark,
          limit: GAP_PAGE,
        });
        if (this.epoch !== epoch) return;
        const before = this.coverage;
        this.applyPage(page);
        if (!page.covered || this.coverage.equals(before)) return;
      }
    });
    this.env.runner.fork(
      fill.pipe(
        Effect.catch((error: Error) =>
          Effect.sync(() => {
            // The watermark is outside what the server still has: only the newest range is kept as read.
            if (
              this.epoch === epoch &&
              error instanceof CommaApiError &&
              error.status === 404
            ) {
              const tail = this.coverage.tail;
              this.coverage = tail ? SeqCoverage.of([tail]) : SeqCoverage.EMPTY;
              this.state = { ...this.state, history: this.historyState() };
              this.rebuildState({ emit: true });
            }
          })
        ),
        Effect.ensuring(Effect.sync(() => (this.fillingGaps = false)))
      )
    );
  }

  private notifyCommittedLocalFiles(messages: readonly SalixMessage[]) {
    if (!this.onLocalFilesCommitted) return;

    for (const message of messages) {
      if (message.actor_type !== "user") continue;
      const files = canonicalLocalFiles(message).filter(
        (file) =>
          !this.committedLocalFileRefs.has(file.localFileRef) &&
          !this.committingLocalFileRefs.has(file.localFileRef)
      );
      if (files.length === 0) continue;

      for (const file of files) {
        this.committingLocalFileRefs.add(file.localFileRef);
      }

      const settle = (committed: boolean) => {
        for (const file of files) {
          this.committingLocalFileRefs.delete(file.localFileRef);
          if (committed) {
            addBoundedSet(
              this.committedLocalFileRefs,
              file.localFileRef,
              PRESENTATION_INDEX_LIMIT
            );
          }
        }
      };

      try {
        this.onLocalFilesCommitted(files, canonicalMessageCreatedAtMs(message));
        settle(true);
      } catch {
        settle(false);
      }
    }
  }

  private nextStreamDelay(): number {
    const hot =
      (this.state.awaitingReply && !this.state.awaitingTimedOut) ||
      this.state.pending.some((pending) => pending.status === "sending");
    return hot ? HOT_STREAM_RECONNECT_MS : WARM_STREAM_RECONNECT_MS;
  }

  private handlePollError(error: unknown): number | "fatal" {
    const errorKind = classifyError(error);

    if (errorKind !== "network") {
      this.active = false;
      this.setState({
        connection: "paused",
        errorKind,
        participantStatuses: undefined,
        boundWorker: undefined,
        taskRun: undefined,
        status: "error",
      });
      return "fatal";
    }

    const nextBackoffMs = Math.min(
      this.state.lastBackoffMs > 0 ? this.state.lastBackoffMs * 2 : INITIAL_BACKOFF_MS,
      MAX_BACKOFF_MS
    );
    this.setState({
      connection: "reconnecting",
      errorKind,
      lastBackoffMs: nextBackoffMs,
      status: this.state.conversation ? "ready" : "error",
      syncWarning:
        this.state.conversation && nextBackoffMs >= STALE_WARNING_BACKOFF_MS
          ? "stale"
          : this.state.syncWarning === "suspect-empty"
            ? "suspect-empty"
            : undefined,
    });
    return nextBackoffMs + this.env.jitterMs(nextBackoffMs);
  }

  private rebuildState({ emit }: { emit: boolean }) {
    const locallyPending = this.locallyAwaitedClientRequestId
      ? this.state.pending.find(
          (pending) =>
            pending.clientRequestId === this.locallyAwaitedClientRequestId &&
            pending.status === "sending"
        )
      : undefined;
    if (
      locallyPending &&
      this.env.now() - (this.locallyAwaitedSince ?? locallyPending.createdAt) >=
        AWAITING_TIMEOUT_MS
    ) {
      this.clearLocalReplyWait();
      this.state = {
        ...this.state,
        pending: replacePending(this.state.pending, {
          ...locallyPending,
          error: undefined,
          failureAction: undefined,
          status: "failed",
        }),
      };
    }

    const awaitingReply = isTerminalStatus(this.state.conversation?.status)
      ? false
      : this.locallyAwaitedClientRequestId !== undefined
        ? true
        : activitySettlesCurrentTurn(this.state.activity, this.serverMessages)
          ? false
          : deriveAwaitingReply(
              this.state.conversation,
              this.state.pending,
              this.serverMessages
            );
    const awaitingSince =
      awaitingReply && this.locallyAwaitedSince !== undefined
        ? this.locallyAwaitedSince
        : deriveAwaitingSince({
            awaitingReply,
            currentAwaitingReply: this.state.awaitingReply,
            currentAwaitingSince: this.state.awaitingSince,
            now: this.env.now(),
          });
    const awaitingTimedOut =
      awaitingReply &&
      awaitingSince !== undefined &&
      this.env.now() - awaitingSince >= AWAITING_TIMEOUT_MS;

    const messages = this.questionStates.inTranscript(this.combineMessagesCached());
    const awaited = awaitedRequest(this.serverMessages);
    const awaitingTurnKey = awaitingReply
      ? (this.locallyAwaitedClientRequestId ??
        this.state.pending.findLast((item) => item.status === "sending")
          ?.clientRequestId ??
        (awaited ? conversationMessageTurnKey(awaited) : undefined))
      : undefined;
    this.state = {
      ...this.state,
      awaitingReply,
      awaitingSince,
      awaitingTimedOut,
      awaitingTurnKey,
      locallyAwaitingReply:
        this.locallyAwaitedClientRequestId !== undefined && !awaitingTimedOut,
      messages,
      questionAttachments: this.withoutClosedCardImages(messages),
      serverMessages: this.questionStates.inServerMessages(
        this.serverMessages,
        messages
      ),
    };

    if (emit) {
      this.emit();
    }
  }

  private readonly questionStates = createQuestionStates();

  private combinedMessagesCache:
    | {
        pending: PendingSend[];
        resolvedIds: string[];
        result: ChatMessage[];
        serverMessages: ChatMessage[];
      }
    | undefined;

  // While a send is in flight, rebuildState runs on every stream chunk. The
  // combined rows (and the array itself) must keep their identities across
  // those rebuilds, or every memoized message row is invalidated during the
  // exact window where streaming makes renders most frequent. The canonical-id
  // map is mutated in place, so the cache compares the resolved ids by value.
  private combineMessagesCached() {
    const serverMessages = this.serverMessages;
    const pending = this.state.pending;
    if (pending.length === 0) {
      this.combinedMessagesCache = undefined;
      return serverMessages;
    }

    const resolvedIds = pending.map(
      (item) =>
        this.canonicalMessageIdsByClientRequestId.get(item.clientRequestId) ??
        `pending:${item.clientRequestId}`
    );
    const cache = this.combinedMessagesCache;
    if (
      cache &&
      cache.serverMessages === serverMessages &&
      cache.pending === pending &&
      cache.resolvedIds.length === resolvedIds.length &&
      cache.resolvedIds.every((id, index) => id === resolvedIds[index])
    ) {
      return cache.result;
    }

    const result = combineMessages(serverMessages, pending, resolvedIds);
    this.combinedMessagesCache = { pending, resolvedIds, result, serverMessages };
    return result;
  }

  private setState(patch: Partial<ConversationChannelState>) {
    this.state = { ...this.state, ...patch };
    this.rebuildState({ emit: false });
    this.emit();
  }

  private emit() {
    // The listeners as they were: one that a listener adds (a waiter that waits again) hears the next change.
    for (const listener of Array.from(this.listeners)) {
      listener();
    }
  }

  private restartCurrentStream() {
    // Fence callbacks before the poll is stopped: the stream parser may still drain an
    // already-buffered SSE frame while the fetch cancellation is settling.
    this.activeStreamIncarnation = undefined;
    this.abortController?.abort();
    if (this.connection) Effect.runSync(Queue.offer(this.connection.inputs, "restart"));
  }

  private abortUploads() {
    for (const id of Array.from(this.uploads.keys())) this.stopUpload(id);
  }

  private clearActivity() {
    this.clearActivityTimer();

    if (this.state.activity !== undefined) {
      this.setState({ activity: undefined });
    }
  }

  private clearActivityTimer() {
    if (this.activityTimer) {
      cancel(this.env, this.activityTimer);
      this.activityTimer = undefined;
    }
  }

  private recordMessageObservation(event: CommaConversationEvent) {
    const raw = event as CommaConversationEvent & Record<string, unknown>;
    const messageId = stringValue(raw.message_id);
    if (!messageId) {
      return;
    }

    const clientRequestId = stringValue(raw.client_request_id);
    if (clientRequestId) {
      setBoundedValue(
        this.canonicalMessageIdsByClientRequestId,
        clientRequestId,
        messageId
      );
    }
    this.recordMessageFirstObservation(messageId, clientRequestId);
    if (
      raw.role === "assistant" &&
      !raw.platform_message &&
      !(Array.isArray(raw.content) && milestonesOfBlocks(raw.content)?.standalone) &&
      this.locallyAwaitedClientRequestId
    ) {
      const localUserMessageId = this.canonicalMessageIdsByClientRequestId.get(
        this.locallyAwaitedClientRequestId
      );
      if (localUserMessageId) {
        this.clearLocalReplyWait();
      }
    }
    this.rebuildState({ emit: true });
  }

  private recordConversationObservations(messages: readonly ChatMessage[]) {
    for (const message of messages) {
      if (message.clientRequestId) {
        setBoundedValue(
          this.canonicalMessageIdsByClientRequestId,
          message.clientRequestId,
          message.messageId
        );
      }
      this.recordMessageFirstObservation(message.messageId, message.clientRequestId);
    }
  }

  private settleLocallyAwaitedReplyForSources(sourceMessageIds: readonly string[]) {
    const clientRequestId = this.locallyAwaitedClientRequestId;
    if (!clientRequestId) return;
    const messageId = this.canonicalMessageIdsByClientRequestId.get(clientRequestId);
    if (messageId && sourceMessageIds.includes(messageId)) {
      this.clearLocalReplyWait();
      return true;
    }
    return false;
  }

  private settleLocallyAwaitedReplyFromTranscript(messages: readonly ChatMessage[]) {
    const clientRequestId = this.locallyAwaitedClientRequestId;
    if (!clientRequestId) return;
    const messageId = this.canonicalMessageIdsByClientRequestId.get(clientRequestId);
    if (!messageId) return;
    const userIndex = messages.findIndex((message) => message.messageId === messageId);
    if (
      userIndex >= 0 &&
      messages.slice(userIndex + 1).some(
        (message) =>
          message.role === "assistant" &&
          !message.platformSource &&
          // A message that only records milestones is no reply anyone sees.
          shownInTranscript(message)
      )
    ) {
      this.clearLocalReplyWait();
    }
  }

  private beginLocalReplyWait(clientRequestId: string) {
    this.clearLocalReplyWait();
    this.locallyAwaitedClientRequestId = clientRequestId;
    this.locallyAwaitedSince = this.env.now();
    // At most one one-shot timer per channel, independent of message count.
    // It only updates local presentation and never performs network reads.
    this.localReplyTimer = after(this.env, AWAITING_TIMEOUT_MS, () => {
      this.localReplyTimer = undefined;
      this.rebuildState({ emit: true });
    });
  }

  private clearLocalReplyWait() {
    this.locallyAwaitedClientRequestId = undefined;
    this.locallyAwaitedSince = undefined;
    if (this.localReplyTimer !== undefined) {
      cancel(this.env, this.localReplyTimer);
      this.localReplyTimer = undefined;
    }
  }

  private nextObservationSequence() {
    this.observationSequence += 1;
    return this.observationSequence;
  }

  private recordMessageFirstObservation(messageId: string, clientRequestId?: string) {
    const relatedSequences = [
      this.messageFirstObservedSequences.get(messageId),
      clientRequestId
        ? this.clientRequestFirstObservedSequences.get(clientRequestId)
        : undefined,
    ].filter((sequence): sequence is number => sequence !== undefined);
    const sequence =
      relatedSequences.length > 0
        ? Math.min(...relatedSequences)
        : this.nextObservationSequence();

    setBoundedObservation(
      this.messageFirstObservedSequences,
      messageId,
      Math.min(this.messageFirstObservedSequences.get(messageId) ?? sequence, sequence)
    );
    if (clientRequestId) {
      setBoundedObservation(
        this.clientRequestFirstObservedSequences,
        clientRequestId,
        Math.min(
          this.clientRequestFirstObservedSequences.get(clientRequestId) ?? sequence,
          sequence
        )
      );
    }
  }

  private createClientRequestId() {
    return this.env.createClientRequestId();
  }
}

export function toConversationProjection(
  state: ConversationChannelState,
  context: { groupId: string; workspaceId: string }
): import("@comma/chat-contract").ConversationProjection {
  const conversation = state.conversation;
  const activity = isBoundChatActivity(state.activity) ? state.activity : undefined;
  return {
    ...(activity ? { activity } : {}),
    ...(state.assistantDraft
      ? {
          assistantDraft: {
            ...state.assistantDraft,
            // Parsed as it grows, once for every client.
            markdown: draftMarkdown(
              state.assistantDraft.draftId,
              state.assistantDraft.text,
              state.assistantDraft.status === "completed"
            ) as ContractChatMessage["markdown"],
          },
        }
      : {}),
    awaitingReply: state.awaitingReply,
    ...(state.awaitingSince === undefined
      ? {}
      : { awaitingSince: state.awaitingSince }),
    awaitingTimedOut: state.awaitingTimedOut,
    reply: replyState(state),
    ...(state.awaitingTurnKey === undefined
      ? {}
      : { awaitingTurnKey: state.awaitingTurnKey }),
    locallyAwaitingReply: state.locallyAwaitingReply === true,
    connection: state.connection,
    ...(conversation
      ? {
          conversation: {
            ...(conversation.created_at === undefined
              ? {}
              : { createdAt: conversation.created_at }),
            ...(conversation.client_platform === undefined
              ? {}
              : { clientPlatform: conversation.client_platform }),
            id: conversation.id,
            groupId: context.groupId,
            kind: conversation.kind,
            ...(conversation.labels === undefined
              ? {}
              : { labels: conversation.labels }),
            ...(conversation.origin === undefined
              ? {}
              : { origin: conversation.origin }),
            ...(conversation.review_version === undefined
              ? {}
              : { reviewVersion: conversation.review_version }),
            status: conversation.status,
            title: conversation.title,
            ...(conversation.updated_at === undefined
              ? {}
              : { updatedAt: conversation.updated_at }),
            workspaceId: context.workspaceId,
          },
        }
      : {}),
    draft: state.draft,
    draftAttachments: state.draftAttachments,
    ...(state.questionAttachments
      ? { questionAttachments: state.questionAttachments }
      : {}),
    ...(state.errorKind ? { errorKind: state.errorKind } : {}),
    ...(state.history ? { history: state.history } : {}),
    lastBackoffMs: state.lastBackoffMs,
    // A message that only records milestones is shown in the Task's Activity, not in any transcript.
    messages: transcriptMessages(state.messages),
    pending: state.pending,
    ...(state.participantStatus
      ? { participantStatus: { ...state.participantStatus } }
      : {}),
    ...(state.boundWorker ? { boundWorker: state.boundWorker } : {}),
    ...(state.taskRun ? { taskRun: state.taskRun } : {}),
    ...(state.participantStatuses
      ? { participantStatuses: state.participantStatuses }
      : {}),
    serverMessages: transcriptMessages(state.serverMessages),
    status: state.status,
    ...(state.syncWarning ? { syncWarning: state.syncWarning } : {}),
    ...taskActivityOf(
      conversation?.kind,
      withActivityHistory(state.activityHistory, state.serverMessages),
      state.loopRuns,
      state.activityEarlier
    ),
  };
}

function taskActivityOf(
  kind: CommaConversationKind | undefined,
  serverMessages: readonly ChatMessage[],
  loopRuns: readonly TaskLoopRun[] | undefined,
  earlier: ChatTaskActivity["earlier"]
): { taskActivity?: ChatTaskActivity } {
  if (kind !== "agent_task") return {};
  const activity = taskActivity(serverMessages, loopRuns);
  if (!earlier) return activity ? { taskActivity: activity } : {};
  // What is not read yet shows even before any milestone is.
  const groups = activity?.groups ?? [];
  return {
    taskActivity: { key: `${earlier}:${activity?.key ?? ""}`, groups, earlier },
  };
}

function normalizeEnv(env: ConversationChannelEnv): ConversationChannelEnv {
  return { ...env, visibility: env.visibility ?? alwaysVisible };
}

const alwaysVisible: ConversationVisibility = {
  isVisible: () => true,
  subscribe: () => () => {},
};

/** Canonical Comma Message to chat presentation projection for live and snapshot views. */
export function normalizeServerMessages(
  rawMessages: SalixMessage[],
  previous: ChatMessage[],
  conversationKind: CommaConversationKind,
  conversationId = ""
) {
  const previousById = new Map(previous.map((message) => [message.messageId, message]));
  const normalizedTail = rawMessages.flatMap((message) => {
    const platformMessage = message.platform_message;
    if (
      !platformMessage &&
      message.actor_type === "system" &&
      (message.agent_input != null ||
        (message.kind === "app_event" &&
          internalEvent(String(message.metadata?.event_type ?? ""))))
    ) {
      return [];
    }
    const content = platformMessage
      ? platformMessage.content.map(legacyPlatformMediaBlock)
      : message.content;
    const text = contentBlocksToText(content);
    if (!platformMessage && isCommaContextMessage(text)) {
      return [];
    }

    const derivedBlockViews = deriveBlockViews(
      content,
      platformMessage
        ? platformMessage.agent_id
        : message.actor_type === "agent"
          ? message.agent_id
          : undefined,
      conversationId,
      message.message_id
    );
    // A platform send's image is bound to the sending Agent's blob so it can
    // show, but the message holds no attachment the download endpoint reads.
    const blockViews = platformMessage
      ? {
          ...derivedBlockViews,
          attachments: derivedBlockViews.attachments.map((attachment) => ({
            ...attachment,
            attachmentIndex: undefined,
          })),
        }
      : derivedBlockViews;
    const strippedText = platformMessage ? text : stripCommaProtocolMarkers(text);
    const role =
      platformMessage?.role ??
      (assistantActorType(message.actor_type) ? "assistant" : "user");
    const display =
      role === "user" && !platformMessage ? decodeUserMessage(strippedText) : undefined;
    const parts = blockViews.parts.some((part) => part.kind !== "markdown")
      ? blockViews.parts
      : display
        ? userParts(display)
        : [{ kind: "markdown" as const, text: strippedText }];
    const messageType = stringValue(message.metadata?.message_type);
    const milestones =
      !platformMessage && message.actor_type === "agent"
        ? milestonesOfBlocks(content)
        : undefined;
    const next: ChatMessage = {
      actorId: message.actor_type === "agent" ? message.agent_id : undefined,
      actorRole: messageActorRole(message, conversationKind),
      actorType: writerOf(message.actor_type),
      attachments: blockViews.attachments,
      blocksKey: blockViews.blocksKey,
      ...(isBrief(messageType, message.client_request_id, conversationId)
        ? { brief: true }
        : {}),
      clientRequestId: message.client_request_id,
      createdAt: message.created_at,
      createdBy: message.user_id,
      delivery: "sent",
      ...(display ? { display } : {}),
      error: undefined,
      messageId: message.message_id,
      messageType,
      ...noticeOf(
        role,
        platformMessage,
        writerOf(message.actor_type),
        messageActorRole(message, conversationKind),
        conversationKind,
        strippedText,
        blockViews.attachments.length > 0
      ),
      ...(milestones ? { milestones } : {}),
      ...(routerRequest(message, conversationKind)
        ? { routerRequest: true as const }
        : {}),
      replyToMessageId: message.reply_to_message_id,
      threadRootMessageId: message.thread_root_message_id,
      parts,
      refs: blockViews.refs,
      role,
      platformSource: platformMessage?.provider,
      seq: messageSeq(message),
      source: "server",
      status: "committed",
      text: strippedText,
    };
    const current = previousById.get(next.messageId);
    // A message kept from before the core parsed messages, or before it read a person's Quick Chat, is read now.
    if (
      current &&
      sameMessage(current, next) &&
      (role !== "assistant" || current.markdown) &&
      (role !== "user" || !announcesTasks(next) || current.createdTasks)
    )
      return [current];
    // Read once, when the message arrives or changes.
    return [{ ...next, ...messageReading(next) }];
  });

  const tailById = new Map(
    normalizedTail.map((message) => [message.messageId, message] as const)
  );
  const knownIds = new Set(previousById.keys());
  const normalized = previous.map(
    (message) => tailById.get(message.messageId) ?? message
  );

  for (const message of normalizedTail) {
    if (knownIds.has(message.messageId)) continue;
    knownIds.add(message.messageId);
    normalized.push(message);
  }

  const ordered = withLatestSetupOffers(bySeq(normalized), rawMessages);
  if (
    ordered.length === previous.length &&
    ordered.every((message, index) => message === previous[index])
  ) {
    return previous;
  }

  return ordered;
}

const DEVICE_SETUP_OFFER = "device_setup_offer";
const DEVICE_SETUP_OFFER_UPDATED = "device_setup_offer.updated";

/**
 * System events that carry no message for the transcript: delivery records, a
 * setup offer's later state, and `mail.*` changes to a Home mail interaction.
 */
function internalEvent(eventType: string) {
  return (
    eventType.startsWith("mail.") ||
    [
      "provider.output",
      "provider.status",
      "provider.message",
      "message.redelivery",
      DEVICE_SETUP_OFFER_UPDATED,
    ].includes(eventType)
  );
}

/** A canonical message's place in its conversation, when the server said it. */
function messageSeq(message: SalixMessage): number | undefined {
  const seq = (message as { seq?: unknown }).seq;
  return typeof seq === "number" && Number.isSafeInteger(seq) && seq > 0
    ? seq
    : undefined;
}

export function messageSeqs(messages: readonly SalixMessage[]): number[] {
  return messages.flatMap((message) => {
    const seq = messageSeq(message);
    return seq === undefined ? [] : [seq];
  });
}

/**
 * The messages by seq, once every one has its seq (a page of older history goes before what is held). A transcript
 * kept from before messages carried a seq stays in the order it has.
 */
function bySeq(messages: ChatMessage[]): ChatMessage[] {
  if (messages.some((message) => message.seq === undefined)) return messages;
  for (let index = 1; index < messages.length; index++)
    if (messages[index - 1]!.seq! > messages[index]!.seq!)
      return messages.toSorted((a, b) => a.seq! - b.seq!);
  return messages;
}

/**
 * Each device setup offer as its latest update says it. An offer's later state arrives as a hidden
 * `device_setup_offer.updated` event; the message that carried the offer shows that state.
 */
function withLatestSetupOffers(
  messages: ChatMessage[],
  rawMessages: readonly SalixMessage[]
): ChatMessage[] {
  const updates = new Map<string, ChatDeviceSetupOffer>();
  for (const message of rawMessages.toSorted(
    (a, b) => (messageSeq(a) ?? 0) - (messageSeq(b) ?? 0)
  )) {
    if (
      message.actor_type !== "system" ||
      message.kind !== "app_event" ||
      message.metadata?.event_type !== DEVICE_SETUP_OFFER_UPDATED
    )
      continue;
    const offer = deviceSetupOfferValue(
      (message.metadata as { offer?: unknown }).offer
    );
    if (!offer) continue;
    const held = updates.get(offer.offerId);
    if (!held || deviceSetupOfferReplaces(held, offer))
      updates.set(offer.offerId, offer);
  }
  if (updates.size === 0) return messages;
  let changed = false;
  const next = messages.map((message) => {
    if (!message.parts?.some((part) => part.kind === "device-setup-offer"))
      return message;
    let touched = false;
    const parts = message.parts.map((part) => {
      if (part.kind !== "device-setup-offer") return part;
      const update = updates.get(part.offer.offerId);
      if (!update || !deviceSetupOfferReplaces(part.offer, update)) return part;
      touched = true;
      return { ...part, offer: update };
    });
    if (!touched) return message;
    changed = true;
    return { ...message, parts };
  });
  return changed ? next : messages;
}

function canonicalLocalFiles(message: SalixMessage): CommaLocalFileRef[] {
  const refs = new Set<string>();
  const files: CommaLocalFileRef[] = [];

  for (const rawBlock of message.content) {
    if (rawBlock.type !== "local_file") continue;
    const block = rawBlock as Record<string, unknown>;
    const localFileRef = stringValue(block.local_file_ref);
    const displayName = stringValue(block.display_name);
    const mediaType = stringValue(block.media_type);
    const size = numberValue(block.size);
    if (
      !localFileRef ||
      !displayName ||
      !mediaType ||
      size === undefined ||
      refs.has(localFileRef)
    ) {
      continue;
    }
    refs.add(localFileRef);
    files.push({ displayName, localFileRef, mediaType, size });
  }

  return files;
}

function canonicalMessageCreatedAtMs(message: SalixMessage) {
  const seconds = message.created_at;
  return typeof seconds === "number" && Number.isSafeInteger(seconds) && seconds >= 0
    ? seconds * 1_000
    : undefined;
}

function sameMessage(a: ChatMessage, b: ChatMessage) {
  return (
    a.actorId === b.actorId &&
    a.actorRole === b.actorRole &&
    a.actorType === b.actorType &&
    a.messageType === b.messageType &&
    a.brief === b.brief &&
    a.routerRequest === b.routerRequest &&
    a.clientRequestId === b.clientRequestId &&
    a.blocksKey === b.blocksKey &&
    a.createdAt === b.createdAt &&
    a.createdBy === b.createdBy &&
    a.delivery === b.delivery &&
    a.error === b.error &&
    a.messageId === b.messageId &&
    a.replyToMessageId === b.replyToMessageId &&
    a.threadRootMessageId === b.threadRootMessageId &&
    a.role === b.role &&
    a.platformSource === b.platformSource &&
    a.seq === b.seq &&
    a.source === b.source &&
    a.status === b.status &&
    a.text === b.text
  );
}

// Platform rows written before typed media blocks carry `[File: name]` text,
// which Markdown would otherwise read as a display-math block.
const LEGACY_PLATFORM_MEDIA_LABEL = /^\[(File|Image)(?:: (.+))?\]$/;

function legacyPlatformMediaBlock(block: SalixContentBlock): SalixContentBlock {
  const match =
    block.type === "text"
      ? LEGACY_PLATFORM_MEDIA_LABEL.exec(String(block.text ?? ""))
      : null;
  if (!match) {
    return block;
  }
  return {
    type: match[1] === "Image" ? "image" : "file",
    ...(match[2] ? { file_name: match[2] } : {}),
  };
}

function contentBlocksToText(content: SalixContentBlock[]): string {
  return content
    .flatMap((block) => {
      const text = rawTextValue(block.text);
      return text === undefined ? [] : [text];
    })
    .join("\n");
}

function writerOf(value: string): ChatMessage["actorType"] {
  return value === "user" || value === "agent" || value === "system"
    ? value
    : undefined;
}

function assistantActorType(actorType: string) {
  return actorType === "agent" || actorType === "system";
}

/**
 * A Router's message in a Task that hands it a request made elsewhere, such as in Home. The server marks it
 * (`metadata.task_request`) from the delivery that woke the Router.
 */
function routerRequest(message: SalixMessage, conversationKind: CommaConversationKind) {
  return (
    messageActorRole(message, conversationKind) === "router" &&
    message.metadata?.task_request === true
  );
}

function messageActorRole(
  message: SalixMessage,
  conversationKind: CommaConversationKind
): ChatMessage["actorRole"] {
  if (conversationKind !== "agent_task") {
    return undefined;
  }
  if (message.actor_type !== "agent") {
    return undefined;
  }
  return message.role_label === "delegator" ? "router" : "worker";
}

function deriveBlockViews(
  blocks: SalixContentBlock[] | undefined,
  sourceAgentId?: string,
  conversationId = "",
  messageId = ""
) {
  if (!blocks || blocks.length === 0) {
    return {
      attachments: [] as ChatAttachment[],
      blocksKey: undefined,
      parts: [] as ChatMessagePart[],
      refs: [] as ChatConversationRef[],
    };
  }

  const refs: ChatConversationRef[] = [];
  const attachments: ChatAttachment[] = [];
  const parts: ChatMessagePart[] = [];
  // The plain-text version of a question card, for clients that cannot draw the card: shown only when the card
  // cannot be read.
  const questionFallbacks: ChatMessagePart[] = [];
  let asksQuestion = false;

  for (const [blockIndex, rawBlock] of blocks.entries()) {
    const block = objectValue(rawBlock);
    if (!block) {
      continue;
    }

    const type = stringValue(block.type);
    if (type === "text") {
      const text = rawTextValue(block.text);
      if (text !== undefined) {
        (block.fallback_for === "question" ? questionFallbacks : parts).push({
          kind: "markdown",
          text,
        });
      }
      continue;
    }

    if (type === "question") {
      // Only an agent asks.
      const question = sourceAgentId
        ? questionPartValue(rawBlock, messageId)
        : undefined;
      if (question) {
        parts.push(question);
        asksQuestion = true;
      }
      continue;
    }

    if (type === "question_answer") {
      // Only a person answers.
      const answer = sourceAgentId ? undefined : questionAnswerPartValue(rawBlock);
      if (answer) parts.push(answer);
      continue;
    }

    if (type === "dynamic_ui") {
      const blobRef = salixBlobRefValue(block.blob_ref);
      if (!sourceAgentId || !blobRef) {
        parts.push({
          kind: "markdown",
          text:
            stringValue(block.summary) ?? stringValue(block.text) ?? "UI unavailable",
        });
        continue;
      }
      parts.push({
        kind: "dynamic-ui",
        contentId: blobRef.uuid,
        uiRef: stringValue(block.ui_ref) ?? "unavailable",
        summary: (
          stringValue(block.summary) ??
          stringValue(block.text) ??
          "UI unavailable"
        ).slice(0, 4000),
        originTaskId: stringValue(block.origin_task_id),
        version: numberValue(block.version) ?? 0,
        conversationId,
        messageId,
        attachmentIndex: blockIndex,
      });
      continue;
    }

    if (type === "conversation_ref") {
      const inlinePart = decodeInlineMessagePart(rawBlock);
      if (inlinePart) {
        parts.push(inlinePart);
        continue;
      }
      const referencedConversationId = stringValue(block.conversation_id);
      if (referencedConversationId) {
        refs.push({
          activityStatus: stringValue(block.activity_status),
          conversationId: referencedConversationId,
          kind: conversationKindValue(block.kind),
          status: stringValue(block.status),
          title: stringValue(block.title),
        });
      }
      continue;
    }

    if (type === "file" || type === "image") {
      const blobRef = salixBlobRefValue(block.blob_ref);
      const downloadFileName = downloadableAttachmentFileName(block, sourceAgentId);
      attachments.push({
        agentId: blobRef ? sourceAgentId : undefined,
        attachmentIndex: downloadFileName !== undefined ? blockIndex : undefined,
        blockType: type,
        blobRef,
        fileName: downloadFileName ?? stringValue(block.file_name),
        height: pixelValue(block.height),
        mimeType: stringValue(block.mime_type),
        size: numberValue(block.size),
        title: stringValue(block.title),
        width: pixelValue(block.width),
        workspacePath: vfsPathValue(block),
      });
      continue;
    }

    if (type === DEVICE_SETUP_OFFER) {
      // Only an agent's message offers a setup.
      const offer = sourceAgentId ? decodeInlineMessagePart(rawBlock) : undefined;
      if (offer) parts.push(offer);
      continue;
    }

    if (type === "local_file") {
      const mediaType = stringValue(block.media_type);
      attachments.push({
        blockType: localFileAttachmentBlockType(mediaType),
        fileName: stringValue(block.display_name),
        localFileRef: localFileRefValue(block.local_file_ref),
        mimeType: mediaType,
        size: numberValue(block.size),
        title: undefined,
      });
      continue;
    }

    const fallbackText = rawTextValue(block.text);
    if (fallbackText !== undefined) {
      parts.push({
        kind: "markdown",
        text: fallbackText,
      });
    }
  }

  return {
    attachments,
    blocksKey: JSON.stringify(blocks),
    parts: asksQuestion ? parts : [...parts, ...questionFallbacks],
    refs,
  };
}

/** A pixel count a block declares, within what an image can be. */
function pixelValue(value: unknown): number | undefined {
  const pixels = numberValue(value);
  return pixels !== undefined &&
    Number.isSafeInteger(pixels) &&
    pixels >= 1 &&
    pixels <= 100_000
    ? pixels
    : undefined;
}

function conversationKindValue(value: unknown): CommaConversationKind | undefined {
  return value === "user_chat" || value === "agent_task" ? value : undefined;
}

function combineMessages(
  serverMessages: ChatMessage[],
  pending: PendingSend[],
  resolvedMessageIds: readonly string[]
) {
  if (pending.length === 0) {
    return serverMessages;
  }

  return [
    ...serverMessages,
    ...pending.map<ChatMessage>((item, index) => ({
      clientRequestId: item.clientRequestId,
      attachments: [
        ...(item.uploads?.map<ChatAttachment>((upload) => ({
          // An image shows as one still loading until it uploaded; one that failed shows as its file.
          blockType: upload.isImage && upload.status !== "failed" ? "image" : "file",
          fileName: upload.name,
          mimeType: undefined,
          size: upload.size,
          title: undefined,
          ...(upload.status === "uploading" ? { uploadingId: upload.id } : {}),
          ...(upload.path ? { workspacePath: upload.path } : {}),
        })) ?? []),
        ...(item.localFiles?.map<ChatAttachment>((file) => ({
          blockType: localFileAttachmentBlockType(file.mediaType),
          fileName: file.displayName,
          localFileRef: file.localFileRef,
          mimeType: file.mediaType,
          size: file.size,
          title: undefined,
        })) ?? []),
      ],
      blocksKey: undefined,
      createdAt: item.createdAt,
      createdBy: undefined,
      delivery: item.status === "failed" ? "failed" : "sending",
      error: item.error,
      failureAction: item.failureAction,
      messageId: resolvedMessageIds[index]!,
      display: decodeUserMessage(item.text),
      parts: item.questionAnswer
        ? [
            ...userParts(decodeUserMessage(item.text)),
            { kind: "question-answer" as const, ...item.questionAnswer },
          ]
        : userParts(decodeUserMessage(item.text)),
      refs: [],
      ...(item.replyToMessageId ? { replyToMessageId: item.replyToMessageId } : {}),
      role: "user",
      source: "pending",
      status: item.status,
      text: item.text,
    })),
  ];
}

/** The `messageType` of a person's words said to Quick Chat, which Home shows over the Task they started. */
export const QUICK_CHAT_MESSAGE_TYPE = "quick_chat";

/** Whether a message announces the Tasks in its parts: any message not from a person, and a person's Quick Chat. */
export function announcesTasks(
  message: Pick<ChatMessage, "role" | "messageType">
): boolean {
  return message.role !== "user" || message.messageType === QUICK_CHAT_MESSAGE_TYPE;
}

/**
 * Whether a message is a request to the Router: a person's message, their Quick Chat included. The server delivers
 * a Quick Chat to the Router as it does typed words; the Router may reply or end its turn (its status frames settle
 * the thinking line either way), so the chat awaits it as any request.
 */
export function asksRouter(message: Pick<ChatMessage, "role">): boolean {
  return message.role === "user";
}

/**
 * What the core reads from a committed message's parts and sends with it: the Tasks a message announces
 * (`createdTasks`, see `announcesTasks`) and an assistant's parsed Markdown (`markdown`). A fixture that builds
 * messages by hand reads them with this, as the core does.
 */
export function messageReading(
  message: Pick<ChatMessage, "parts" | "refs" | "role" | "messageType">
): Pick<ChatMessage, "createdTasks" | "markdown"> {
  const parts = message.parts ?? [];
  return {
    // A person's Quick Chat always says which Tasks it announces, none included
    // (its Task can be unavailable): a kept copy with the field is known read.
    ...(announcesTasks(message)
      ? {
          ...(message.role === "user" ? { createdTasks: [] } : {}),
          ...createdTasksOf(parts, message.refs),
        }
      : {}),
    ...(message.role === "assistant"
      ? { markdown: messageMarkdown(parts) as ChatMessage["markdown"] }
      : {}),
  };
}

/** The Tasks a message announces (`ChatMessage.createdTasks`); none, no field. */
export function createdTasksOf(
  parts: readonly ChatMessagePart[],
  refs: ChatMessage["refs"]
): Pick<ChatMessage, "createdTasks"> {
  const seen = new Set<string>();
  const created: NonNullable<ChatMessage["createdTasks"]> = [];
  for (const part of parts) {
    if (part.kind !== "inline-task") continue;
    const id = part.task.conversationId;
    if (!id || part.task.unavailable || seen.has(id)) continue;
    seen.add(id);
    created.push({
      conversationId: id,
      ...(part.task.title === undefined ? {} : { title: part.task.title }),
      ...(part.task.updatedAt === undefined ? {} : { updatedAt: part.task.updatedAt }),
    });
  }
  for (const ref of refs) {
    if (ref.kind !== "agent_task" || seen.has(ref.conversationId)) continue;
    seen.add(ref.conversationId);
    created.push({
      conversationId: ref.conversationId,
      ...(ref.title === undefined ? {} : { title: ref.title }),
    });
  }
  return created.length === 0 ? {} : { createdTasks: created };
}

/**
 * Whether an agent's message is worth a notification (`ChatMessage.notice`): the Router speaking, in Home chat (where
 * no role is stamped) or a Task, in its own words. A worker's step, a system notice or another platform's message is
 * not.
 */
function noticeOf(
  role: string,
  platformMessage: unknown,
  actorType: ChatMessage["actorType"],
  actorRole: ChatMessage["actorRole"],
  conversationKind: CommaConversationKind,
  text: string,
  attached: boolean
): Pick<ChatMessage, "notice"> {
  if (role !== "assistant" || platformMessage || actorType === "system") return {};
  const router =
    actorRole === "router" ||
    (actorRole === undefined && conversationKind === "user_chat");
  const preview = previewText(text);
  // Files alone are worth a notice too; the preview is then empty.
  return router && (preview || attached) ? { notice: { preview } } : {};
}

/** Keeps a notification's payload small; it sits far past what a banner shows, which fades the rest itself. */
const NOTICE_PREVIEW_MAX = 500;
const LINE_MARKS = /^(#{1,6}\s+|>\s*|[-*+]\s+|\d+[.)]\s+)+/;
const INLINE_MARKS = /\*\*|__|`|~~/g;
const LINK = /!?\[([^\]]*)\]\([^)]*\)/g;

/**
 * Text as plain words for a notification: Markdown marks and code fences dropped, its paragraphs kept for the banner
 * to lay out, bounded without an ellipsis of its own.
 */
export function previewText(text: string): string {
  return text
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => !line.startsWith("```"))
    .map((line) =>
      line
        .replace(LINE_MARKS, "")
        .replace(INLINE_MARKS, "")
        .replace(LINK, "$1")
        .replace(/[ \t]+/g, " ")
    )
    .join("\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim()
    .slice(0, NOTICE_PREVIEW_MAX);
}

/** A person's message as parts: the words shown, task mentions as chips, a model mention as `@name`. */
function userParts(display: UserMessageDisplay): ChatMessagePart[] {
  const shown = display.command
    ? `/${display.command}`
    : modelMentionsAsWords(display.body);
  return splitUserTaskMentionParts(shown) ?? [{ kind: "markdown", text: shown }];
}

const BRIEF_TYPES = new Set(["task_command", "meeting_recording"]);

function isBrief(
  messageType: string | undefined,
  clientRequestId: string | undefined,
  conversationId: string
) {
  return (
    (messageType !== undefined && BRIEF_TYPES.has(messageType)) ||
    (conversationId !== "" && clientRequestId === `delegate-task-${conversationId}`)
  );
}

function localFileAttachmentBlockType(mediaType: string | undefined) {
  const normalized = mediaType?.trim().toLowerCase();
  return normalized === "image/jpeg" ||
    normalized === "image/jpg" ||
    normalized === "image/png" ||
    normalized === "image/gif" ||
    normalized === "image/webp"
    ? ("image" as const)
    : ("file" as const);
}

function localFileRefValue(value: unknown) {
  const ref = stringValue(value);
  return ref && /^lfi1_[A-Za-z0-9_-]{43}$/.test(ref) ? ref : undefined;
}

function salixBlobRefValue(value: unknown): ChatAttachment["blobRef"] {
  const ref = objectValue(value);
  if (!ref) return undefined;
  const kind = stringValue(ref.kind);
  const uuid = stringValue(ref.uuid);
  const hash = stringValue(ref.hash);
  const size = numberValue(ref.size);
  if (
    kind !== "blob" ||
    !uuid ||
    !/^[0-9a-f]{32}$/.test(uuid) ||
    !hash ||
    !/^[0-9a-f]{64}$/.test(hash) ||
    size === undefined ||
    !Number.isSafeInteger(size) ||
    size < 0
  ) {
    return undefined;
  }
  return { hash, kind, size, uuid };
}

/**
 * Match ConversationAttachments.downloadable?/1 for canonical string filenames
 * and fetch's sender requirement.
 * This only suppresses known unusable actions; the attachment endpoint still
 * decides whether the caller can retrieve the bytes. Preview refs deliberately
 * keep their separate, stricter parsing contract above.
 */
function downloadableAttachmentFileName(
  block: Record<string, unknown>,
  sourceAgentId?: string
): string | undefined {
  const ref = objectValue(block.blob_ref);
  const size = numberValue(ref?.size);
  if (
    !sourceAgentId ||
    !stringValue(ref?.uuid) ||
    !stringValue(ref?.hash) ||
    size === undefined ||
    !Number.isInteger(size) ||
    size < 0 ||
    size > chatAttachmentDownloadMaxBytes
  ) {
    return undefined;
  }

  const explicit = attachmentBasename(stringValue(block.file_name));
  const source = attachmentBasename(vfsPathValue(block));
  // Match Salix's legacy convention using the complete source basename.
  // A terminal dot-token cannot distinguish a filename from a description.
  const legacyDescription =
    explicit &&
    source &&
    explicit !== source &&
    [" - ", " – ", " — "].some((separator) => {
      const prefix = source + separator;
      return explicit.startsWith(prefix) && explicit.slice(prefix.length).trim() !== "";
    });
  const fileName = (legacyDescription ? source : explicit) ?? source ?? "attachment";
  return new TextEncoder().encode(fileName).byteLength <=
    chatAttachmentDownloadMaxFileNameBytes
    ? fileName
    : undefined;
}

const attachmentBasename = (path: string | undefined) => {
  const name = path?.trim().replace(/\/+$/, "").split("/").at(-1);
  return name && ![".", ".."].includes(name) ? name : undefined;
};

function vfsPathValue(block: Record<string, unknown>) {
  // Images bind file_ref first. A file block requires its top-level path.
  if (block.type === "image") {
    const fileRef = objectValue(block.file_ref);
    if (fileRef?.environment_id === "vfs" && typeof fileRef.path === "string") {
      return fileRef.path.trim();
    }
  }
  return stringValue(block.path)?.trim();
}

function reconcilePending(pending: PendingSend[], serverMessages: ChatMessage[]) {
  const seenClientRequestIds = new Set(
    serverMessages.flatMap((message) => {
      const ids = message.clientRequestId ? [message.clientRequestId] : [];
      if (message.role === "user") {
        ids.push(message.messageId);
      }
      return ids;
    })
  );
  return pending.filter((item) => !seenClientRequestIds.has(item.clientRequestId));
}

function replacePending(pending: PendingSend[], next: PendingSend) {
  const found = pending.some((item) => item.clientRequestId === next.clientRequestId);
  if (!found) {
    return [...pending, next];
  }

  return pending.map((item) =>
    item.clientRequestId === next.clientRequestId ? next : item
  );
}

/** The message's text with its uploaded files listed. */
function composeUploadedMessage(text: string, uploads: readonly DraftAttachment[]) {
  return composeMessageWithAttachments(
    text,
    uploads.map((attachment) => ({ name: attachment.name, path: attachment.path! }))
  );
}

function replaceAttachment(attachments: DraftAttachment[], next: DraftAttachment) {
  return attachments.map((attachment) =>
    attachment.id === next.id ? next : attachment
  );
}

function setBoundedObservation(
  observations: Map<string, number>,
  id: string,
  sequence: number
) {
  observations.delete(id);
  observations.set(id, sequence);
  while (observations.size > PRESENTATION_INDEX_LIMIT) {
    const oldest = observations.keys().next().value;
    if (oldest === undefined) {
      break;
    }
    observations.delete(oldest);
  }
}

function setBoundedValue<T>(values: Map<string, T>, id: string, value: T) {
  values.delete(id);
  values.set(id, value);
  while (values.size > PRESENTATION_INDEX_LIMIT) {
    const oldest = values.keys().next().value;
    if (oldest === undefined) {
      break;
    }
    values.delete(oldest);
  }
}

function addBoundedSet(values: Set<string>, value: string, limit: number) {
  values.delete(value);
  values.add(value);
  while (values.size > limit) {
    const oldest = values.values().next().value;
    if (oldest === undefined) break;
    values.delete(oldest);
  }
}

function validateAttachment(
  file: AttachmentUploadInput,
  projectedCount: number,
  locale: CommaLocale,
  transcodesImages: boolean
) {
  if (projectedCount >= MAX_ATTACHMENTS_PER_MESSAGE) {
    return commaMessages.chat_too_many_attachments({}, { locale });
  }

  if (file.size > MAX_ATTACHMENT_BYTES) {
    return commaMessages.chat_attachment_too_large({}, { locale });
  }

  if (
    !isAllowedAttachment(file.name) &&
    !(transcodesImages && isTranscodedImageAttachment(file.name))
  ) {
    return commaMessages.chat_unsupported_attachment({}, { locale });
  }

  return undefined;
}

/** The request a reply is owed to: the last message, when it asks the Router. */
function awaitedRequest(serverMessages: readonly ChatMessage[]) {
  const last = serverMessages.at(-1);
  return last && asksRouter(last) ? last : undefined;
}

function deriveAwaitingReply(
  conversation: CommaConversation | undefined,
  pending: PendingSend[],
  serverMessages: ChatMessage[]
) {
  if (conversation?.kind === "agent_task") {
    return false;
  }

  if (isTerminalStatus(conversation?.status)) {
    return false;
  }

  if (pending.some((item) => item.status !== "failed")) {
    return true;
  }

  const responsePending =
    awaitedRequest(serverMessages) !== undefined || conversation?.status === "waiting";
  if (!responsePending) {
    return false;
  }

  // A user-tail transcript only means that no visible provider reply was
  // appended. The Router may already have ended its runtime turn without
  // calling the explicit IM delivery tool, so use the canonical activity
  // snapshot to avoid presenting an idle session as "still thinking".
  if (isSettledActivityStatus(conversation?.activity_status)) {
    return false;
  }

  return true;
}

function isSettledActivityStatus(status: string | undefined) {
  return ["idle", "paused", "failed"].includes(status ?? "");
}

function isFailedActivity(activity: ChatActivity | undefined) {
  return activity?.status === "failed" || activity?.status === "error";
}

function activitySettlesCurrentTurn(
  activity: ChatActivity | undefined,
  serverMessages: readonly ChatMessage[]
) {
  if (!isFailedActivity(activity) || !isBoundChatActivity(activity)) {
    return false;
  }
  const currentUserMessage = serverMessages.findLast(asksRouter);
  return Boolean(
    currentUserMessage &&
    activity.sourceMessageIds.includes(currentUserMessage.messageId)
  );
}

function isBoundChatActivity(
  activity: ChatActivity | undefined
): activity is BoundChatActivity {
  return Boolean(
    activity?.ownerTurnKey &&
    activity.producerEpoch &&
    activity.responseKey &&
    activity.sequence !== undefined &&
    activity.sourceMessageIds?.length &&
    activity.summaryClass &&
    activity.streamIncarnation !== undefined
  );
}

function deriveAwaitingSince({
  awaitingReply,
  currentAwaitingReply,
  currentAwaitingSince,
  now,
}: {
  awaitingReply: boolean;
  currentAwaitingReply: boolean;
  currentAwaitingSince: number | undefined;
  now: number;
}) {
  if (!awaitingReply) {
    return undefined;
  }

  if (currentAwaitingReply && currentAwaitingSince !== undefined) {
    return currentAwaitingSince;
  }

  return now;
}

function isTerminalStatus(status: string | undefined) {
  return status === "cancelled" || status === "failed";
}

function classifyError(error: unknown): ConversationErrorKind {
  if (error instanceof CommaApiError) {
    if (error.status === 401) {
      return "unauthorized";
    }
    if (error.status === 403) {
      return "forbidden";
    }
    if (error.status === 404) {
      return "not-found";
    }
  }

  return "network";
}

function isAssistantDraftEvent(event: CommaConversationEvent, eventName: string) {
  return (
    eventName.startsWith("message_draft_") || event.type.startsWith("message_draft_")
  );
}

function isAssistantMessageCreated(event: CommaConversationEvent, eventName: string) {
  const raw = event as CommaConversationEvent & Record<string, unknown>;
  return (
    (eventName === "message_created" || event.type === "message_created") &&
    raw.role === "assistant"
  );
}

function isUserMessageCreated(event: CommaConversationEvent, eventName: string) {
  const raw = event as CommaConversationEvent & Record<string, unknown>;
  return (
    (eventName === "message_created" || event.type === "message_created") &&
    raw.role === "user"
  );
}

function exactOrderedStringArrayValue(value: unknown) {
  if (
    !Array.isArray(value) ||
    !value.every((item): item is string => typeof item === "string" && item.length > 0)
  ) {
    return [];
  }

  return [...value];
}

function nonNegativeIntegerValue(value: unknown) {
  return typeof value === "number" && Number.isInteger(value) && value >= 0
    ? value
    : undefined;
}

function positiveIntegerValue(value: unknown) {
  return typeof value === "number" && Number.isInteger(value) && value > 0
    ? value
    : undefined;
}

function activitySummaryClassValue(value: unknown): ActivitySummaryClass | undefined {
  return value === "none" || value === "generic" || value === "public"
    ? value
    : undefined;
}

function participantActivityStateValue(
  value: unknown
): ChatParticipantStatus["state"] | undefined {
  return value === "active" || value === "error" || value === "stopped"
    ? value
    : undefined;
}

function participantStatusValue(
  raw: Record<string, unknown> | null | undefined,
  expectedConversationId: string
): ChatParticipantStatus | undefined {
  if (!raw) return undefined;
  const conversationId = stringValue(raw.conversation_id);
  const participantId = stringValue(raw.participant_id);
  const state = participantActivityStateValue(raw.state);
  const status = typeof raw.status === "string" ? raw.status : undefined;
  const updatedAt = numberValue(raw.updated_at);
  if (
    conversationId !== expectedConversationId ||
    participantId === undefined ||
    state === undefined ||
    status === undefined ||
    updatedAt === undefined
  ) {
    return undefined;
  }
  return {
    conversationId,
    participantId,
    state,
    status,
    updatedAt,
    ...(stringValue(raw.issue) ? { issue: stringValue(raw.issue) } : {}),
    ...(state === "error" &&
    stringValue(raw.issue) &&
    participantIssueDetail(raw.issue_detail)
      ? { issueDetail: participantIssueDetail(raw.issue_detail) }
      : {}),
    ...(state === "active" &&
    (raw.working_provider === "wechat" ||
      raw.working_provider === "telegram" ||
      raw.working_provider === "signal")
      ? { workingProvider: raw.working_provider }
      : {}),
    ...(state === "active" && raw.loop_wake === true ? { loopWake: true } : {}),
    ...(state === "active" && workingConversationIds(raw.working_conversation_ids)
      ? { workingConversationIds: workingConversationIds(raw.working_conversation_ids) }
      : {}),
    ...(state === "active" && raw.waiting === true ? { waiting: true } : {}),
  };
}

/** A Task's place, model and its model's maker as the Task status stream sent them; none before a server sends them. */
export function taskRun(run: CommaTaskRun | undefined): ChatTaskRun | undefined {
  if (!run) return undefined;
  const place: ChatTaskRun["place"] =
    run.place.kind === "station"
      ? {
          kind: "station",
          deviceId: run.place.device_id,
          ...(run.place.name ? { name: run.place.name } : {}),
        }
      : { kind: run.place.kind };
  const model: ChatTaskRun["model"] = !run.model
    ? undefined
    : run.model.kind === "runtime"
      ? {
          kind: "runtime",
          ...(run.model.provider ? { provider: run.model.provider } : {}),
          ...(run.model.name ? { name: run.model.name } : {}),
        }
      : run.model.kind === "catalog"
        ? { kind: "catalog", name: run.model.name }
        : { kind: "platform" };
  const vendor =
    run.model?.kind === "platform" ? "comma" : run.model?.vendor || undefined;
  return { place, ...(model ? { model } : {}), ...(vendor ? { vendor } : {}) };
}

export function participantIssueDetail(
  value: unknown
): ChatParticipantIssueDetail | undefined {
  if (!value || typeof value !== "object") return undefined;
  const raw = value as Record<string, unknown>;
  const resetAt = numberValue(raw.reset_at);
  const detail: ChatParticipantIssueDetail = {
    ...(stringValue(raw.source) ? { source: stringValue(raw.source) } : {}),
    ...(stringValue(raw.profile_id) ? { profileId: stringValue(raw.profile_id) } : {}),
    ...(stringValue(raw.profile_name)
      ? { profileName: stringValue(raw.profile_name) }
      : {}),
    ...(resetAt !== undefined && resetAt > 0 ? { resetAt } : {}),
    ...(raw.trigger === "background" || raw.trigger === "voice_call"
      ? { trigger: raw.trigger }
      : {}),
  };
  return Object.keys(detail).length > 0 ? detail : undefined;
}

function workingConversationIds(value: unknown): string[] | undefined {
  if (!Array.isArray(value)) return undefined;
  const ids = [
    ...new Set(value.filter((id): id is string => typeof id === "string" && id !== "")),
  ];
  return ids.length > 0 ? ids : undefined;
}

function activityPayloadValue(
  raw: Record<string, unknown>,
  summaryClass: ActivitySummaryClass
):
  | {
      action: string | undefined;
      goal: string | undefined;
      phase: "execution" | "idle" | "messaging" | "thinking";
      status: "failed" | "idle" | "running";
      summary: string | undefined;
      toolName: string | undefined;
    }
  | undefined {
  const phase = stringValue(raw.phase);
  const status = stringValue(raw.status);

  if (summaryClass === "generic" && phase === "thinking" && status === "failed") {
    return {
      action: undefined,
      goal: undefined,
      phase,
      status,
      summary: undefined,
      toolName: undefined,
    };
  }

  if (
    summaryClass === "generic" &&
    status === "running" &&
    (phase === "thinking" || phase === "messaging")
  ) {
    const copy = phase === "thinking" ? "Thinking" : "Typing";
    return {
      action: copy,
      goal: undefined,
      phase,
      status,
      summary: copy,
      toolName: undefined,
    };
  }

  if (
    summaryClass === "public" &&
    ((phase === "thinking" && status === "running") ||
      (phase === "execution" && (status === "running" || status === "failed")))
  ) {
    const summary = publicActivityProseValue(raw.summary);
    const action = optionalPublicActivityProseValue(raw.action);
    const goal = optionalPublicActivityProseValue(raw.goal);
    const toolName = optionalPublicActivityProseValue(raw.tool_name);
    if (
      summary === undefined ||
      action === null ||
      goal === null ||
      toolName === null
    ) {
      return undefined;
    }
    return {
      action,
      goal,
      phase,
      status,
      summary,
      toolName,
    };
  }

  if (summaryClass === "none" && phase === "idle" && status === "idle") {
    return {
      action: undefined,
      goal: undefined,
      phase,
      status,
      summary: undefined,
      toolName: undefined,
    };
  }

  return undefined;
}

function publicActivityProseValue(value: unknown): string | undefined {
  return typeof value === "string" &&
    value.trim() !== "" &&
    Array.from(value).length <= PUBLIC_ACTIVITY_PROSE_MAX_CODEPOINTS
    ? value
    : undefined;
}

function optionalPublicActivityProseValue(value: unknown): string | null | undefined {
  if (value === undefined || value === null) return undefined;
  return publicActivityProseValue(value) ?? null;
}

function visibleReplyDraftFrameKind(
  raw: Record<string, unknown>
): "cancelled" | "completed" | "delta" | "started" | undefined {
  const suffix =
    typeof raw.type === "string" && raw.type.startsWith("message_draft_")
      ? raw.type.slice("message_draft_".length)
      : raw.status;

  return suffix === "started" ||
    suffix === "delta" ||
    suffix === "completed" ||
    suffix === "cancelled"
    ? suffix
    : undefined;
}

function sendErrorDetail(error: unknown, locale: CommaLocale) {
  if (error instanceof CommaApiError) {
    if (error.body?.error === "billing_unavailable") {
      switch (error.body.reason) {
        case "insufficient_credits":
          return commaMessages.chat_insufficient_credits({}, { locale });
        case "account_inactive":
          return commaMessages.chat_billing_account_inactive({}, { locale });
        case "missing_account":
          return commaMessages.chat_billing_account_missing({}, { locale });
        default:
          return commaMessages.chat_billing_unavailable({}, { locale });
      }
    }

    // API error codes are control-plane values, not user-facing prose. Unknown
    // codes deliberately fall back to the generic failed-send label in the UI.
    return undefined;
  }

  return error instanceof Error ? error.message : undefined;
}

function sendFailureAction(error: unknown): "billing" | undefined {
  return error instanceof CommaApiError &&
    error.body?.error === "billing_unavailable" &&
    error.body.reason === "insufficient_credits"
    ? "billing"
    : undefined;
}

function uploadErrorMessage(error: unknown, locale: CommaLocale) {
  if (error instanceof CommaApiError) {
    if (error.status === 404) {
      return commaMessages.chat_server_unsupported_attachment({}, { locale });
    }
    if (error.status === 413) {
      return commaMessages.chat_attachment_too_large({}, { locale });
    }
    if (error.status === 415) {
      return commaMessages.chat_unsupported_attachment({}, { locale });
    }
  }

  return error instanceof Error
    ? error.message
    : commaMessages.chat_upload_failed({}, { locale });
}

function stringValue(value: unknown) {
  return typeof value === "string" ? value : undefined;
}

// Message text is positional content: an empty or whitespace-only block can be
// the only separator between two inline elements and must not be normalized.
function rawTextValue(value: unknown) {
  return typeof value === "string" ? value : undefined;
}

function numberValue(value: unknown) {
  return typeof value === "number" ? value : undefined;
}

function objectValue(value: unknown) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return undefined;
  }

  return value as Record<string, unknown>;
}
