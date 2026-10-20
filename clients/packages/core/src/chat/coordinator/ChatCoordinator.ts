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
  ChatLeasedSetTaskStatusInput,
  ChatLeasedTarget,
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
import type { Effect } from "effect";
import { ConversationCommands } from "./ConversationCommands";
import { DraftEditor } from "./DraftEditor";
import { ChatEntries } from "./entries/ChatEntries";
import { sessionBoundaryOpener } from "./entries/sessionBoundary";
import type {
  ChatAttachmentIntakeClaim,
  ChatAttachmentIntakeTarget,
  ChatCoordinatorOptions,
  ChatProvider,
} from "./hostContract";
import { AttachmentIntake } from "./intake/AttachmentIntake";
import { SendIntents } from "./send/SendIntents";
import { SurfaceLeases } from "./SurfaceLeases";
import { GroupImagePreviews } from "./workspace/GroupImagePreviews";
import { SkillsCache } from "./workspace/SkillsCache";
import { WorkspaceChatResolver } from "./workspace/WorkspaceChatResolver";

export type * from "./hostContract";

export class ChatCoordinator implements ChatProvider {
  readonly #commands: ConversationCommands;
  readonly #drafts: DraftEditor;
  readonly #entries: ChatEntries;
  readonly #groupImages: GroupImagePreviews;
  readonly #intake: AttachmentIntake;
  readonly #leases: SurfaceLeases;
  readonly #sends: SendIntents;
  readonly #skills: SkillsCache;
  readonly #workspaceChat: WorkspaceChatResolver;

  constructor(options: ChatCoordinatorOptions) {
    const openBoundary = sessionBoundaryOpener(options);
    this.#entries = new ChatEntries(openBoundary, options);
    this.#commands = new ConversationCommands(this.#entries);
    this.#drafts = new DraftEditor(this.#entries);
    this.#intake = new AttachmentIntake(this.#entries);
    this.#leases = new SurfaceLeases(this.#entries, options);
    this.#sends = new SendIntents(this.#entries, options);
    this.#groupImages = new GroupImagePreviews(openBoundary, options, (groupId, id) => {
      for (const entry of this.#entries.values()) {
        if (entry.channel.groupId !== groupId) continue;
        const file = entry.channel.heldUpload(id);
        if (file) return file;
      }
      return undefined;
    });
    this.#skills = new SkillsCache(openBoundary, options.env);
    this.#workspaceChat = new WorkspaceChatResolver(openBoundary, options.env);
  }

  state(): ChatRuntimeSnapshot {
    return this.#entries.publisher.state();
  }

  drafts(): ChatRuntimeDraftsSnapshot {
    return this.#entries.publisher.drafts();
  }

  incomingAttachmentTarget(surfaceId: string) {
    return this.#intake.incomingTarget(surfaceId);
  }

  subscribe(listener: (snapshot: ChatRuntimeSnapshot) => void) {
    return this.#entries.publisher.subscribe(listener);
  }

  subscribeDrafts(listener: (drafts: ChatRuntimeDraftsSnapshot) => void) {
    return this.#entries.publisher.subscribeDrafts(listener);
  }

  retain(input: ChatRetainInput): ChatCommandReceipt {
    return this.#leases.retain(input);
  }

  release(input: ChatReleaseInput): ChatCommandReceipt {
    return this.#leases.release(input);
  }

  setDraft(input: ChatLeasedSetDraftInput): ChatCommandReceipt {
    return this.#drafts.setDraft(input);
  }

  prefillDraft(
    input: ChatLeasedSetDraftInput
  ): Effect.Effect<ChatCommandReceipt, Error> {
    return this.#drafts.prefill(input);
  }

  beginSendIntent(input: ChatLeasedBeginSendIntentInput): ChatBeginSendIntentReceipt {
    return this.#sends.begin(input);
  }

  cancelSendIntent(input: ChatLeasedBeginSendIntentInput): ChatCommandReceipt {
    return this.#sends.cancel(input);
  }

  resolveWorkspaceChat(
    workspaceId?: string
  ): Effect.Effect<ChatWorkspaceResolution, Error> {
    return this.#workspaceChat.resolve(workspaceId);
  }

  listSkills(input: ChatWorkspaceSkillsInput): Effect.Effect<ChatSkill[], Error> {
    return this.#skills.list(input);
  }

  readGroupImage(input: ChatReadGroupImageInput): Effect.Effect<Uint8Array, Error> {
    return this.#groupImages.read(input);
  }

  acknowledgeIntakeFailures(
    input: ChatLeasedAcknowledgeIntakeFailuresInput
  ): ChatCommandReceipt {
    return this.#intake.acknowledgeFailures(input);
  }

  attach(input: ChatLeasedAttachInput): ChatCommandReceipt {
    return this.#drafts.attach(input);
  }

  attachLocalFiles(input: ChatLeasedAttachLocalFilesInput): ChatCommandReceipt {
    return this.#drafts.attachLocalFiles(input);
  }

  claimAttachmentIntake(input: ChatAttachmentIntakeTarget): ChatAttachmentIntakeClaim {
    return this.#intake.claim(input);
  }

  removeAttachment(input: ChatLeasedAttachmentIdInput): ChatCommandReceipt {
    return this.#drafts.removeAttachment(input);
  }

  retryAttachment(input: ChatLeasedAttachmentIdInput): ChatCommandReceipt {
    return this.#drafts.retryAttachment(input);
  }

  sendDetachedMessage(target: ChatTarget, text: string): Effect.Effect<void, Error> {
    return this.#sends.sendDetached(target, text);
  }

  /** `onAccepted`: told once the message is pending (its draft consumed), before its server has it. */
  send(
    input: ChatLeasedSendInput,
    onAccepted?: () => void
  ): Effect.Effect<ChatCommandReceipt, Error> {
    return this.#sends.send(input, onAccepted);
  }

  clearPresentation(input: ChatLeasedTarget): ChatCommandReceipt {
    return this.#leases.clearPresentation(input);
  }

  retry(input: ChatLeasedClientRequestInput): Effect.Effect<ChatCommandReceipt, Error> {
    return this.#commands.retry(input);
  }

  discard(input: ChatLeasedClientRequestInput): ChatCommandReceipt {
    return this.#commands.discard(input);
  }

  answerQuestion(
    input: Parameters<ConversationCommands["answerQuestion"]>[0]
  ): Effect.Effect<ChatCommandReceipt, Error> {
    return this.#commands.answerQuestion(input);
  }

  attachQuestion(
    input: Parameters<ConversationCommands["attachQuestion"]>[0]
  ): ChatCommandReceipt {
    return this.#commands.attachQuestion(input);
  }

  removeQuestionAttachment(
    input: Parameters<ConversationCommands["removeQuestionAttachment"]>[0]
  ): ChatCommandReceipt {
    return this.#commands.removeQuestionAttachment(input);
  }

  retryQuestionAttachment(
    input: Parameters<ConversationCommands["retryQuestionAttachment"]>[0]
  ): ChatCommandReceipt {
    return this.#commands.retryQuestionAttachment(input);
  }

  acceptTaskReview(
    input: ChatLeasedTarget & { reviewVersion: number }
  ): Effect.Effect<ChatCommandReceipt, Error> {
    return this.#commands.acceptTaskReview(input);
  }

  setTaskStatus(
    input: ChatLeasedSetTaskStatusInput
  ): Effect.Effect<ChatCommandReceipt, Error> {
    return this.#commands.setTaskStatus(input);
  }

  older(input: ChatLeasedTarget): ChatCommandReceipt {
    return this.#commands.older(input);
  }

  readTaskActivity(input: ChatLeasedTarget): ChatCommandReceipt {
    return this.#commands.readTaskActivity(input);
  }

  refresh(input: ChatLeasedTarget): ChatCommandReceipt {
    return this.#commands.refresh(input);
  }

  reset() {
    this.#workspaceChat.reset();
    this.#skills.clear();
    this.#entries.reset();
  }

  close() {
    this.reset();
  }
}
