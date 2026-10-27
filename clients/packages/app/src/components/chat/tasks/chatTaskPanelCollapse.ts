import { useSyncExternalStore } from "react";

/**
 * Whether the reader has folded the chat task panel down to its header.
 *
 * One choice for every conversation, kept in localStorage like the Home rail
 * folds: a reader who folds the panel away wants it folded the next time a
 * conversation opens, not only until they switch chats. Per device rather than
 * per account, since how much room the transcript gets is a property of the
 * screen in front of the reader. Safe to lose: the panel merely opens again.
 */
const COLLAPSE_STORAGE_KEY = "comma.chatTaskPanelCollapsed";
const COLLAPSE_CHANGED_EVENT = "comma:chat-task-panel-collapse-changed";

/** The choice made while storage refused it, keyed to what storage held then. */
let volatile: { collapsed: boolean; raw: string | null } | undefined;

function readRaw(): string | null {
  try {
    return globalThis.localStorage?.getItem(COLLAPSE_STORAGE_KEY) ?? null;
  } catch {
    return null;
  }
}

export function readChatTaskPanelCollapsed(): boolean {
  const raw = readRaw();
  // A later genuine storage change has a different raw value and wins.
  if (volatile && volatile.raw === raw) return volatile.collapsed;
  return raw === "true";
}

export function setChatTaskPanelCollapsed(collapsed: boolean) {
  volatile = undefined;
  try {
    const storage = globalThis.localStorage;
    if (storage) storage.setItem(COLLAPSE_STORAGE_KEY, String(collapsed));
    else volatile = { collapsed, raw: null };
  } catch {
    // A blocked write still applies for this session.
    volatile = { collapsed, raw: readRaw() };
  }
  globalThis.window?.dispatchEvent(new CustomEvent(COLLAPSE_CHANGED_EVENT));
}

export function subscribeChatTaskPanelCollapsed(listener: () => void) {
  if (!globalThis.window) return () => undefined;
  const handleStorage = (event: StorageEvent) => {
    if (event.key === COLLAPSE_STORAGE_KEY || event.key === null) listener();
  };
  window.addEventListener(COLLAPSE_CHANGED_EVENT, listener);
  window.addEventListener("storage", handleStorage);
  return () => {
    window.removeEventListener(COLLAPSE_CHANGED_EVENT, listener);
    window.removeEventListener("storage", handleStorage);
  };
}

export function useChatTaskPanelCollapsed(): boolean {
  return useSyncExternalStore(
    subscribeChatTaskPanelCollapsed,
    readChatTaskPanelCollapsed,
    readChatTaskPanelCollapsed
  );
}
