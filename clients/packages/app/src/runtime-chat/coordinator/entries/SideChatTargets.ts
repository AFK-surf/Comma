import type { ChatTarget, SideChatSession } from "@comma/chat-contract";
import { projectSideChatSession } from "../projection/entryProjection";
import { chatKey, type ChatEntry } from "./chatEntry";

type SideChatListener = (session: SideChatSession | undefined) => void;

/**
 * The conversation presented in the side chat, and the listeners following
 * side chat targets: each is told whenever its target's entry is published.
 */
export class SideChatTargets {
  readonly #entry: (key: string) => ChatEntry | undefined;
  readonly #listeners = new Map<string, Set<SideChatListener>>();
  #presentedKey: string | undefined;

  constructor(entry: (key: string) => ChatEntry | undefined) {
    this.#entry = entry;
  }

  get presentedKey() {
    return this.#presentedKey;
  }

  present(key: string | undefined) {
    this.#presentedKey = key;
  }

  /** A disposed entry is no longer presented. */
  forget(key: string) {
    if (this.#presentedKey === key) {
      this.#presentedKey = undefined;
    }
  }

  keys() {
    return [...this.#listeners.keys()];
  }

  sessionFor(target: ChatTarget) {
    return projectSideChatSession(this.#entry(chatKey(target)));
  }

  subscribe(target: ChatTarget, listener: SideChatListener) {
    const key = chatKey(target);
    const listeners = this.#listeners.get(key) ?? new Set();
    listeners.add(listener);
    this.#listeners.set(key, listeners);
    listener(this.sessionFor(target));
    return () => {
      listeners.delete(listener);
      if (listeners.size === 0) this.#listeners.delete(key);
    };
  }

  notify(key: string) {
    const listeners = this.#listeners.get(key);
    if (!listeners?.size) return;
    const session = projectSideChatSession(this.#entry(key));
    for (const listener of listeners) listener(session);
  }
}
