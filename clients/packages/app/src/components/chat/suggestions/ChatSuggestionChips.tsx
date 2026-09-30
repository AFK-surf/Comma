import { useCommaMessages } from "@comma/i18n/react";
import { ScrollArea, spacing } from "@comma/ui";
import { memo, type CSSProperties } from "react";
import { Button as AriaButton } from "react-aria-components";
import type { CommaChatSuggestion } from "../../../api";

/**
 * The capsule row under the newest assistant turn: model-written openers for
 * the next message, sent verbatim on click.
 *
 * Rendered through `ConversationView`'s transcript tail, so it lives in the
 * current turn only and disappears with it. Suggestions being generated render
 * nothing — the row has no placeholder state, so a slow generation costs no
 * layout shift. Overflow uses ScrollArea's easing edge mask instead of a
 * hard clip.
 */
export const ChatSuggestionChips = memo(function ChatSuggestionChips({
  items,
  onSelect,
}: {
  items: readonly CommaChatSuggestion[];
  onSelect: (suggestion: CommaChatSuggestion) => void;
}) {
  const messages = useCommaMessages();
  if (items.length === 0) return null;

  return (
    <ScrollArea
      aria-label={messages.chat_suggestions_label()}
      className="comma-chat-suggestions"
      contentClassName="flex w-max items-center gap-md py-xxs"
      data-testid="chat-suggestions"
      edgeEffect="mask"
      edgeMask={{ size: spacing["4xl"] }}
      orientation="horizontal"
      role="toolbar"
      scrollbar={false}
      viewportProps={{ tabIndex: -1 }}
    >
      {items.map((suggestion, index) => (
        <AriaButton
          className="comma-chat-suggestion"
          data-testid={`chat-suggestion-${suggestion.id}`}
          key={suggestion.id}
          onPress={() => onSelect(suggestion)}
          style={{ "--comma-chat-suggestion-index": index } as CSSProperties}
        >
          {suggestion.label}
        </AriaButton>
      ))}
    </ScrollArea>
  );
});
