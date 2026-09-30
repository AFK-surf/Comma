import type { ChatMessagePart } from "@comma/chat-contract";
import { useRef } from "react";
import type { CommaApiClient } from "../../../../../api";
import type { ChatMessage } from "../../../model/conversationChannel";
import {
  compileMessageMarkdown,
  messagePartsHaveInlineElements,
  sameMessageParts,
  type CompiledMessageMarkdown,
} from "../../inline/MessageInlineElements";

/**
 * Compiles a committed message's inline elements exactly once per parts VALUE.
 *
 * Messages without inline elements skip compilation entirely and render their
 * plain markdown text, so they never receive an inlineElements Map and the
 * memoized MarkdownStream can bail on value-equal string props alone. For
 * element-bearing messages the compiled result (content string + elements Map)
 * is cached against the parts' value equality, not the message object
 * identity: snapshot projections (Electron bridge IPC echoes, poll refreshes)
 * legitimately re-materialize equal message objects, and that identity churn
 * must not re-create the Map and force a full markdown re-parse per row.
 */
export function useCompiledMessageMarkdown(
  message: ChatMessage | undefined,
  api: CommaApiClient | undefined,
  groupId: string,
  workspaceId: string
) {
  const cacheRef = useRef<{
    api: CommaApiClient | undefined;
    compiled: CompiledMessageMarkdown;
    groupId: string;
    parts: readonly ChatMessagePart[];
    workspaceId: string;
  } | null>(null);

  const parts = message?.parts;
  if (!messagePartsHaveInlineElements(parts)) {
    return undefined;
  }

  const cache = cacheRef.current;
  if (
    cache &&
    cache.api === api &&
    cache.groupId === groupId &&
    cache.workspaceId === workspaceId &&
    sameMessageParts(cache.parts, parts)
  ) {
    return cache.compiled;
  }

  const compiled = compileMessageMarkdown(parts, { api, groupId, workspaceId });
  cacheRef.current = { api, compiled, groupId, parts, workspaceId };
  return compiled;
}
