import type { ChatLeasedTarget, ChatTarget } from "@comma/chat-contract";
import { baseLocale } from "@comma/i18n";
import { isDraftOnlyChange } from "../../../chat-runtime";
import type { ChatCoordinatorOptions } from "../hostContract";
import { withSessionDraft } from "../projection/draftProjection";
import {
  chatKey,
  createChatEntry,
  REJECTED_PROJECTION,
  type ChatChannelHost,
  type ChatEntry,
} from "./chatEntry";
import { ChatPublisher } from "./ChatPublisher";
import {
  isSameLiveBoundary,
  StaleChatSessionError,
  type ChatSessionBoundary,
} from "./sessionBoundary";
import { SideChatTargets } from "./SideChatTargets";

const MAX_RETAINED_CHAT_SESSIONS = 32;

/**
 * The retained entries, each bound to the session boundary it was opened
 * under, and the publisher and side chat targets that read them. An entry
 * whose session is no longer current is quarantined: disposed and published
 * away.
 */
export class ChatEntries {
  readonly #channelHost: ChatChannelHost;
  readonly #entries = new Map<string, ChatEntry>();
  readonly openBoundary: () => ChatSessionBoundary;
  readonly publisher: ChatPublisher;
  readonly sideChat = new SideChatTargets((key) => this.#entries.get(key));

  constructor(
    openBoundary: () => ChatSessionBoundary,
    {
      getClientDeviceId,
      locale = baseLocale,
      onCanonicalMessagesAppended,
      onLocalFilesCommitted,
      onStateChanged,
      transcodeAttachment,
    }: Pick<
      ChatCoordinatorOptions,
      | "getClientDeviceId"
      | "locale"
      | "onCanonicalMessagesAppended"
      | "onLocalFilesCommitted"
      | "onStateChanged"
      | "transcodeAttachment"
    >
  ) {
    this.#channelHost = {
      getClientDeviceId,
      locale,
      onCanonicalMessagesAppended,
      onLocalFilesCommitted,
      transcodeAttachment,
    };
    this.openBoundary = openBoundary;
    this.publisher = new ChatPublisher(this.#entries, this.sideChat, onStateChanged);
  }

  get(key: string) {
    return this.#entries.get(key);
  }

  values() {
    return this.#entries.values();
  }

  ensure(target: ChatTarget) {
    const key = chatKey(target);
    const boundary = this.openBoundary();
    boundary.assertCurrent();
    const existing = this.#entries.get(key);
    if (existing && isSameLiveBoundary(existing.boundary, boundary)) {
      existing.boundary.assertCurrent();
      return existing;
    }
    if (existing) this.dispose(key, existing);
    if (this.#entries.size >= MAX_RETAINED_CHAT_SESSIONS) {
      throw new Error(
        `Chat retains at most ${MAX_RETAINED_CHAT_SESSIONS} active sessions.`
      );
    }

    const entry = createChatEntry(target, boundary, this.#channelHost, (changed) =>
      this.#onChannelChanged(changed)
    );
    this.#entries.set(key, entry);
    boundary.assertCurrent();
    return entry;
  }

  required(target: ChatLeasedTarget) {
    const key = chatKey(target);
    const boundary = this.openBoundary();
    boundary.assertCurrent();
    const entry = this.#entries.get(key);
    if (!entry) {
      throw new Error(
        `Chat session ${target.groupId}/${target.conversationId} is not retained.`
      );
    }
    if (!isSameLiveBoundary(entry.boundary, boundary)) {
      this.quarantine(key, entry);
      throw new StaleChatSessionError();
    }
    if (entry.subscribers.get(target.subscriberId) !== target.leaseId) {
      throw new Error(
        `The stale chat lease for ${target.groupId}/${target.conversationId} is no longer current.`
      );
    }
    entry.boundary.assertCurrent();
    return entry;
  }

  dispose(key: string, entry: ChatEntry) {
    if (this.#entries.get(key) !== entry) return;
    if (entry.releaseTimer) clearTimeout(entry.releaseTimer);
    entry.releaseTimer = undefined;
    entry.releaseSubscription();
    entry.channel.stop();
    this.#entries.delete(key);
    this.sideChat.forget(key);
  }

  /** Disposes every entry, then publishes and tells each side chat target so. */
  reset() {
    const sideChatTargetKeys = this.sideChat.keys();
    for (const [key, entry] of this.#entries) {
      this.dispose(key, entry);
    }
    this.sideChat.present(undefined);
    this.publisher.publish();
    for (const key of sideChatTargetKeys) this.sideChat.notify(key);
  }

  quarantine(key: string, entry: ChatEntry) {
    if (this.#entries.get(key) !== entry) return;
    this.dispose(key, entry);
    this.publisher.publish(key);
  }

  touch(entry: ChatEntry) {
    if (!entry.boundary.isCurrent()) {
      this.quarantine(entry.key, entry);
      return;
    }
    entry.revision += 1;
    entry.projection = undefined;
    entry.runtimeProjection = undefined;
    this.publisher.publish(entry.key);
    if (!entry.boundary.isCurrent()) {
      this.quarantine(entry.key, entry);
    }
  }

  /**
   * A keystroke is a draft-only emit: it patches the draft into the cached
   * projections, keeping state() exact, and publishes drafts alone. Anything
   * else moved conversation content and republishes the runtime snapshot.
   */
  #onChannelChanged(entry: ChatEntry) {
    const previous = entry.observedState;
    const next = entry.channel.getSnapshot();
    entry.observedState = next;
    if (entry.boundary.isCurrent() && isDraftOnlyChange(previous, next)) {
      if (entry.projection)
        entry.projection = { ...entry.projection, draft: next.draft };
      if (entry.runtimeProjection && entry.runtimeProjection !== REJECTED_PROJECTION) {
        entry.runtimeProjection = withSessionDraft(
          entry.runtimeProjection,
          next.draft,
          entry.draftEpoch
        );
      }
      this.publisher.publishDrafts();
      return;
    }
    this.touch(entry);
    if (previous.draft !== next.draft) this.publisher.publishDrafts();
  }
}
