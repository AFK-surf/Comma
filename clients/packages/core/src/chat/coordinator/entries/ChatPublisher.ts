import {
  chatProtocolVersion,
  type ChatCommandReceipt,
  type ChatRuntimeDraftsSnapshot,
  type ChatRuntimeSnapshot,
} from "@comma/chat-contract";
import type { ChatCoordinatorOptions } from "../hostContract";
import { projectEntry } from "../projection/entryProjection";
import type { ChatEntry } from "./chatEntry";

/**
 * Publishes the retained entries as runtime snapshots and draft snapshots.
 * One revision orders every runtime publication and every command receipt.
 */
export class ChatPublisher {
  readonly #draftListeners = new Set<(drafts: ChatRuntimeDraftsSnapshot) => void>();
  readonly #entries: ReadonlyMap<string, ChatEntry>;
  readonly #listeners = new Set<(snapshot: ChatRuntimeSnapshot) => void>();
  readonly #onStateChanged: ChatCoordinatorOptions["onStateChanged"];
  #revision = 0;

  constructor(
    entries: ReadonlyMap<string, ChatEntry>,
    onStateChanged: ChatCoordinatorOptions["onStateChanged"]
  ) {
    this.#entries = entries;
    this.#onStateChanged = onStateChanged;
  }

  get revision() {
    return this.#revision;
  }

  state(): ChatRuntimeSnapshot {
    const sessions = this.#current().flatMap(([key, entry]) => {
      const session = projectEntry(key, entry);
      return session ? [session] : [];
    });
    return {
      protocolVersion: chatProtocolVersion,
      revision: this.#revision,
      sessions,
    };
  }

  drafts(): ChatRuntimeDraftsSnapshot {
    return {
      drafts: this.#current().map(([key, entry]) => ({
        draft: entry.channel.getSnapshot().draft,
        draftEpoch: entry.draftEpoch,
        key,
      })),
      protocolVersion: chatProtocolVersion,
    };
  }

  subscribe(listener: (snapshot: ChatRuntimeSnapshot) => void) {
    this.#listeners.add(listener);
    listener(this.state());
    return () => this.#listeners.delete(listener);
  }

  subscribeDrafts(listener: (drafts: ChatRuntimeDraftsSnapshot) => void) {
    this.#draftListeners.add(listener);
    listener(this.drafts());
    return () => this.#draftListeners.delete(listener);
  }

  publish() {
    this.#revision += 1;
    if (this.#listeners.size === 0 && !this.#onStateChanged) return;
    const snapshot = this.state();
    for (const listener of this.#listeners) {
      listener(snapshot);
    }
    void this.#onStateChanged?.(snapshot);
  }

  publishDrafts() {
    if (this.#draftListeners.size === 0) return;
    const drafts = this.drafts();
    for (const listener of this.#draftListeners) {
      listener(drafts);
    }
  }

  receipt(entry?: ChatEntry): ChatCommandReceipt {
    return {
      revision: this.#revision,
      ...(entry ? { draftEpoch: entry.draftEpoch } : {}),
    };
  }

  #current() {
    return Array.from(this.#entries.entries())
      .filter(([, entry]) => entry.boundary.isCurrent())
      .toSorted(([left], [right]) => left.localeCompare(right));
  }
}
