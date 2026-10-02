import { memo } from "react";
import type { ConversationThreadProps } from "./conversationThreadProps";
import { ConversationThreadView } from "./ConversationThreadView";
import { useConversationThread } from "./useConversationThread";

export type { ChatOutgoingLaunch } from "./outgoing/outgoingPresentation";
export type { AnchoredTail } from "./turns/useAnchoredTails";
export { partitionConversationTurns } from "./layout/conversationLayout";

// Memoized: the parent ConversationView re-renders on every change to the
// conversation's view state (connection, attachments, ...), and
// this component's render is O(messages). With stable props — message array
// identity, memoized slot elements, and identity-stable callbacks — a change
// that leaves the transcript alone doesn't re-render it.
export const ConversationThread = memo(function ConversationThread(
  props: ConversationThreadProps
) {
  const thread = useConversationThread(props);
  return <ConversationThreadView {...thread} />;
});
