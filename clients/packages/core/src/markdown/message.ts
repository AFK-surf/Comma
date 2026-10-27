// A chat message's Markdown (`ChatMessage.markdown`): its parts as one document, a Task chip or a card in the place
// its part has, parsed once by the core for every client.
import type { ChatMessagePart } from "@comma/chat-contract";
import { stripCommaProtocolMarkersPreservingWhitespace } from "../chat/model/protocol.ts";
import { partsDocument, partsDocumentNodes } from "./parts.ts";
import { toMarkdownTree, type MarkdownTree } from "./tree.ts";

export function messageMarkdown(parts: readonly ChatMessagePart[]): MarkdownTree {
  return toMarkdownTree(
    partsDocumentNodes(
      partsDocument(parts, {
        // Question, Mac app and Mini App cards are drawn after the message, not in its text (QuestionCard,
        // MacAppItemCards, MessageMiniAppCards).
        markdownText: (part) =>
          part.kind === "markdown"
            ? part.text
            : part.kind === "question" ||
                part.kind === "mac-app-item" ||
                part.kind === "mini-app"
              ? ""
              : undefined,
        isBlock: (part) => part.kind === "dynamic-ui",
        sanitizeMarkdown: stripCommaProtocolMarkersPreservingWhitespace,
      })
    )
  );
}
