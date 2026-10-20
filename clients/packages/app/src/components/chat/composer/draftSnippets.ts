import {
  createContext,
  createElement,
  useCallback,
  useContext,
  useId,
  useMemo,
  useState,
  useSyncExternalStore,
  type Dispatch,
  type ReactNode,
  type SetStateAction,
} from "react";
import type { AttachedText } from "@comma/core/chat";
import type { RecommendationSource } from "@comma/recommendation-contract";

/**
 * Text staged for the next message as one tile: a Routine row's prompt, or a
 * paste too long to edit in the prompt. Like quotes, snippets are
 * renderer-only draft state, kept per conversation for the chat session the way
 * its draft is, so leaving a conversation and coming back finds them. At send
 * time each one is folded into the message text. A Routine row goes as an
 * attached text, which the sent message shows as a file; a paste goes after
 * the typed text, where "Show in text field" would have written it.
 */
export type ChatDraftSnippet = {
  id: string;
  kind: "paste" | "routine";
  text: string;
  /** The app the text came from, for the tile's brand mark. */
  source?: RecommendationSource | undefined;
  /** The item the text is about, such as a Linear issue or a Gmail message.
   *  The browser sidebar opens it once the message is sent. */
  sourceUrl?: string | undefined;
};

/** A conversation's staged snippets, shared by every surface that shows it. */
export interface ComposerDraftSnippets {
  items: readonly ChatDraftSnippet[];
  setItems: Dispatch<SetStateAction<readonly ChatDraftSnippet[]>>;
}

/**
 * A paste at least this long is staged as a snippet instead of written into
 * the prompt: it is material for the message, not text to edit there.
 */
export const PASTED_SNIPPET_MIN_LENGTH = 5_000;

let snippetSequence = 0;

export function createChatDraftSnippet(
  snippet: Omit<ChatDraftSnippet, "id">
): ChatDraftSnippet {
  snippetSequence += 1;
  return { ...snippet, id: `snippet-${snippetSequence}` };
}

/** The tile's title: the text's first line, as a pasted-text tile shows it. */
export function chatSnippetTitle(text: string) {
  return (
    text
      .split("\n")
      .map((line) => line.replace(/\s+/gu, " ").trim())
      .find((line) => line !== "") ?? ""
  );
}

/** The pasted snippets folded after the typed text. */
export function composeMessageWithSnippets(
  text: string,
  snippets: readonly ChatDraftSnippet[]
) {
  const pasted = snippets.filter((snippet) => snippet.kind === "paste");
  if (pasted.length === 0) return text;
  return [text.trim(), ...pasted.map((snippet) => snippet.text)]
    .filter((part) => part !== "")
    .join("\n\n");
}

/** The Routine snippets, sent as attached texts named by their app. */
export function snippetAttachedTexts(
  snippets: readonly ChatDraftSnippet[]
): AttachedText[] {
  return snippets.flatMap((snippet) =>
    snippet.kind === "routine"
      ? [
          {
            ...(snippet.source ? { source: snippet.source.appName } : {}),
            text: snippet.text,
          },
        ]
      : []
  );
}

const NO_SNIPPETS: readonly ChatDraftSnippet[] = [];

type DraftSnippetStore = {
  get(key: string): readonly ChatDraftSnippet[];
  subscribe(listener: () => void): () => void;
  update(key: string, action: SetStateAction<readonly ChatDraftSnippet[]>): void;
};

function createDraftSnippetStore(): DraftSnippetStore {
  const staged = new Map<string, readonly ChatDraftSnippet[]>();
  const listeners = new Set<() => void>();
  return {
    get: (key) => staged.get(key) ?? NO_SNIPPETS,
    subscribe(listener) {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
    update(key, action) {
      const current = staged.get(key) ?? NO_SNIPPETS;
      const next = typeof action === "function" ? action(current) : action;
      if (next === current) return;
      if (next.length === 0) staged.delete(key);
      else staged.set(key, next);
      for (const listener of listeners) listener();
    },
  };
}

const DraftSnippetStoreContext = createContext<DraftSnippetStore | null>(null);

/** Keeps staged snippets by conversation for one chat session. */
export function DraftSnippetsProvider({ children }: { children: ReactNode }) {
  const [store] = useState(createDraftSnippetStore);
  return createElement(DraftSnippetStoreContext.Provider, { value: store }, children);
}

/**
 * The snippets staged for `conversationId`. A conversation without an id yet,
 * or a render without `DraftSnippetsProvider`, keeps them for the caller only.
 */
export function useConversationDraftSnippets(
  conversationId: string | undefined
): ComposerDraftSnippets {
  const shared = useContext(DraftSnippetStoreContext);
  const [own] = useState(createDraftSnippetStore);
  const unsaved = useId();
  const store = conversationId === undefined ? own : (shared ?? own);
  const key = conversationId ?? unsaved;
  const read = useCallback(() => store.get(key), [key, store]);
  const items = useSyncExternalStore(store.subscribe, read, read);
  const setItems = useCallback<Dispatch<SetStateAction<readonly ChatDraftSnippet[]>>>(
    (action) => store.update(key, action),
    [key, store]
  );
  return useMemo(() => ({ items, setItems }), [items, setItems]);
}
