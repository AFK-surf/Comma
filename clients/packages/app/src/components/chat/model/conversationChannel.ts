import { baseLocale, messages as commaMessages, type CommaLocale } from "@comma/i18n";
import {
  chatAttachmentDownloadMaxBytes,
  chatAttachmentDownloadMaxFileNameBytes,
  type ChatMessage as ContractChatMessage,
  type ChatMessagePart,
} from "@comma/chat-contract";
import {
  CommaApiError,
  type CommaApiClient,
  type CommaLocalFileRef,
  type SalixContentBlock,
  type CommaConversation,
  type CommaConversationKind,
  type CommaConversationEvent,
  type SalixMessage,
} from "../../../api";
import {
  composeMessageWithAttachments,
  isAllowedAttachment,
  isCommaContextMessage,
  isImageAttachment,
  isTranscodedImageAttachment,
  isGroupImagePreviewPath,
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
import { decodeInlineMessagePart } from "./inlineElementContract";
import { splitUserTaskMentionParts } from "./mentionSerialization";

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
  file: AttachmentUploadInput,
  signal: AbortSignal
) => Promise<AttachmentUploadInput>;

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
};

export type ChatBoundWorker = {
  participantId: string;
  actorId?: string | undefined;
  name: string;
};

export type ChatParticipantStatus = {
  workingProvider?: "wechat" | "telegram" | "signal" | undefined;
  loopWake?: boolean | undefined;
  actorId?: string | undefined;
  actorRole?: "router" | "worker" | undefined;
  conversationId: string;
  issue?: string | undefined;
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
  status: PendingSendStatus;
  text: string;
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
  errorKind: ConversationErrorKind | undefined;
  lastBackoffMs: number;
  /** Local send feedback until exact-source runtime feedback, outcome, or timeout. */
  locallyAwaitingReply?: boolean | undefined;
  messages: ChatMessage[];
  pending: PendingSend[];
  participantStatus: ChatParticipantStatus | undefined;
  participantStatuses?: ChatParticipantStatus[] | undefined;
  boundWorker?: ChatBoundWorker | undefined;
  serverMessages: ChatMessage[];
  status: "idle" | "loading" | "ready" | "error";
  syncWarning: ChatSyncWarning | undefined;
};

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
 * as Side Chat's local Clear boundary.
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

export type ConversationChannelEnv = {
  clearTimeout: (handle: ReturnType<typeof setTimeout>) => void;
  createClientRequestId: (() => string) | undefined;
  jitterMs: (baseDelayMs: number) => number;
  now: () => number;
  setTimeout: (callback: () => void, delayMs: number) => ReturnType<typeof setTimeout>;
  transcodeAttachment: AttachmentTranscoder | undefined;
  visibility: ConversationVisibility | undefined;
};

export type ConversationChannelOptions = {
  api: CommaApiClient;
  getClientDeviceId?: () => string | undefined;
  conversationId: string;
  groupId: string;
  env?: Partial<ConversationChannelEnv>;
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
  ) => Promise<void> | void;
  workspaceId: string;
};

type Listener = () => void;

// Activity v2 admission is modeled in tla/salix/ActivityPresentation.tla;
// Participant draft replay in tla/salix/TransientDraftDelivery.tla; local
// send-to-runtime feedback handoff in tla/salix/LocalReplyFeedback.tla.
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
    | ((
        files: readonly CommaLocalFileRef[],
        committedAtMs: number | undefined
      ) => Promise<void> | void)
    | undefined;
  private readonly attachmentControllers = new Map<string, AbortController>();
  private readonly attachmentFiles = new Map<string, AttachmentUploadInput>();
  private readonly clientRequestFirstObservedSequences = new Map<string, number>();
  private readonly draftFirstObservedSequences = new Map<string, number>();
  private readonly listeners = new Set<Listener>();
  private readonly messageFirstObservedSequences = new Map<string, number>();
  private readonly canonicalMessageIdsByClientRequestId = new Map<string, string>();
  private readonly committedLocalFileRefs = new Set<string>();
  private readonly committingLocalFileRefs = new Set<string>();
  private abortController: AbortController | undefined;
  private active = false;
  private activityProducerEpoch: string | undefined;
  private activityProducerSequence: number | undefined;
  private activityRetiredProducerEpochs = new Set<string>();
  private activityCursorIncarnation: number | undefined;
  private activitySnapshotReadyIncarnation: number | undefined;
  private activityStreamIncarnation: number | undefined;
  private activityTimer: ReturnType<typeof setTimeout> | undefined;
  private epoch = 0;
  private activeStreamIncarnation: number | undefined;
  private nextStreamIncarnation = 0;
  private observationSequence = 0;
  private locallyAwaitedClientRequestId: string | undefined;
  private locallyAwaitedSince: number | undefined;
  private localReplyTimer: ReturnType<typeof setTimeout> | undefined;
  private visibleReplyPresentation: VisibleReplyPresentationState =
    idleVisibleReplyPresentationState;
  private pendingExplicitRefreshEpoch: number | undefined;
  private polling = false;
  private taskDetailRefreshNeeded = true;
  private taskEtag: string | undefined;
  private taskListVersion: string | undefined;
  private transportMode: "unknown" | "events" | "task-events";
  private releaseVisibility: (() => void) | undefined;
  private restartAfterCurrentStream = false;
  private retryTimer: ReturnType<typeof setTimeout> | undefined;
  private serverMessages: ChatMessage[] = [];
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
    this.releaseVisibility = this.env.visibility?.subscribe(() => {
      if (!this.active || !this.env.visibility?.isVisible()) {
        return;
      }
      this.pollSoon(0);
    });
    this.pollSoon(0);
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
    this.abortController?.abort();
    this.abortController = undefined;
    this.abortUploads();
    this.taskDetailRefreshNeeded = true;
    this.taskListVersion = undefined;
    this.pendingExplicitRefreshEpoch = undefined;
    this.clearLocalReplyWait();
    this.polling = false;
    this.clearActivityTimer();
    this.clearRetryTimer();
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
    });
  }

  async acceptTaskReview(reviewVersion: number) {
    if (!this.active) throw new Error("The chat session is no longer active.");
    const epoch = this.epoch;
    try {
      const conversation = await this.api.acceptTaskReview(
        this.groupId,
        this.conversationId,
        reviewVersion
      );
      if (!this.active || this.epoch !== epoch) return;
      // Cancel any detail read captured before the mutation, then publish the
      // canonical command result before fetching subsequent invalidations.
      this.taskEtag = undefined;
      this.taskDetailRefreshNeeded = true;
      if (this.polling) this.restartCurrentStream();
      else this.pollSoon(0);
      if (
        !this.state.conversation ||
        (conversation.updated_at ?? 0) >= (this.state.conversation.updated_at ?? 0)
      ) {
        this.applyConversation(conversation);
      }
    } catch (error) {
      if (this.active && this.epoch === epoch) this.refresh();
      throw error;
    }
  }

  refresh() {
    if (!this.active) {
      return;
    }

    if (this.transportMode === "task-events") {
      this.taskDetailRefreshNeeded = true;
    }

    if (this.polling) {
      this.pendingExplicitRefreshEpoch = this.epoch;
      if (this.transportMode === "task-events") this.restartCurrentStream();
      return;
    }

    this.pollSoon(0);
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

  attachFiles(files: AttachmentUploadInput[]) {
    if (files.length === 0) {
      return;
    }

    const nextAttachments: DraftAttachment[] = [];
    // The upload budget counts upload-class attachments only. Local refs have
    // their own 50-item budget, so a mixed selection admits identically
    // regardless of which class the dialog returned first.
    let projectedCount = this.state.draftAttachments.filter(
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

    this.setState({
      draftAttachments: [...this.state.draftAttachments, ...nextAttachments],
    });

    for (const attachment of nextAttachments) {
      if (attachment.status === "uploading") {
        void this.uploadAttachment(attachment.id);
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

  async previewLocalFile(
    previewRef: ChatImagePreviewRef,
    signal?: AbortSignal
  ): Promise<LocalFilePreview | undefined> {
    const source = agentBlobImagePreviewRefValue(previewRef);
    if (typeof previewRef !== "string" && !source) return undefined;
    if (typeof previewRef === "string" && !isGroupImagePreviewPath(previewRef)) {
      return undefined;
    }
    try {
      const blob = source
        ? await this.api.fetchAgentBlob(
            this.groupId,
            source.agentId,
            source.blobRef,
            signal ? { signal } : undefined
          )
        : await this.api.fetchGroupFile(
            this.groupId,
            previewRef as string,
            signal ? { signal } : undefined
          );
      const mediaType = source?.mediaType ?? blob.type;
      const fileName = source?.fileName ?? (previewRef as string);
      if (
        signal?.aborted ||
        blob.size === 0 ||
        blob.size > MAX_ATTACHMENT_BYTES ||
        !workspaceImageMediaTypeMatchesPath(mediaType, fileName)
      ) {
        return undefined;
      }
      const url = URL.createObjectURL(
        source ? new Blob([await blob.arrayBuffer()], { type: mediaType }) : blob
      );
      let released = false;
      return {
        release() {
          if (released) return;
          released = true;
          URL.revokeObjectURL(url);
        },
        url,
      };
    } catch {
      return undefined;
    }
  }

  removeAttachment(id: string) {
    this.attachmentControllers.get(id)?.abort();
    this.attachmentControllers.delete(id);
    this.attachmentFiles.delete(id);
    this.setState({
      draftAttachments: this.state.draftAttachments.filter(
        (attachment) => attachment.id !== id
      ),
    });
  }

  retryAttachment(id: string) {
    const file = this.attachmentFiles.get(id);
    if (!file) {
      return;
    }

    const existing = this.state.draftAttachments.find(
      (attachment) => attachment.id === id
    );
    if (!existing || existing.status !== "failed") {
      return;
    }

    // The retry re-validates against the upload-class count only — the same
    // per-class budget attachFiles admits under. Local refs must not consume
    // the image-upload allowance here either, or a retry could fail for a
    // selection that originally admitted.
    const validationError = validateAttachment(
      file,
      this.state.draftAttachments.filter(
        (attachment) => attachment.id !== id && attachment.localFile === undefined
      ).length,
      this.locale,
      this.env.transcodeAttachment !== undefined
    );
    if (validationError) {
      this.setState({
        draftAttachments: replaceAttachment(this.state.draftAttachments, {
          ...existing,
          error: validationError,
          status: "failed",
        }),
      });
      return;
    }

    this.setState({
      draftAttachments: replaceAttachment(this.state.draftAttachments, {
        ...existing,
        error: undefined,
        status: "uploading",
      }),
    });
    void this.uploadAttachment(id);
  }

  refreshDerivedState() {
    this.rebuildState({ emit: true });
  }

  async send(
    text: string,
    options: {
      consumeDraft?: boolean;
      skills?: { location: string }[];
      replyToMessageId?: string;
    } = {}
  ) {
    const consumeDraft = options.consumeDraft ?? true;
    const trimmed = text.trim();
    const hasBlockedAttachment =
      consumeDraft &&
      this.state.draftAttachments.some(
        (attachment) =>
          attachment.status === "uploading" || attachment.status === "failed"
      );
    const uploadedAttachments = consumeDraft
      ? this.state.draftAttachments.filter(
          (attachment) => attachment.status === "uploaded" && attachment.path
        )
      : [];
    const localFiles = consumeDraft
      ? this.state.draftAttachments.flatMap((attachment) =>
          attachment.status === "uploaded" && attachment.localFile
            ? [{ ...attachment.localFile }]
            : []
        )
      : [];
    if (
      hasBlockedAttachment ||
      (!trimmed && uploadedAttachments.length === 0 && localFiles.length === 0)
    ) {
      return this.state.conversation;
    }

    const sendText = composeMessageWithAttachments(
      text,
      uploadedAttachments.map((attachment) => ({
        name: attachment.name,
        path: attachment.path!,
      }))
    );
    const pending: PendingSend = {
      clientDeviceId: this.getClientDeviceId?.(),
      clientRequestId: this.createClientRequestId(),
      createdAt: this.env.now(),
      error: undefined,
      localFiles: localFiles.length > 0 ? localFiles : undefined,
      skills: options.skills?.length ? options.skills : undefined,
      replyToMessageId: options.replyToMessageId,
      status: "sending",
      text: sendText,
    };
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
        this.attachmentFiles.delete(attachment.id);
        this.attachmentControllers.delete(attachment.id);
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
    this.pollSoon(0);

    return this.sendPending(pending);
  }

  async retry(clientRequestId: string) {
    const pending = this.state.pending.find(
      (item) => item.clientRequestId === clientRequestId
    );
    if (!pending) {
      return this.state.conversation;
    }

    const retrying = {
      ...pending,
      error: undefined,
      failureAction: undefined,
      status: "sending" as const,
    };
    this.beginLocalReplyWait(retrying.clientRequestId);
    this.state = {
      ...this.state,
      pending: replacePending(this.state.pending, retrying),
    };
    this.rebuildState({ emit: true });
    this.pollSoon(0);

    return this.sendPending(retrying);
  }

  discard(clientRequestId: string) {
    if (this.locallyAwaitedClientRequestId === clientRequestId) {
      this.clearLocalReplyWait();
    }
    this.state = {
      ...this.state,
      pending: this.state.pending.filter(
        (pending) => pending.clientRequestId !== clientRequestId
      ),
    };
    this.rebuildState({ emit: true });
  }

  private async sendPending(pending: PendingSend) {
    try {
      const attrs: {
        clientRequestId: string;
        clientDeviceId?: string;
        localFiles?: CommaLocalFileRef[];
        skills?: { location: string }[];
        replyToMessageId?: string;
        text: string;
      } = {
        text: pending.text,
        clientRequestId: pending.clientRequestId,
      };
      if (pending.replyToMessageId) attrs.replyToMessageId = pending.replyToMessageId;
      if (pending.clientDeviceId) attrs.clientDeviceId = pending.clientDeviceId;
      if (pending.skills?.length) {
        attrs.skills = pending.skills;
      }
      if (pending.localFiles?.length) {
        attrs.localFiles = pending.localFiles;
      }

      const conversation = await this.api.sendMessage(
        this.groupId,
        this.conversationId,
        attrs
      );
      if (conversation.kind === "agent_task") {
        this.transportMode = "task-events";
        this.taskEtag = undefined;
        this.taskDetailRefreshNeeded = true;
      }
      this.applyConversation(conversation);
      if (conversation.kind === "agent_task") this.restartCurrentStream();
      else this.pollSoon(0);
      return conversation;
    } catch (error) {
      if (this.locallyAwaitedClientRequestId === pending.clientRequestId) {
        this.clearLocalReplyWait();
      }
      const failed = {
        ...pending,
        error: sendErrorDetail(error, this.locale),
        failureAction: sendFailureAction(error),
        status: "failed" as const,
      };
      this.state = {
        ...this.state,
        pending: replacePending(this.state.pending, failed),
      };
      this.rebuildState({ emit: true });
      throw error;
    }
  }

  private async uploadAttachment(id: string) {
    const file = this.attachmentFiles.get(id);
    const attachment = this.state.draftAttachments.find((item) => item.id === id);
    if (!file || !attachment || attachment.status !== "uploading") {
      return;
    }

    const controller = new AbortController();
    this.attachmentControllers.set(id, controller);
    let transcoding = false;

    try {
      let source = file;
      if (isTranscodedImageAttachment(file.name)) {
        const transcode = this.env.transcodeAttachment;
        if (!transcode) {
          throw new Error(
            commaMessages.chat_unsupported_attachment({}, { locale: this.locale })
          );
        }
        transcoding = true;
        source = await transcode(file, controller.signal);
        transcoding = false;
      }
      const uploaded = await this.api.uploadGroupFile(this.groupId, {
        data: source.data,
        name: source.name,
        signal: controller.signal,
      });

      if (!this.attachmentFiles.has(id)) {
        return;
      }

      this.attachmentControllers.delete(id);
      this.setState({
        draftAttachments: replaceAttachment(this.state.draftAttachments, {
          ...attachment,
          error: undefined,
          isImage: isImageAttachment(uploaded.name),
          name: uploaded.name,
          path: uploaded.path,
          size: uploaded.size,
          status: "uploaded",
        }),
      });
    } catch (error) {
      this.attachmentControllers.delete(id);
      if (controller.signal.aborted || !this.attachmentFiles.has(id)) {
        return;
      }

      this.setState({
        draftAttachments: replaceAttachment(this.state.draftAttachments, {
          ...attachment,
          // A decoder failure is not an upload outcome the server named; the
          // user retries or removes the file either way.
          error: transcoding
            ? commaMessages.chat_upload_failed({}, { locale: this.locale })
            : uploadErrorMessage(error, this.locale),
          status: "failed",
        }),
      });
    }
  }

  private pollSoon(delayMs: number) {
    if (!this.active) {
      return;
    }

    this.clearRetryTimer();

    if (delayMs === 0) {
      void this.poll();
      return;
    }

    this.retryTimer = this.env.setTimeout(() => {
      this.retryTimer = undefined;
      void this.poll();
    }, delayMs);
  }

  private async poll() {
    if (!this.active || this.polling) {
      return;
    }

    if (!this.env.visibility?.isVisible()) {
      this.setState({ connection: "paused" });
      return;
    }

    this.polling = true;
    const pollEpoch = this.epoch;
    const controller = new AbortController();
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

    try {
      if (this.transportMode !== "events") {
        const taskHandled =
          this.transportMode === "task-events" && !this.taskDetailRefreshNeeded
            ? true
            : await this.pollDetail(controller, pollEpoch);

        if (taskHandled) {
          if (controller.signal.aborted) return;
          await this.streamTaskInvalidations(controller, pollEpoch);

          if (this.active && pollEpoch === this.epoch && !controller.signal.aborted) {
            this.setState({
              connection: "live",
              errorKind: undefined,
              lastBackoffMs: 0,
              status: "ready",
            });
            this.restartAfterCurrentStream = true;
          }
          return;
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
        signal: controller.signal,
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

      await this.api.streamConversationEvents(
        this.groupId,
        this.conversationId,
        streamOpts
      );

      if (
        !this.active ||
        pollEpoch !== this.epoch ||
        this.activeStreamIncarnation !== currentStreamIncarnation
      ) {
        return;
      }

      this.setState({
        connection: "live",
        lastBackoffMs: 0,
        status: "ready",
        syncWarning:
          this.state.syncWarning === "suspect-empty" ? "suspect-empty" : undefined,
      });
      this.scheduleNextStream();
    } catch (error) {
      if (!this.active || pollEpoch !== this.epoch || controller.signal.aborted) {
        return;
      }
      this.handlePollError(error);
    } finally {
      if (
        streamIncarnation !== undefined &&
        this.activeStreamIncarnation === streamIncarnation
      ) {
        this.activeStreamIncarnation = undefined;
      }
      if (this.abortController === controller) {
        this.abortController = undefined;
      }
      this.polling = false;

      const shouldDrainExplicitRefresh =
        this.active &&
        pollEpoch === this.epoch &&
        this.pendingExplicitRefreshEpoch === pollEpoch;
      const shouldRestartStream =
        this.active && pollEpoch === this.epoch && this.restartAfterCurrentStream;

      if (shouldDrainExplicitRefresh) {
        this.pendingExplicitRefreshEpoch = undefined;
        if (this.transportMode === "task-events") {
          this.taskDetailRefreshNeeded = true;
        }
      }
      if (shouldRestartStream) {
        this.restartAfterCurrentStream = false;
      }
      if (shouldDrainExplicitRefresh || shouldRestartStream) {
        this.pollSoon(0);
      }
    }
  }

  private async pollDetail(controller: AbortController, pollEpoch: number) {
    const result = await this.api.pollConversation(this.groupId, this.conversationId, {
      ...(this.taskEtag ? { etag: this.taskEtag } : {}),
      signal: controller.signal,
    });

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
  }

  private async streamTaskInvalidations(
    controller: AbortController,
    pollEpoch: number
  ) {
    // Keep the last reliable snapshot through finite-wait EOF and reconnect.
    // Only this incarnation can replace it; stop/auth loss clears the scope.
    // See tla/salix/TaskParticipantStatus.tla.
    await this.api.streamConversationListEvents(this.groupId, {
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
          })),
        });
      },
      signal: controller.signal,
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

    // Validate summary authority before accepting the producer cursor. The
    // invalid-high/valid-lower ordering is modeled in
    // tla/salix/ActivitySummaryAuthority.tla.
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
    // See tla/salix/LocalReplyFeedback.tla.
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
    this.activityTimer = this.env.setTimeout(() => {
      this.activityTimer = undefined;
      this.clearActivity();
    }, ACTIVITY_TTL_MS);
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
    if (!suspiciousEmpty) this.hasObservedCanonicalSnapshot = true;

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
      status: "ready",
      syncWarning: suspiciousEmpty ? "suspect-empty" : undefined,
    };
    this.rebuildState({ emit: opts.emit !== false });
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
        void Promise.resolve(
          this.onLocalFilesCommitted(files, canonicalMessageCreatedAtMs(message))
        ).then(
          () => settle(true),
          () => settle(false)
        );
      } catch {
        settle(false);
      }
    }
  }

  private scheduleNextStream() {
    const hot =
      (this.state.awaitingReply && !this.state.awaitingTimedOut) ||
      this.state.pending.some((pending) => pending.status === "sending");
    this.pollSoon(hot ? HOT_STREAM_RECONNECT_MS : WARM_STREAM_RECONNECT_MS);
  }

  private handlePollError(error: unknown) {
    const errorKind = classifyError(error);

    if (errorKind !== "network") {
      this.active = false;
      this.clearRetryTimer();
      this.setState({
        connection: "paused",
        errorKind,
        participantStatuses: undefined,
        boundWorker: undefined,
        status: "error",
      });
      return;
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
    this.pollSoon(nextBackoffMs + this.env.jitterMs(nextBackoffMs));
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

    const messages = this.combineMessagesCached();
    const awaitingTurnKey = awaitingReply
      ? (this.locallyAwaitedClientRequestId ??
        this.state.pending.findLast((item) => item.status === "sending")
          ?.clientRequestId ??
        (this.serverMessages.at(-1)?.role === "user"
          ? conversationMessageTurnKey(this.serverMessages.at(-1)!)
          : undefined))
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
      serverMessages: this.serverMessages,
    };

    if (emit) {
      this.emit();
    }
  }

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
    for (const listener of this.listeners) {
      listener();
    }
  }

  private clearRetryTimer() {
    if (this.retryTimer) {
      this.env.clearTimeout(this.retryTimer);
      this.retryTimer = undefined;
    }
  }

  private restartCurrentStream() {
    this.restartAfterCurrentStream = true;
    // Fence callbacks before aborting: the stream parser may still drain an
    // already-buffered SSE frame while the fetch cancellation is settling.
    this.activeStreamIncarnation = undefined;
    this.abortController?.abort();
  }

  private abortUploads() {
    for (const controller of this.attachmentControllers.values()) {
      controller.abort();
    }
    this.attachmentControllers.clear();
  }

  private clearActivity() {
    this.clearActivityTimer();

    if (this.state.activity !== undefined) {
      this.setState({ activity: undefined });
    }
  }

  private clearActivityTimer() {
    if (this.activityTimer) {
      this.env.clearTimeout(this.activityTimer);
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
      messages
        .slice(userIndex + 1)
        .some((message) => message.role === "assistant" && !message.platformSource)
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
    this.localReplyTimer = this.env.setTimeout(() => {
      this.localReplyTimer = undefined;
      this.rebuildState({ emit: true });
    }, AWAITING_TIMEOUT_MS);
  }

  private clearLocalReplyWait() {
    this.locallyAwaitedClientRequestId = undefined;
    this.locallyAwaitedSince = undefined;
    if (this.localReplyTimer !== undefined) {
      this.env.clearTimeout(this.localReplyTimer);
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
    if (this.env.createClientRequestId) {
      return this.env.createClientRequestId();
    }

    if (globalThis.crypto?.randomUUID) {
      return globalThis.crypto.randomUUID();
    }

    return `req-${this.env.now()}-${Math.random().toString(16).slice(2)}`;
  }
}

function workspaceImageMediaTypeMatchesPath(mediaType: string, path: string) {
  const normalizedType = mediaType.trim().toLowerCase();
  const normalizedPath = path.toLowerCase();
  if (normalizedPath.endsWith(".png")) return normalizedType === "image/png";
  if (normalizedPath.endsWith(".gif")) return normalizedType === "image/gif";
  if (normalizedPath.endsWith(".webp")) return normalizedType === "image/webp";
  return normalizedType === "image/jpeg";
}

export function toConversationProjection(
  state: ConversationChannelState,
  context: { groupId: string; workspaceId: string }
): import("@comma/chat-contract").ConversationProjection {
  const conversation = state.conversation;
  const activity = isBoundChatActivity(state.activity) ? state.activity : undefined;
  return {
    ...(activity ? { activity } : {}),
    ...(state.assistantDraft ? { assistantDraft: state.assistantDraft } : {}),
    awaitingReply: state.awaitingReply,
    ...(state.awaitingSince === undefined
      ? {}
      : { awaitingSince: state.awaitingSince }),
    awaitingTimedOut: state.awaitingTimedOut,
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
            ...(conversation.schedule === undefined
              ? {}
              : { schedule: conversation.schedule }),
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
    ...(state.errorKind ? { errorKind: state.errorKind } : {}),
    lastBackoffMs: state.lastBackoffMs,
    messages: state.messages,
    pending: state.pending,
    ...(state.participantStatus
      ? { participantStatus: { ...state.participantStatus } }
      : {}),
    ...(state.boundWorker ? { boundWorker: state.boundWorker } : {}),
    ...(state.participantStatuses
      ? { participantStatuses: state.participantStatuses }
      : {}),
    serverMessages: state.serverMessages,
    status: state.status,
    ...(state.syncWarning ? { syncWarning: state.syncWarning } : {}),
  };
}

function normalizeEnv(
  env: Partial<ConversationChannelEnv> = {}
): ConversationChannelEnv {
  return {
    clearTimeout:
      env.clearTimeout ??
      ((handle) => {
        clearTimeout(handle);
      }),
    createClientRequestId: env.createClientRequestId,
    jitterMs: env.jitterMs ?? (() => Math.floor(Math.random() * 250)),
    now: env.now ?? (() => Date.now()),
    setTimeout:
      env.setTimeout ?? ((callback, delayMs) => setTimeout(callback, delayMs)),
    transcodeAttachment: env.transcodeAttachment,
    visibility: env.visibility ?? defaultVisibility(),
  };
}

function defaultVisibility(): ConversationVisibility {
  if (typeof document === "undefined") {
    return {
      isVisible: () => true,
      subscribe: () => () => {},
    };
  }

  return {
    isVisible: () => document.visibilityState !== "hidden",
    subscribe(listener) {
      document.addEventListener("visibilitychange", listener);
      return () => document.removeEventListener("visibilitychange", listener);
    },
  };
}

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
          [
            "provider.output",
            "provider.status",
            "provider.message",
            "message.redelivery",
          ].includes(String(message.metadata?.event_type ?? ""))))
    ) {
      return [];
    }
    const content = platformMessage?.content ?? message.content;
    const text = contentBlocksToText(content);
    if (!platformMessage && isCommaContextMessage(text)) {
      return [];
    }

    const blockViews = deriveBlockViews(
      content,
      message.actor_type === "agent" ? message.agent_id : undefined,
      conversationId,
      message.message_id
    );
    const strippedText = platformMessage ? text : stripCommaProtocolMarkers(text);
    const role =
      platformMessage?.role ??
      (assistantActorType(message.actor_type) ? "assistant" : "user");
    const parts = blockViews.parts.some((part) => part.kind !== "markdown")
      ? blockViews.parts
      : ((role === "user" && !platformMessage
          ? splitUserTaskMentionParts(strippedText)
          : undefined) ?? [{ kind: "markdown" as const, text: strippedText }]);
    const next: ChatMessage = {
      actorId: message.actor_type === "agent" ? message.agent_id : undefined,
      actorRole: messageActorRole(message, conversationKind),
      attachments: blockViews.attachments,
      blocksKey: blockViews.blocksKey,
      clientRequestId: message.client_request_id,
      createdAt: message.created_at,
      createdBy: message.user_id,
      delivery: "sent",
      error: undefined,
      messageId: message.message_id,
      replyToMessageId: message.reply_to_message_id,
      threadRootMessageId: message.thread_root_message_id,
      parts,
      refs: blockViews.refs,
      role,
      platformSource: platformMessage?.provider,
      source: "server",
      status: "committed",
      text: strippedText,
    };
    const current = previousById.get(next.messageId);
    return current && sameMessage(current, next) ? [current] : [next];
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

  if (
    normalized.length === previous.length &&
    normalized.every((message, index) => message === previous[index])
  ) {
    return previous;
  }

  return normalized;
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
    a.source === b.source &&
    a.status === b.status &&
    a.text === b.text
  );
}

function contentBlocksToText(content: SalixContentBlock[]): string {
  return content
    .flatMap((block) => {
      const text = rawTextValue(block.text);
      return text === undefined ? [] : [text];
    })
    .join("\n");
}

function assistantActorType(actorType: string) {
  return actorType === "agent" || actorType === "system";
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

  for (const [blockIndex, rawBlock] of blocks.entries()) {
    const block = objectValue(rawBlock);
    if (!block) {
      continue;
    }

    const type = stringValue(block.type);
    if (type === "text") {
      const text = rawTextValue(block.text);
      if (text !== undefined) {
        parts.push({
          kind: "markdown",
          text,
        });
      }
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
          conversationId: referencedConversationId,
          kind: conversationKindValue(block.kind),
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
        mimeType: stringValue(block.mime_type),
        size: numberValue(block.size),
        title: stringValue(block.title),
        workspacePath: vfsPathValue(block),
      });
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
    parts,
    refs,
  };
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
      attachments:
        item.localFiles?.map((file) => ({
          blockType: localFileAttachmentBlockType(file.mediaType),
          fileName: file.displayName,
          localFileRef: file.localFileRef,
          mimeType: file.mediaType,
          size: file.size,
          title: undefined,
        })) ?? [],
      blocksKey: undefined,
      createdAt: item.createdAt,
      createdBy: undefined,
      delivery: item.status === "failed" ? "failed" : "sending",
      error: item.error,
      failureAction: item.failureAction,
      messageId: resolvedMessageIds[index]!,
      parts: splitUserTaskMentionParts(item.text) ?? [
        { kind: "markdown", text: item.text },
      ],
      refs: [],
      role: "user",
      source: "pending",
      status: item.status,
      text: item.text,
    })),
  ];
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

  const candidate = [
    stringValue(block.file_name),
    stringValue(block.title),
    attachmentBasename(stringValue(block.path) ?? ""),
  ]
    .map((value) => value?.trim())
    .find((value) => value && ![".", "..", "/"].includes(value));
  const fileName = attachmentBasename(candidate ?? "attachment");
  return new TextEncoder().encode(fileName).byteLength <=
    chatAttachmentDownloadMaxFileNameBytes
    ? fileName
    : undefined;
}

const attachmentBasename = (path: string) =>
  path.replace(/\/+$/, "").split("/").at(-1) ?? "";

function vfsPathValue(block: Record<string, unknown>) {
  const directPath = stringValue(block.path);
  if (directPath) return directPath;
  const fileRef = objectValue(block.file_ref);
  if (stringValue(fileRef?.environment_id) !== "vfs") return undefined;
  return stringValue(fileRef?.path);
}

function agentBlobImagePreviewRefValue(
  value: ChatImagePreviewRef
): AgentBlobImagePreviewRef | undefined {
  if (typeof value === "string" || value.kind !== "agent-blob") return undefined;
  return value;
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
    serverMessages.at(-1)?.role === "user" || conversation?.status === "waiting";
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
  const currentUserMessage = serverMessages.findLast(
    (message) => message.role === "user"
  );
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
    ...(state === "active" &&
    (raw.working_provider === "wechat" ||
      raw.working_provider === "telegram" ||
      raw.working_provider === "signal")
      ? { workingProvider: raw.working_provider }
      : {}),
    ...(state === "active" && raw.loop_wake === true ? { loopWake: true } : {}),
  };
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
