import { useSyncExternalStore } from "react";
import { isDraftOnlyChange } from "../model/channelStateChange";
import type { ConversationChannelState } from "../model/conversationChannel";

/** The conversation as the view shows it: every field but the draft. */
export type ConversationViewState = Omit<ConversationChannelState, "draft">;

/**
 * The composer draft as its own subscription. A keystroke is a conversation's
 * most frequent change and only the composer shows it, so only the composer
 * re-renders for it; the view, the transcript, and their hosts do not.
 */
export interface ComposerDraftSource {
  getSnapshot(): string;
  subscribe(listener: () => void): () => void;
}

const unsubscribeNothing = () => {};

/** A draft that stays fixed while shown: a pending, local, or test draft. */
export function fixedDraftSource(draft: string): ComposerDraftSource {
  return { getSnapshot: () => draft, subscribe: () => unsubscribeNothing };
}

export function useComposerDraft(source: ComposerDraftSource) {
  return useSyncExternalStore(source.subscribe, source.getSnapshot, source.getSnapshot);
}

/** Re-renders only when `select` answers differently, such as empty or not. */
export function useComposerDraftSelector<T>(
  source: ComposerDraftSource,
  select: (draft: string) => T
) {
  const getSnapshot = () => select(source.getSnapshot());
  return useSyncExternalStore(source.subscribe, getSnapshot, getSnapshot);
}

/**
 * Projects channel states to view states that keep their identity across
 * draft-only changes, so memoized hosts skip a keystroke entirely.
 */
export function createViewStateProjection() {
  let lastState: ConversationChannelState | undefined;
  let lastView: ConversationViewState | undefined;
  return (state: ConversationChannelState): ConversationViewState => {
    if (
      !lastState ||
      !lastView ||
      (state !== lastState && !isDraftOnlyChange(lastState, state))
    ) {
      const { draft: _draft, ...view } = state;
      lastView = view;
    }
    lastState = state;
    return lastView;
  };
}
