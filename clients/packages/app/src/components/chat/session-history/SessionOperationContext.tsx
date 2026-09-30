import { createContext, useContext, type ReactNode } from "react";
import { useCommaMessages } from "@comma/i18n/react";
import { useChatRegistry } from "../ChatProvider";
import type { SessionItemPresentation } from "./model/sessionHistoryPresentation";

const ConversationName = createContext<(id: string) => string | undefined>(
  () => undefined
);

/** Resolve names from already retained chat state; never fetch once per history row. */
export function SessionOperationContext({
  groupId,
  conversationId,
  children,
}: {
  groupId: string;
  conversationId: string;
  children: ReactNode;
}) {
  const registry = useChatRegistry();
  const m = useCommaMessages();
  return (
    <ConversationName.Provider
      value={(id) =>
        registry.getRetainedSnapshot(groupId, id)?.conversation?.title?.trim() ||
        (id === conversationId ? m.session_current_conversation() : undefined)
      }
    >
      {children}
    </ConversationName.Provider>
  );
}

export function useSessionOperation(item: SessionItemPresentation) {
  const name = useContext(ConversationName);
  const m = useCommaMessages();
  const destination = item.destination;
  const title =
    destination && (name(destination.id) || destination.name || m.chat_ref_fallback());
  return [title, item.operation].filter(Boolean).join(" · ");
}
