import type {
  ChatBeginSendIntentReceipt,
  ChatCommandReceipt,
  ChatLeasedAcknowledgeIntakeFailuresInput,
  ChatLeasedAttachInput,
  ChatLeasedAttachLocalFilesInput,
  ChatLeasedAttachmentIdInput,
  ChatLeasedBeginSendIntentInput,
  ChatLeasedClientRequestInput,
  ChatLeasedSendInput,
  ChatLeasedSetDraftInput,
  ChatLeasedTarget,
  ChatPickAttachmentError,
  ChatReadGroupImageInput,
  ChatReleaseInput,
  ChatRetainInput,
  ChatRuntimeDraftsSnapshot,
  ChatRuntimeSnapshot,
  ChatSkill,
  ChatTarget,
  ChatWorkspaceResolution,
  ChatWorkspaceSkillsInput,
} from "@comma/chat-contract";
import type { CommaLocale } from "@comma/i18n";
import type { SessionProductLease } from "@comma/session-contract";
import type { CommaApiClient, CommaConversation, CommaLocalFileRef } from "../../api";
import type { AttachmentTranscoder, ChatMessage } from "../../chat-runtime";

/** Host-owned API binding: Main bearer or SharedWorker HttpOnly cookie. */
export interface ChatSessionBoundApi {
  readonly api: CommaApiClient;
  readonly session: SessionProductLease;
  assertCurrent(): void;
  isCurrent(): boolean;
}

/** What a host builds the coordinator with: exactly one API factory and its hooks. */
export type ChatCoordinatorOptions = {
  createApi?: () => CommaApiClient;
  createSessionBoundApi?: () => ChatSessionBoundApi;
  getClientDeviceId?: (workspaceId: string) => string | undefined;
  locale?: CommaLocale;
  onCanonicalMessagesAppended?: (input: {
    conversation: CommaConversation;
    messages: readonly ChatMessage[];
    target: ChatTarget;
  }) => void;
  onLocalFilesCommitted?: (
    files: readonly CommaLocalFileRef[],
    committedAtMs: number | undefined
  ) => Promise<void> | void;
  onStateChanged?: (snapshot: ChatRuntimeSnapshot) => Promise<void> | void;
  releaseDelayMs?: number;
  renderGroupImagePreview?: GroupImagePreviewRenderer;
  /** Installed only on hosts that can decode HEIC/HEIF into JPEG before upload. */
  transcodeAttachment?: AttachmentTranscoder;
};

/**
 * How one native attachment intake ended. `errorCount` counts selected items
 * that failed selection, registration, or attach; a send waiting on this
 * intake must not commit a partial subset while any selected file failed.
 */
export type ChatAttachmentIntakeOutcome = {
  cancelled: boolean;
  errorCount: number;
  errors?: readonly ChatPickAttachmentError[];
};

export type GroupImagePreviewRenderer = (input: {
  bytes: Uint8Array;
  mediaType: string;
}) => Promise<Uint8Array>;

export interface ChatProvider {
  acceptTaskReview(
    input: ChatLeasedTarget & { reviewVersion: number }
  ): Promise<ChatCommandReceipt>;
  beginSendIntent(input: ChatLeasedBeginSendIntentInput): ChatBeginSendIntentReceipt;
  cancelSendIntent(input: ChatLeasedBeginSendIntentInput): ChatCommandReceipt;
  acknowledgeIntakeFailures(
    input: ChatLeasedAcknowledgeIntakeFailuresInput
  ): ChatCommandReceipt;
  attach(input: ChatLeasedAttachInput): ChatCommandReceipt;
  attachLocalFiles(input: ChatLeasedAttachLocalFilesInput): ChatCommandReceipt;
  claimAttachmentIntake(input: ChatAttachmentIntakeTarget): ChatAttachmentIntakeClaim;
  clearPresentation(input: ChatLeasedTarget): ChatCommandReceipt;
  discard(input: ChatLeasedClientRequestInput): ChatCommandReceipt;
  refresh(input: ChatLeasedTarget): ChatCommandReceipt;
  removeAttachment(input: ChatLeasedAttachmentIdInput): ChatCommandReceipt;
  release(input: ChatReleaseInput): ChatCommandReceipt;
  retain(input: ChatRetainInput): ChatCommandReceipt;
  retry(input: ChatLeasedClientRequestInput): Promise<ChatCommandReceipt>;
  send(input: ChatLeasedSendInput): Promise<ChatCommandReceipt>;
  setDraft(input: ChatLeasedSetDraftInput): ChatCommandReceipt;
  presentInSideChat(input: ChatLeasedTarget): ChatCommandReceipt;
  readGroupImage(input: ChatReadGroupImageInput): Promise<Uint8Array>;
  resolveWorkspaceChat(input?: void): Promise<ChatWorkspaceResolution>;
  retryAttachment(input: ChatLeasedAttachmentIdInput): ChatCommandReceipt;
  listSkills(input: ChatWorkspaceSkillsInput): Promise<ChatSkill[]>;
  state(input?: void): ChatRuntimeSnapshot;
  drafts(input?: void): ChatRuntimeDraftsSnapshot;
}

/**
 * Main-local fence for one native attachment picker invocation. It is never
 * exposed through the generated bridge: the session-bound provider captures
 * it before opening the native dialog and rechecks it immediately before each
 * regular-file route registration. The claim is also this draft's send
 * admission: send() drains it — with its typed outcome — before composing
 * the canonical message.
 */
export interface ChatAttachmentIntakeClaim {
  readonly intakeId: string;
  assertCurrent(): void;
  markDialogClosed(): void;
  releaseIfUnused(): void;
  settle(outcome: ChatAttachmentIntakeOutcome): void;
}

export type ChatAttachmentIntakeTarget = ChatLeasedTarget &
  Readonly<{ surfaceId: string }>;
