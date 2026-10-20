import type { ConversationChannelState } from "./conversationChannel";

/**
 * Whether the composer draft is the only field that moved. The channel's
 * draft fast path keeps every other field's identity, so identity is exact.
 */
export function isDraftOnlyChange(
  previous: ConversationChannelState,
  next: ConversationChannelState
) {
  if (previous.draft === next.draft) return false;
  const keys = Object.keys(next) as (keyof ConversationChannelState)[];
  return (
    keys.length === Object.keys(previous).length &&
    keys.every((key) => key === "draft" || previous[key] === next[key])
  );
}
