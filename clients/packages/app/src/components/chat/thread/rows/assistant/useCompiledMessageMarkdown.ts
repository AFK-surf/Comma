import { useRef } from "react";
import type { ChatMessage } from "@comma/core/chat";
import { useScreenDevicesEnabled } from "../../../../remote-screen/useScreenListing";
import {
  messageMarkdownElements,
  sameMessageParts,
  type CompiledMessageMarkdown,
} from "../../inline/MessageInlineElements";

/**
 * A committed message's Markdown as the core parsed it (`ChatMessage.markdown`),
 * with its Task chips and cards drawn in place. It is made again only when the
 * tree's or the parts' VALUE changes, not their identity: snapshot projections
 * (Electron bridge IPC echoes, poll refreshes) re-materialize equal messages,
 * and that churn must not hand the memoized MarkdownStream new nodes.
 */
export function useCompiledMessageMarkdown(
  message: ChatMessage | undefined,
  live: boolean,
  groupId: string,
  workspaceId: string
) {
  const screenCards = useScreenDevicesEnabled();
  const cacheRef = useRef<{
    compiled: CompiledMessageMarkdown | undefined;
    screenCards: boolean;
    live: boolean;
    groupId: string;
    markdown: string;
    parts: ChatMessage["parts"];
    workspaceId: string;
  } | null>(null);
  if (!message?.markdown) return undefined;
  const markdown = JSON.stringify(message.markdown);
  const cache = cacheRef.current;
  if (
    cache &&
    cache.screenCards === screenCards &&
    cache.live === live &&
    cache.groupId === groupId &&
    cache.workspaceId === workspaceId &&
    cache.markdown === markdown &&
    sameMessageParts(cache.parts ?? [], message.parts ?? [])
  ) {
    return cache.compiled;
  }
  const compiled = messageMarkdownElements(message, {
    live,
    groupId,
    workspaceId,
    screenCards,
  });
  cacheRef.current = {
    compiled,
    groupId,
    live,
    screenCards,
    markdown,
    parts: message.parts,
    workspaceId,
  };
  return compiled;
}
