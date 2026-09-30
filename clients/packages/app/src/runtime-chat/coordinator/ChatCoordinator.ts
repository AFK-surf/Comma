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
  ChatReadGroupImageInput,
  ChatReleaseInput,
  ChatRetainInput,
  ChatRuntimeDraftsSnapshot,
  ChatRuntimeSnapshot,
  ChatSkill,
  ChatTarget,
  ChatWorkspaceResolution,
  ChatWorkspaceSkillsInput,
  SideChatSession,
} from "@comma/chat-contract";
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
    this.#groupImages = new GroupImagePreviews(openBoundary, options);
    this.#skills = new SkillsCache(openBoundary);
    this.#workspaceChat = new WorkspaceChatResolver(openBoundary);
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

  sideChatSessionForTarget(target: ChatTarget): SideChatSession | undefined {
    return this.#entries.sideChat.sessionFor(target);
  }

  subscribeSideChatTarget(
    target: ChatTarget,
    listener: (session: SideChatSession | undefined) => void
  ) {
    return this.#entries.sideChat.subscribe(target, listener);
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

  beginSendIntent(input: ChatLeasedBeginSendIntentInput): ChatBeginSendIntentReceipt {
    return this.#sends.begin(input);
  }

  cancelSendIntent(input: ChatLeasedBeginSendIntentInput): ChatCommandReceipt {
    return this.#sends.cancel(input);
  }

  presentInSideChat(input: ChatLeasedTarget): ChatCommandReceipt {
    return this.#commands.presentInSideChat(input);
  }

  resolveWorkspaceChat(): Promise<ChatWorkspaceResolution> {
    return this.#workspaceChat.resolve();
  }

  listSkills(input: ChatWorkspaceSkillsInput): Promise<ChatSkill[]> {
    return this.#skills.list(input);
  }

  readGroupImage(input: ChatReadGroupImageInput): Promise<Uint8Array> {
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

  sendDetachedMessage(target: ChatTarget, text: string): Promise<void> {
    return this.#sends.sendDetached(target, text);
  }

  send(input: ChatLeasedSendInput): Promise<ChatCommandReceipt> {
    return this.#sends.send(input);
  }

  clearPresentation(input: ChatLeasedTarget): ChatCommandReceipt {
    return this.#leases.clearPresentation(input);
  }

  retry(input: ChatLeasedClientRequestInput): Promise<ChatCommandReceipt> {
    return this.#commands.retry(input);
  }

  discard(input: ChatLeasedClientRequestInput): ChatCommandReceipt {
    return this.#commands.discard(input);
  }

  acceptTaskReview(
    input: ChatLeasedTarget & { reviewVersion: number }
  ): Promise<ChatCommandReceipt> {
    return this.#commands.acceptTaskReview(input);
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
