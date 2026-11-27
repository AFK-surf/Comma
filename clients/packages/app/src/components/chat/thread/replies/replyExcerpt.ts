import type { useCommaMessages } from "@comma/i18n/react";
import type { ChatMessage } from "@comma/core/chat";
import {
  inlineMessagePartPlainText,
  stripCommaProtocolMarkersPreservingWhitespace,
} from "@comma/core/chat";
import { withoutScreenLinks } from "../../../remote-screen/screenLinks";

const CODE_SENTINEL = String.fromCharCode(1);
const CODE_SENTINEL_PATTERN = new RegExp(`${CODE_SENTINEL}(\\d+)${CODE_SENTINEL}`, "g");

/** Strip Markdown framing so a compact reply preview reads as plain prose. */
function stripMarkdownForExcerpt(markdown: string) {
  const cleaned = withoutScreenLinks(
    stripCommaProtocolMarkersPreservingWhitespace(markdown)
  );
  // Protect inline/fenced code content while unwrapping delimiters so symbols
  // inside code spans are not re-interpreted as emphasis.
  const codeSpans: string[] = [];
  const placeholder = (index: number) => `${CODE_SENTINEL}${index}${CODE_SENTINEL}`;
  let text = cleaned
    .replaceAll(CODE_SENTINEL, "")
    .replace(/```[^\n]*\n?([\s\S]*?)```/g, (_match, body: string) => {
      codeSpans.push(body);
      return placeholder(codeSpans.length - 1);
    })
    .replace(/`([^`\n]+)`/g, (_match, body: string) => {
      codeSpans.push(body);
      return placeholder(codeSpans.length - 1);
    });

  text = text
    .split(/\r?\n/)
    .map((line) => {
      if (/^\s*([-*_])(?:\s*\1){2,}\s*$/.test(line)) return "";
      return line
        .replace(/^\s*(?:>\s*)+/, "")
        .replace(/^\s*#{1,6}\s+/, "")
        .replace(/^\s*[-*+]\s+\[[ xX]\]\s+/, "")
        .replace(/^\s*[-*+]\s+/, "");
    })
    .join(" ");

  text = text
    .replace(/!\[([^\]]*)\]\([^)\n]+\)/g, "$1")
    .replace(/\[([^\]]+)\]\([^)\n]+\)/g, "$1")
    .replace(/\*\*([^*\n]+?)\*\*/g, "$1")
    .replace(/(^|[^\w])__([^_\n]+?)__(?=[^\w]|$)/g, "$1$2")
    .replace(/~~([^~\n]+?)~~/g, "$1")
    .replace(/(^|[^\w*])\*([^\s*](?:[^*\n]*?[^\s*])?)\*(?=[^\w*]|$)/g, "$1$2")
    .replace(/(^|[^\w])_([^\s_](?:[^_\n]*?[^\s_])?)_(?=[^\w]|$)/g, "$1$2")
    .replace(/\\([\\`*_{}[\]()#+\-.!~|>])/g, "$1");

  return text.replace(CODE_SENTINEL_PATTERN, (_match, rawIndex: string) => {
    return codeSpans[Number(rawIndex)] ?? "";
  });
}

/** One line that stands for a message wherever a reply points at it. */
export function replyExcerpt(
  target: ChatMessage,
  messagesApi: ReturnType<typeof useCommaMessages>
) {
  const labels = {
    task: messagesApi.chat_ref_task(),
    unavailableTask: messagesApi.chat_ref_task_unavailable(),
  };
  const parts = target.parts ?? [{ kind: "markdown", text: target.text }];
  const segments: string[] = [];
  for (const part of parts) {
    const piece =
      part.kind === "markdown"
        ? stripMarkdownForExcerpt(part.text)
        : part.kind === "question"
          ? part.prompt
          : inlineMessagePartPlainText(part, labels);
    const trimmed = piece.replace(/\s+/g, " ").trim();
    if (trimmed) segments.push(trimmed);
  }
  let text = segments.join(" ");
  // A person's message that only quotes or attaches text stands for that text.
  if (target.display && !text) {
    text = [
      ...target.display.quotes,
      ...(target.display.texts ?? []).map((attached) => attached.text),
    ].join(" ");
  }
  return (
    withoutScreenLinks(text).replace(/\s+/g, " ").trim().slice(0, 180) ||
    target.attachments[0]?.fileName ||
    target.attachments[0]?.title ||
    messagesApi.chat_reply_attachment()
  );
}
