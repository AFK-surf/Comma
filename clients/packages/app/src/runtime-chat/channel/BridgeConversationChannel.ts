import { baseLocale, type CommaLocale } from "@comma/i18n";
import { getNativeBridge } from "@comma/native-bridge";
import type { SessionProductLease } from "@comma/session-contract";
import type {
  AttachmentUploadInput,
  ChatImagePreviewRef,
  ConversationChannelState,
} from "../../components/chat/model/conversationChannel";
import { DraftAttachments } from "./attachments/DraftAttachments";
import { ChannelLease } from "./ChannelLease";
import { ChannelSend } from "./ChannelSend";
import { ChannelStore, idleChannelState } from "./channelStore";
import type { ChatChannel, ChatSendOptions } from "./ChatChannel";
import { ChannelDraft } from "./draft/ChannelDraft";
import { DraftCommands } from "./DraftCommands";
import { LocalFilePreviews } from "./preview/LocalFilePreviews";
import { ProjectionFence } from "./projection/ProjectionFence";
import { SessionProjection } from "./projection/SessionProjection";

export class BridgeConversationChannel implements ChatChannel {
  readonly #attachments: DraftAttachments;
  readonly #commands: DraftCommands;
  readonly #draft: ChannelDraft;
  readonly #lease: ChannelLease;
  readonly #previews: LocalFilePreviews;
  readonly #projection: SessionProjection;
  readonly #sends: ChannelSend;
  readonly #store: ChannelStore;

  // Main installs its HEIC transcoder on macOS only; mirror that here so the
  // composer can turn an un-decodable camera file away before intake.
  readonly transcodesImages: boolean;

  constructor({
    conversationId,
    groupId,
    initialState,
    locale = baseLocale,
    presentInSideChat = false,
    session,
    workspaceId,
  }: {
    conversationId: string;
    groupId: string;
    /**
     * A transcript snapshot carried over from this signed-in session's
     * previous product-lease generation (ChatProvider's channel seed store).
     * It renders immediately — with its original object identities, so
     * memoized rows survive the swap — and yields once the rebuilt Main
     * entry's canonical state settles. Display-only by contract: it never
     * counts as an accepted snapshot (revision cursors and hasSeenSession
     * stay unset), issues no commands, and carries no draft or attachments —
     * an auth reset preserves no ghost drafts (ADR
     * 2026-07-17-electron-side-chat-window).
     */
    initialState?: ConversationChannelState;
    locale?: CommaLocale;
    presentInSideChat?: boolean;
    session: SessionProductLease;
    workspaceId: string;
  }) {
    const bridge = getNativeBridge();
    this.pickAttachments =
      bridge.platform === "electron" ? () => this.#attachments.pickNative() : undefined;
    const surfaceId = bridge.self.windowId;
    this.transcodesImages = bridge.os === "macos";
    const subscriberId = `${bridge.self.windowId}:${groupId}/${conversationId}`;
    const key = `${groupId}/${conversationId}`;
    const store = new ChannelStore(initialState ?? idleChannelState);
    const target = { conversationId, groupId, workspaceId };
    const lease = new ChannelLease({
      presentInSideChat,
      session,
      store,
      subscriberId,
      target,
    });
    const commands = new DraftCommands(lease);
    const draft = new ChannelDraft({ commands, key, session, store, surfaceId });
    const fence = new ProjectionFence();
    const previews = new LocalFilePreviews(bridge, { groupId, session });
    const attachments = new DraftAttachments({
      commands,
      fence,
      lease,
      locale,
      store,
      surfaceId,
    });
    this.#attachments = attachments;
    this.#commands = commands;
    this.#draft = draft;
    this.#lease = lease;
    this.#previews = previews;
    this.#projection = new SessionProjection(
      { attachments, draft, fence, lease, previews, store },
      { key, session, subscriberId },
      initialState !== undefined
    );
    this.#sends = new ChannelSend({
      attachments,
      commands,
      draft,
      lease,
      store,
      surfaceId,
    });
    this.#store = store;
  }

  start() {
    if (this.#lease.active) {
      return;
    }
    this.#previews.replace();
    this.#projection.restart();
    this.#commands.restart();
    this.#draft.reset();
    this.#lease.start({
      applyDraftsEnvelope: (envelope) => this.#draft.applyDraftsEnvelope(envelope),
      applyEnvelope: (envelope) => this.#projection.applyEnvelope(envelope),
      observeDraftEpoch: (receipt) => this.#commands.observeDraftEpoch(receipt),
    });
  }

  stop() {
    this.#previews.dispose();
    if (!this.#lease.active) {
      return;
    }
    this.#lease.end();
    this.#attachments.abandon();
    this.#draft.reset();
    this.#lease.release();
  }

  subscribe(listener: () => void) {
    return this.#store.subscribe(listener);
  }

  getSnapshot() {
    return this.#store.state;
  }

  setDraft(draft: string) {
    return this.#draft.set(draft);
  }

  send(text: string, options: ChatSendOptions = {}) {
    return this.#sends.send(text, options);
  }

  clearPresentation() {
    return this.#lease.runWhenReady((lease) =>
      getNativeBridge().chat.clearPresentation(lease)
    );
  }

  retry(clientRequestId: string) {
    return this.#lease.runWhenReady((lease) =>
      getNativeBridge().chat.retry({ ...lease, clientRequestId })
    );
  }

  discard(clientRequestId: string) {
    return this.#lease.runWhenReady((lease) =>
      getNativeBridge().chat.discard({ ...lease, clientRequestId })
    );
  }

  acceptTaskReview(reviewVersion: number) {
    return this.#lease.runWhenReady((lease) =>
      getNativeBridge().chat.acceptTaskReview({ ...lease, reviewVersion })
    );
  }

  refresh() {
    return this.#lease.runWhenReady((lease) => getNativeBridge().chat.refresh(lease));
  }

  attachFiles(files: AttachmentUploadInput[]) {
    this.#attachments.attach(files);
  }

  readonly pickAttachments: (() => unknown) | undefined;

  previewLocalFile(previewRef: ChatImagePreviewRef, signal?: AbortSignal) {
    return this.#previews.acquire(previewRef, signal);
  }

  removeAttachment(attachmentId: string) {
    return this.#attachments.remove(attachmentId);
  }

  retryAttachment(attachmentId: string) {
    return this.#attachments.retry(attachmentId);
  }
}
